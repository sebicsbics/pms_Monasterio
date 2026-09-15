-- =====================================================================
-- Enforcement de check-out/anticipos para reservas institucionales
-- (change: group-billing, stage 6, Slice 6, branch
-- feat/booking-17-checkout-enforcement). Spec R6.1-R6.4. Incluye también
-- la extensión de alcance de la decisión #391 (orquestador, post-review
-- de feat/booking-16): payment_status de una habitación institucional
-- refleja "la deuda del GRUPO por esta habitación está saldada", no
-- "este check-out cobró plata".
--
-- REVISIÓN (2026-09-15, review de esta misma rama, sdd/group-billing/
-- review-booking-17, request changes): la primera versión de esta
-- migración usaba un UPDATE MASIVO a 'paid' tanto en _close_booking_group
-- (rama saldo<=0) como en el tail de settle_receivable (rama booking_id).
-- El review reprodujo en vivo el bug: un grupo prepago (neto 0) cuya
-- última habitación mandó 80 Bs de extras a CTAS_POR_COBRAR terminaba con
-- esa habitación 'paid' aunque su propia cuenta de extras seguía
-- pendiente -- el UPDATE masivo pisaba esa cuenta sin mirarla. Mismo bug
-- en settle_receivable: saldar la cuenta de GRUPO marcaba paid una
-- habitación que todavía debía sus extras. Decisión #391 v2 (orquestador,
-- "modelo correcto, no parche", sdd/group-billing/client-payment-status):
-- una reserva de un booking 'client' es 'paid' SI Y SOLO SI (1) el grupo
-- cerró (existe un evento group_closed), (2) la deuda del GRUPO está
-- saldada (sin cuenta por cobrar de booking, o esa cuenta tiene
-- status='paid' -- una cancelada NO cuenta como saldada) Y (3) todas SUS
-- PROPIAS cuentas por cobrar de extras (reservation_id, CTAS_POR_COBRAR)
-- tienen status='paid'. En cualquier otro caso, 'pending'.
--
-- Esta migración sigue sin pushearse (rama local, nunca compartida) --
-- se edita EN EL LUGAR (squash, sdd/conventions/unpushed-migration-
-- squash) en vez de agregar una migración nueva encima.
--
-- Cuatro reescrituras body-only (CREATE OR REPLACE, mismas firmas donde
-- ya existían, sin DROP, grants sin cambios -- verificado con
-- pg_get_functiondef/proacl antes y después) MÁS una función nueva:
--   1. check_out_room (8 args, sin cambios de firma desde
--      20260817000100): para reservas de bookings 'client', cobra SOLO
--      los extras de la habitación (no el total_amount_bs) y YA NO marca
--      payment_status='paid'. SIN llamada a _refresh_client_payment_status
--      acá -- ver el comentario junto al bloque CTAS_POR_COBRAR más abajo
--      para el análisis de orden de sentencias que lo justifica.
--   2. record_anticipo (9 args, sin cambios desde 20260806010000):
--      rechaza cualquier reserva de un booking 'client' ANTES de mutar
--      nada (ni anticipos ni cash_movements).
--   3. _close_booking_group (trigger, 0 args, sin cambios de firma desde
--      20260911130000): ya NO hace un update masivo -- llama SIEMPRE a
--      public._refresh_client_payment_status(new.booking_id) después de
--      auditar el cierre (y de insertar la cuenta de grupo si
--      corresponde), tenga o no saldo pendiente.
--   4. settle_receivable (7 args, sin cambios de firma desde
--      20260806010000, incorporada a esta migración -- basada en el
--      cuerpo VIVO de feat/booking-16): la rama booking_id ya NO hace un
--      update masivo -- llama a _refresh_client_payment_status. La rama
--      reservation_id se bifurca: si la reserva es de un booking
--      'client' (cuenta de extras), llama a _refresh_client_payment_status
--      también; si es each_stay (camino de siempre), el UPDATE único sin
--      cambios.
--   5. NUEVA _refresh_client_payment_status(uuid) (SECURITY DEFINER,
--      revocada de public/anon/authenticated): recalcula, en un solo
--      UPDATE con CASE/EXISTS (NULL-safe por construcción, sin comparar
--      contra columnas que puedan ser NULL de forma implícita --
--      postgres/check-constraint-null-trap), el payment_status de TODAS
--      las reservas del booking según la regla de arriba. No-op si el
--      booking no es 'client'.
-- =====================================================================

create or replace function public.check_out_room(
  p_room_id uuid,
  p_payment_method text default 'EFECTIVO',
  p_receipt_path text default null,
  p_payment_reference text default null,
  p_receivable_account_id uuid default null,
  p_cash_bs numeric default null,
  p_non_cash_bs numeric default null,
  p_non_cash_method text default null
) returns numeric
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_reservation_id uuid;
  v_room_total     numeric(10,2);
  v_extras         numeric(10,2);
  v_total          numeric(10,2);
  v_anticipos      numeric(10,2);
  v_due            numeric(10,2);
  v_status         varchar(15);
  v_room_number    text;
  v_payer_mode     text;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin', 'accountant') then
    raise exception 'No autorizado para hacer check-out';
  end if;

  if not exists (
    select 1 from public.payment_methods where code = p_payment_method and is_active
  ) then
    raise exception 'Forma de pago inválida: %', p_payment_method;
  end if;

  if p_payment_method <> 'MIXTO' then
    perform public.assert_payment_proof(p_payment_method, p_payment_reference, p_receipt_path);
  end if;

  select operational_status, room_number into v_status, v_room_number
  from public.rooms where id = p_room_id for update;
  if v_status <> 'occupied' then
    raise exception 'La habitación no está ocupada (estado actual: %)', coalesce(v_status, 'inexistente');
  end if;

  -- reservations.booking_id es NOT NULL y bookings.payer_mode es NOT
  -- NULL con default 'each_stay' (ambos verificados en vivo contra
  -- information_schema.columns) -- el join nunca puede dejar
  -- v_payer_mode en NULL. coalesce(...,'each_stay') de todos modos, en
  -- el mismo espíritu defensivo que _close_booking_group más abajo
  -- (postgres/check-constraint-null-trap).
  select r.id, r.total_amount_bs, coalesce(b.payer_mode, 'each_stay')
    into v_reservation_id, v_room_total, v_payer_mode
  from public.reservations r
  join public.bookings b on b.id = r.booking_id
  where r.room_id = p_room_id and r.status = 'checked_in'
  order by r.check_in_date desc
  limit 1;

  if v_reservation_id is null then
    raise exception 'No hay una reserva activa para esta habitación';
  end if;

  select coalesce(sum(fc.amount_bs), 0) into v_extras
  from public.folio_charges fc
  join public.folios f on f.id = fc.folio_id
  where f.reservation_id = v_reservation_id;

  if v_payer_mode = 'client' then
    -- Reserva institucional (spec R6.1): el check-out de ESTA habitación
    -- cobra SOLO sus extras. El total de la habitación es parte del
    -- contrato del grupo -- vive en booking_balances y se salda al
    -- cerrarse el grupo (Slice 5) o al saldar la cuenta por cobrar
    -- (Slice 5b), nunca acá. Sin término de anticipos: los anticipos por
    -- habitación no existen para reservas institucionales (R6.4,
    -- record_anticipo los rechaza, ver abajo).
    v_total := v_extras;
    v_due := v_extras;
  else
    -- Camino legacy each_stay: sin cambios respecto de la versión previa
    -- (spec R6.2, regresión caracterizada en 27_*).
    v_total := coalesce(v_room_total, 0) + v_extras;

    select coalesce(sum(a.amount_bs), 0) into v_anticipos
    from public.anticipos a
    where a.reservation_id = v_reservation_id
      and a.status = 'active';

    v_due := greatest(v_total - v_anticipos, 0);
  end if;

  update public.reservations
    set payment_method = p_payment_method,
        receipt_path = p_receipt_path,
        payment_reference = nullif(trim(p_payment_reference), '')
    where id = v_reservation_id;

  if p_payment_method = 'CTAS_POR_COBRAR' then
    if p_receivable_account_id is null then
      raise exception 'Elegí la cuenta por cobrar a la que se factura';
    end if;
    if not exists (select 1 from public.receivable_accounts where id = p_receivable_account_id and is_active) then
      raise exception 'Cuenta por cobrar inválida o inactiva';
    end if;

    update public.reservations set payment_status = 'pending' where id = v_reservation_id;

    -- Se factura el SALDO (para client: solo los extras impagos).
    --
    -- Orden de sentencias (revisión #391 v2, verificado en el cuerpo
    -- VIVO): este INSERT de la cuenta de extras corre ANTES del
    -- `update reservations set status='checked_out'` de más abajo (línea
    -- que dispara el trigger reservations_close_booking_group, AFTER
    -- UPDATE OF status). Es decir, si este check-out es el que cierra el
    -- grupo (última habitación activa), _close_booking_group ya va a ver
    -- esta cuenta de extras recién insertada cuando llame a
    -- _refresh_client_payment_status -- no hace falta llamarla de nuevo
    -- acá. Y si este check-out NO es el que cierra el grupo, la regla
    -- exige payment_status='pending' de todos modos (el grupo todavía no
    -- cerró), que es exactamente el valor que esta misma sentencia ya
    -- dejó dos líneas arriba. Por construcción, check_out_room nunca
    -- necesita llamar a _refresh_client_payment_status por su cuenta.
    if v_due > 0 then
      insert into public.receivables (account_id, reservation_id, amount_bs, concept)
      values (p_receivable_account_id, v_reservation_id, v_due,
              'Hospedaje Hab. ' || coalesce(v_room_number, '?'));
    end if;
  else
    -- payment_status='paid' SOLO para each_stay: para una reserva
    -- institucional, este check-out individual no salda la deuda del
    -- grupo (decisión #391, orquestador, post-review de
    -- feat/booking-16). El saldo del grupo se marca paid al cerrarse con
    -- saldo 0 (_close_booking_group, más abajo) o al saldar la cuenta
    -- por cobrar (settle_receivable, Slice 5b).
    if v_payer_mode <> 'client' then
      update public.reservations set payment_status = 'paid' where id = v_reservation_id;
    end if;

    if p_payment_method = 'MIXTO' and v_due > 0 then
      perform public.record_mixed_income(
        v_due, p_cash_bs, p_non_cash_bs, p_non_cash_method,
        'cobro_habitacion', 'Check-out Hab. ' || coalesce(v_room_number, '?'),
        p_receipt_path, p_payment_reference
      );
    elsif public.payment_records_income(p_payment_method) and v_due > 0
       and (public.current_user_role() <> 'root'
            or exists (select 1 from public.cash_sessions where status = 'open')) then
      perform public.add_cash_movement(
        'income', 'cobro_habitacion', v_due,
        'Check-out Hab. ' || coalesce(v_room_number, '?'),
        p_receipt_path, p_payment_method, p_payment_reference
      );
    end if;
  end if;

  update public.reservations set status = 'checked_out' where id = v_reservation_id;
  update public.folios set closed_at = now() where reservation_id = v_reservation_id;
  update public.rooms set operational_status = 'dirty' where id = p_room_id;

  return v_due;
end;
$function$;

comment on function public.check_out_room(uuid, text, text, text, uuid, numeric, numeric, text) is
  'Cierra la estadía. each_stay: cobra el saldo (total + extras - anticipos), payment_status pasa a paid. '
  'client (institucional): cobra SOLO los extras de esta habitación, payment_status NO cambia -- el contrato '
  'del grupo se salda vía booking_balances/receivables al cerrarse el grupo (Slice 5) o al saldar la cuenta '
  '(Slice 5b). feat/booking-17, spec R6.1-R6.3, decisión #391.';

-- Grants sin cambios (misma firma que 20260817000100): revoke public/anon
-- ya vigente, grant authenticated ya vigente. No se re-emiten acá.

create or replace function public.record_anticipo(
  p_reservation_id uuid,
  p_amount_bs numeric,
  p_payment_method text,
  p_notes text default null,
  p_receipt_path text default null,
  p_payment_reference text default null,
  p_cash_bs numeric default null,
  p_non_cash_bs numeric default null,
  p_non_cash_method text default null
) returns public.anticipos
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_movement public.cash_movements;
  v_mov_id   uuid;
  v_row      public.anticipos;
  v_ref      text := nullif(trim(p_payment_reference), '');
begin
  if public.current_user_role() not in ('root','reception','reception_admin') then
    raise exception 'No autorizado para registrar anticipos';
  end if;

  if p_amount_bs is null or p_amount_bs <= 0 then
    raise exception 'El monto debe ser positivo';
  end if;

  if not exists (select 1 from public.reservations where id = p_reservation_id) then
    raise exception 'Reserva no encontrada';
  end if;

  -- Spec R6.4: las reservas de bookings 'client' no usan anticipos por
  -- habitación -- todo el dinero del paquete institucional va por
  -- record_booking_advance (Slice 4) o queda fijado en el contrato
  -- congelado (Slice 2). Guard ANTES de cualquier mutación: ningún
  -- cash_movement/fila de anticipos se inserta si esto dispara
  -- (caracterizado en 27_*, red4). reservations.booking_id y
  -- bookings.payer_mode son NOT NULL (verificado en vivo) -- el join no
  -- puede dejar la comparación en NULL (postgres/check-constraint-null-
  -- trap).
  if exists (
    select 1 from public.reservations r
    join public.bookings b on b.id = r.booking_id
    where r.id = p_reservation_id and b.payer_mode = 'client'
  ) then
    raise exception 'Las reservas institucionales no usan anticipos por habitación; usá el adelanto de grupo';
  end if;

  if p_payment_method = 'MIXTO' then
    v_mov_id := public.record_mixed_income(
      p_amount_bs, p_cash_bs, p_non_cash_bs, p_non_cash_method, 'adelanto',
      'Anticipo reserva ' || p_reservation_id, p_receipt_path, v_ref
    );
  else
    perform public.assert_payment_proof(p_payment_method, v_ref, p_receipt_path);
    v_movement := public.add_cash_movement(
      'income', 'adelanto', p_amount_bs,
      'Anticipo reserva ' || p_reservation_id, p_receipt_path, p_payment_method, v_ref
    );
    v_mov_id := v_movement.id;
  end if;

  insert into public.anticipos (
    reservation_id, amount_bs, payment_method, cash_movement_id, notes,
    receipt_path, payment_reference
  )
  values (
    p_reservation_id, p_amount_bs, p_payment_method, v_mov_id, p_notes,
    p_receipt_path, v_ref
  )
  returning * into v_row;

  return v_row;
end;
$function$;

-- Grants sin cambios (misma firma que 20260806010000).

create or replace function public._close_booking_group()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_payer_mode text;
  v_account_id uuid;
  v_net        numeric(10,2);
begin
  -- (1) Lectura SIN lock: evita tomar un lock de fila de `bookings` en
  -- CADA check-out/cancelación de una reserva each_stay (el caso común,
  -- la inmensa mayoría de las transiciones de status). payer_mode es
  -- NOT NULL con default 'each_stay' (constraint de Slice 2a,
  -- verificado en vivo: is_nullable=NO) y ninguna función de este repo
  -- lo modifica después de crear el booking -- leerlo sin FOR UPDATE es
  -- seguro: no hay carrera posible sobre un valor que nunca cambia.
  -- `is distinct from` en vez de `<>`: NULL-safe por construcción
  -- (postgres/check-constraint-null-trap, #368), aunque acá payer_mode
  -- nunca sea NULL -- defensa en profundidad, mismo estilo del resto del
  -- cambio.
  select payer_mode into v_payer_mode
  from public.bookings where id = new.booking_id;

  if v_payer_mode is distinct from 'client' then
    return new;
  end if;

  -- (2) Recién acá, SOLO para bookings institucionales, se toma el lock
  -- de fila de `bookings` (mismo lock que ya usa record_booking_advance,
  -- feat/booking-14) -- serializa un cierre en curso contra un adelanto
  -- concurrente y viceversa (ver análisis de deadlock arriba).
  select payer_mode, receivable_account_id into v_payer_mode, v_account_id
  from public.bookings where id = new.booking_id for update;

  -- (3) Todavía quedan habitaciones activas del grupo: no cierra.
  if exists (
    select 1 from public.reservations
    where booking_id = new.booking_id and status in ('confirmed', 'checked_in')
  ) then
    return new;
  end if;

  -- (4) Idempotencia (defensa de aplicación; el unique index de
  -- `receivables` -- Slice 1 -- es la defensa de esquema si esto
  -- fallara igual).
  if exists (
    select 1 from public.booking_balances
    where booking_id = new.booking_id and event_type = 'group_closed'
  ) then
    return new;
  end if;

  -- (5) _net_owed_bs, NUNCA net_owed_bs (el wrapper público guardado por
  -- rol, sdd/group-billing/net-owed-guard) -- código interno usa siempre
  -- el helper con underscore. coalesce(...,0)-coalesce(...,0) por
  -- construcción: nunca NULL.
  v_net := public._net_owed_bs(new.booking_id);

  -- (6) SIEMPRE se audita el cierre, incluso con saldo <= 0 (spec R5.3).
  insert into public.booking_balances (booking_id, event_type, amount_bs, notes)
  values (new.booking_id, 'group_closed', v_net, 'Cierre automático del grupo');

  -- (7) Cuenta por cobrar SOLO si queda saldo pendiente (spec R5.4).
  -- receivable_account_id está garantizado NOT NULL para bookings
  -- 'client' (constraint bookings_client_requires_account, Slice 2a) --
  -- la rama "cuenta nula al cerrar" es inalcanzable por construcción.
  -- `on conflict` sobre el unique index parcial de Slice 1 es la última
  -- red de seguridad ante una carrera que el lock de arriba ya debería
  -- haber prevenido.
  if v_net > 0 then
    insert into public.receivables (account_id, booking_id, amount_bs, concept)
    values (v_account_id, new.booking_id, v_net, 'Saldo de grupo/institución')
    on conflict (booking_id) where booking_id is not null do nothing;
  end if;

  -- (8, revisión #391 v2) Ya NO hay un `else update ... set paid` acá --
  -- ese UPDATE masivo pisaba cualquier cuenta de EXTRAS de una habitación
  -- (reservation_id, CTAS_POR_COBRAR) que siguiera pendiente, marcándola
  -- 'paid' igual (bug reproducido en vivo por el review de esta rama,
  -- sdd/group-billing/review-booking-17). Ahora SIEMPRE se recalcula con
  -- la regla completa (grupo cerrado + deuda de grupo saldada + cada
  -- cuenta propia pagada), tenga o no saldo de grupo pendiente.
  perform public._refresh_client_payment_status(new.booking_id);

  return new;
end;
$function$;

-- Grants sin cambios (trigger interno, revocado de public/anon/
-- authenticated desde 20260911130000).

create or replace function public.settle_receivable(
  p_id uuid,
  p_method text,
  p_receipt_path text default null,
  p_payment_reference text default null,
  p_cash_bs numeric default null,
  p_non_cash_bs numeric default null,
  p_non_cash_method text default null
) returns public.receivables
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_row      public.receivables;
  v_movement public.cash_movements;
  v_mov_id   uuid;
  v_ref      text := nullif(trim(p_payment_reference), '');
  -- (revisión #391 v2) solo se usan cuando la cuenta es a nivel de
  -- reserva (v_row.reservation_id is not null) -- ver más abajo.
  v_reservation_booking_id  uuid;
  v_reservation_payer_mode  text;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado';
  end if;
  if not exists (select 1 from public.payment_methods where code = p_method and is_active) then
    raise exception 'Forma de pago inválida: %', p_method;
  end if;

  select * into v_row from public.receivables where id = p_id for update;
  if not found then
    raise exception 'Cuenta por cobrar no encontrada';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'La deuda ya no está pendiente (estado: %)', v_row.status;
  end if;

  if p_method = 'MIXTO' then
    v_mov_id := public.record_mixed_income(
      v_row.amount_bs, p_cash_bs, p_non_cash_bs, p_non_cash_method,
      'cobro_cuenta', 'Cobro cuenta por cobrar', p_receipt_path, v_ref
    );
  else
    perform public.assert_payment_proof(p_method, v_ref, p_receipt_path);
    if public.payment_records_income(p_method) then
      v_movement := public.add_cash_movement(
        'income', 'cobro_cuenta', v_row.amount_bs,
        'Cobro cuenta por cobrar', p_receipt_path, p_method, v_ref
      );
      v_mov_id := v_movement.id;
    end if;
  end if;

  update public.receivables
    set status = 'paid', settled_by = auth.uid(), settled_at = now(),
        settle_method = p_method, cash_movement_id = v_mov_id,
        settle_receipt_path = p_receipt_path, settle_payment_reference = v_ref
    where id = p_id
    returning * into v_row;

  -- (revisión #391 v2) Cuentas de grupo tienen reservation_id NULL y
  -- booking_id seteado (feat/booking-15). Ya NO hay un UPDATE masivo acá
  -- -- pisaba cualquier cuenta de extras de otra habitación que siguiera
  -- pendiente (bug reproducido en vivo por el review). Ahora SIEMPRE se
  -- recalcula con la regla completa.
  if v_row.booking_id is not null then
    perform public._refresh_client_payment_status(v_row.booking_id);
  elsif v_row.reservation_id is not null then
    -- Cuenta a NIVEL DE RESERVA: puede ser el camino each_stay de
    -- siempre (reservation_id, booking_id NULL en la reserva -- payer_mode
    -- 'each_stay') o una cuenta de EXTRAS de una habitación institucional
    -- (feat/booking-17, CTAS_POR_COBRAR). Para el segundo caso, el estado
    -- de la habitación depende de la regla completa (grupo cerrado +
    -- deuda de grupo saldada + esta cuenta), no solo de esta cuenta --
    -- para el primero, el UPDATE único de siempre, sin cambios de
    -- comportamiento.
    select r.booking_id, coalesce(b.payer_mode, 'each_stay')
      into v_reservation_booking_id, v_reservation_payer_mode
    from public.reservations r
    join public.bookings b on b.id = r.booking_id
    where r.id = v_row.reservation_id;

    if v_reservation_payer_mode = 'client' then
      perform public._refresh_client_payment_status(v_reservation_booking_id);
    else
      update public.reservations set payment_status = 'paid' where id = v_row.reservation_id;
    end if;
  end if;

  return v_row;
end;
$function$;

-- Grants sin cambios (misma firma que 20260806010000).

create or replace function public._refresh_client_payment_status(p_booking_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_payer_mode text;
begin
  -- No-op para bookings each_stay (o inexistentes) -- esta función solo
  -- tiene sentido para 'client'. `is distinct from` NULL-safe por
  -- construcción, aunque bookings.payer_mode es NOT NULL (verificado en
  -- vivo, postgres/check-constraint-null-trap).
  select payer_mode into v_payer_mode from public.bookings where id = p_booking_id;
  if v_payer_mode is distinct from 'client' then
    return;
  end if;

  -- Regla (decisión #391 v2, "modelo correcto, no parche"): una reserva
  -- de este booking es 'paid' SI Y SOLO SI:
  --   (1) el grupo cerró -- existe un evento booking_balances con
  --       event_type='group_closed' para este booking;
  --   (2) la deuda del GRUPO está saldada -- NO existe una cuenta por
  --       cobrar a nivel de booking (reservation_id NULL) con
  --       status <> 'paid'. Si nunca se creó ninguna (saldo <= 0 al
  --       cerrar), esta condición es verdadera por vacuidad. Una cuenta
  --       'cancelled' (cancel_receivable) SIGUE contando como no saldada
  --       -- status <> 'paid' es verdadero para 'cancelled' también, así
  --       que bloquea igual que 'pending' (regresión probada en 27_*,
  --       redfix-d);
  --   (3) TODAS las cuentas por cobrar propias de ESTA reserva (extras,
  --       reservation_id = r.id) tienen status='paid'. Si esta reserva
  --       nunca tuvo una (extras cobrados en el momento o sin extras),
  --       esta condición es verdadera por vacuidad.
  -- En cualquier otro caso, 'pending'. Sin filtro de status en la reserva
  -- (incluye canceladas, mismo criterio que settle_receivable desde
  -- feat/booking-16). Todo por EXISTS/NOT EXISTS -- ningún operador de
  -- comparación contra una columna nullable, sin riesgo del NULL-trap de
  -- un CHECK (postgres/check-constraint-null-trap) ni de esta consulta.
  update public.reservations r
    set payment_status = case
      when exists (
             select 1 from public.booking_balances bb
             where bb.booking_id = p_booking_id and bb.event_type = 'group_closed'
           )
       and not exists (
             select 1 from public.receivables br
             where br.booking_id = p_booking_id and br.reservation_id is null and br.status <> 'paid'
           )
       and not exists (
             select 1 from public.receivables rr
             where rr.reservation_id = r.id and rr.status <> 'paid'
           )
      then 'paid'
      else 'pending'
    end
  where r.booking_id = p_booking_id;
end;
$function$;

revoke execute on function public._refresh_client_payment_status(uuid) from public, anon, authenticated;
