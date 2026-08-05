-- =====================================================================
-- Respaldo del cobro por QR y tarjeta, en TODOS los puntos de pago.
-- (change: payment-proof-qr-card)
--
-- Regla única del sistema:
--   QR      -> foto del comprobante OBLIGATORIA. Ningún huésped se va sin
--              mostrar el comprobante: si no hay foto, no hay cobro.
--   TARJETA -> código de referencia OBLIGATORIO. Sin él no se puede
--              conciliar el voucher contra el extracto del POS.
--
-- Las dos se exigen en la RPC, no sólo en la UI: la validación de frontend
-- la esquiva cualquiera con las devtools abiertas.
--
-- El check-out (`check_out_room`) ya tenía `p_receipt_path` y
-- `p_payment_reference` desde 20260716020000_reservations_receipts.sql;
-- acá se le suma la exigencia del número de tarjeta y se lleva la misma
-- capacidad al resto de los cobros: caja chica, anticipos, eventos y
-- cuentas por cobrar.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0) Helper único de validación. Que la regla viva en UNA función evita
--    que dentro de seis meses "tarjeta sin número" se cuele por el flujo
--    que alguien se olvidó de tocar.
-- ---------------------------------------------------------------------
create or replace function public.assert_payment_proof(
  p_method            text,
  p_payment_reference text,
  p_receipt_path      text default null
) returns void
language plpgsql
immutable
set search_path = public
as $$
begin
  if p_method = 'QR'
     and coalesce(trim(p_receipt_path), '') = '' then
    raise exception 'La foto del comprobante es obligatoria para pagos por QR';
  end if;
  if p_method = 'TARJETA'
     and coalesce(trim(p_payment_reference), '') = '' then
    raise exception 'El código de referencia es obligatorio para pagos con tarjeta';
  end if;
end;
$$;

grant execute on function public.assert_payment_proof(text, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- 1) Columnas de respaldo donde faltaban.
-- ---------------------------------------------------------------------
alter table public.cash_movements
  add column if not exists payment_reference text;

alter table public.anticipos
  add column if not exists receipt_path      text,
  add column if not exists payment_reference text;

alter table public.event_payments
  add column if not exists receipt_path      text,
  add column if not exists payment_reference text;

alter table public.receivables
  add column if not exists settle_receipt_path      text,
  add column if not exists settle_payment_reference text;

comment on column public.cash_movements.payment_reference is
  'Número de transacción del POS. Obligatorio cuando payment_method = TARJETA.';
comment on column public.anticipos.receipt_path is
  'Foto del comprobante QR en el bucket privado ''receipts''.';

-- ---------------------------------------------------------------------
-- 2) add_cash_movement: +p_payment_reference. Se DROPEA la firma de 6
--    args antes de crear la de 7: con las dos vivas, una llamada por
--    nombre con 6 argumentos (que es como llama PostgREST) quedaría
--    ambigua y fallaría en runtime.
-- ---------------------------------------------------------------------
drop function if exists public.add_cash_movement(text, text, numeric, text, text, text);

create or replace function public.add_cash_movement(
  p_kind text, p_category text, p_amount numeric,
  p_concept text, p_receipt_path text,
  p_payment_method text default null,
  p_payment_reference text default null
) returns public.cash_movements
language plpgsql security definer set search_path = public as $$
declare v_session uuid; row public.cash_movements;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado';
  end if;
  select id into v_session from public.cash_sessions where status = 'open';
  if v_session is null then
    raise exception 'No hay una caja abierta';
  end if;
  if p_kind not in ('income', 'expense') then
    raise exception 'Tipo inválido';
  end if;
  if p_payment_method is not null
     and not exists (
       select 1 from public.payment_methods where code = p_payment_method and is_active
     ) then
    raise exception 'Forma de pago inválida: %', p_payment_method;
  end if;
  perform public.assert_payment_proof(p_payment_method, p_payment_reference, p_receipt_path);

  insert into public.cash_movements
    (session_id, kind, category, amount_bs, concept, receipt_path, created_by,
     payment_method, payment_reference)
    values (v_session, p_kind, p_category, p_amount, p_concept, p_receipt_path,
            auth.uid(), p_payment_method, nullif(trim(p_payment_reference), ''))
    returning * into row;
  return row;
end $$;

grant execute on function public.add_cash_movement(
  text, text, numeric, text, text, text, text
) to authenticated;

-- ---------------------------------------------------------------------
-- 3) record_anticipo: +p_receipt_path, +p_payment_reference. El respaldo
--    se guarda en el anticipo Y viaja al movimiento de caja, así el
--    comprobante aparece igual mirando desde caja o desde la reserva.
-- ---------------------------------------------------------------------
drop function if exists public.record_anticipo(uuid, numeric, text, text);

create or replace function public.record_anticipo(
  p_reservation_id    uuid,
  p_amount_bs         numeric,
  p_payment_method    text,
  p_notes             text default null,
  p_receipt_path      text default null,
  p_payment_reference text default null
) returns public.anticipos
language plpgsql
security definer
set search_path = public
as $$
declare
  v_movement public.cash_movements;
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

  perform public.assert_payment_proof(p_payment_method, v_ref, p_receipt_path);

  v_movement := public.add_cash_movement(
    'income', 'adelanto', p_amount_bs,
    'Anticipo reserva ' || p_reservation_id, p_receipt_path, p_payment_method, v_ref
  );

  insert into public.anticipos (
    reservation_id, amount_bs, payment_method, cash_movement_id, notes,
    receipt_path, payment_reference
  )
  values (
    p_reservation_id, p_amount_bs, p_payment_method, v_movement.id, p_notes,
    p_receipt_path, v_ref
  )
  returning * into v_row;

  return v_row;
end;
$$;

grant execute on function public.record_anticipo(uuid, numeric, text, text, text, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- 4) modify_anticipo: al corregir la forma de pago también se corrige el
--    respaldo. Si el anticipo pasa a TARJETA hay que dar el número; si
--    pasa a otra cosa, el respaldo viejo se limpia para no dejar la foto
--    de un QR colgada de un cobro que ya no fue por QR.
-- ---------------------------------------------------------------------
drop function if exists public.modify_anticipo(uuid, numeric, text, text);

create or replace function public.modify_anticipo(
  p_anticipo_id        uuid,
  p_new_amount_bs      numeric,
  p_new_payment_method text,
  p_reason             text,
  p_receipt_path       text default null,
  p_payment_reference  text default null
) returns public.anticipos
language plpgsql
security definer
set search_path = public
as $$
declare
  v_anticipo public.anticipos;
  v_row      public.anticipos;
  v_ref      text := nullif(trim(p_payment_reference), '');
begin
  if public.current_user_role() <> 'reception_admin' then
    raise exception 'Solo reception_admin puede modificar anticipos';
  end if;

  if p_reason is null or char_length(trim(p_reason)) = 0 then
    raise exception 'La justificación es obligatoria';
  end if;

  select * into v_anticipo from public.anticipos where id = p_anticipo_id for update;
  if not found then
    raise exception 'Anticipo no encontrado';
  end if;

  if v_anticipo.status <> 'active' then
    raise exception 'No se puede modificar un anticipo ya reembolsado (total o parcialmente)';
  end if;

  if p_new_amount_bs is null or p_new_amount_bs <= 0 then
    raise exception 'El monto debe ser positivo';
  end if;

  if not exists (
    select 1 from public.payment_methods where code = p_new_payment_method and is_active
  ) then
    raise exception 'Forma de pago inválida: %', p_new_payment_method;
  end if;

  -- Si no mandan respaldo nuevo pero la forma de pago no cambió, se
  -- conserva el que ya tenía (corregir sólo el monto no debe borrar el
  -- comprobante).
  if p_new_payment_method = v_anticipo.payment_method then
    p_receipt_path := coalesce(p_receipt_path, v_anticipo.receipt_path);
    v_ref          := coalesce(v_ref, v_anticipo.payment_reference);
  end if;

  perform public.assert_payment_proof(p_new_payment_method, v_ref, p_receipt_path);

  insert into public.anticipo_corrections (
    anticipo_id, action, previous_amount_bs, previous_payment_method,
    new_amount_bs, new_payment_method, reason
  ) values (
    p_anticipo_id, 'modify', v_anticipo.amount_bs, v_anticipo.payment_method,
    p_new_amount_bs, p_new_payment_method, p_reason
  );

  update public.anticipos set
    amount_bs         = p_new_amount_bs,
    payment_method    = p_new_payment_method,
    receipt_path      = p_receipt_path,
    payment_reference = v_ref
  where id = p_anticipo_id
  returning * into v_row;

  return v_row;
end;
$$;

grant execute on function public.modify_anticipo(uuid, numeric, text, text, text, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- 5) add_event_payment: +respaldo. (Además arrastra el fix de que el
--    movimiento de caja del efectivo no registraba payment_method.)
-- ---------------------------------------------------------------------
drop function if exists public.add_event_payment(uuid, numeric, text, boolean);

create or replace function public.add_event_payment(
  p_event_id uuid, p_amount numeric, p_method text, p_is_deposit boolean,
  p_receipt_path text default null, p_payment_reference text default null
) returns void
language plpgsql security definer set search_path = public as $$
declare v_ref text := nullif(trim(p_payment_reference), '');
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado';
  end if;
  if not exists (
    select 1 from public.payment_methods where code = p_method and is_active
  ) then
    raise exception 'Forma de pago inválida: %', p_method;
  end if;
  perform public.assert_payment_proof(p_method, v_ref, p_receipt_path);

  insert into public.event_payments (
    event_id, amount_bs, method, is_deposit, created_by,
    receipt_path, payment_reference
  )
  values (
    p_event_id, p_amount, p_method, coalesce(p_is_deposit, false), auth.uid(),
    p_receipt_path, v_ref
  );

  if p_method = 'EFECTIVO' then
    perform public.add_cash_movement(
      'income', 'evento', p_amount,
      case when p_is_deposit then 'Adelanto evento' else 'Pago evento' end,
      null, p_method, null
    );
  end if;
end $$;

grant execute on function public.add_event_payment(
  uuid, numeric, text, boolean, text, text
) to authenticated;

-- ---------------------------------------------------------------------
-- 6) settle_receivable: +respaldo del cobro que salda la deuda.
-- ---------------------------------------------------------------------
drop function if exists public.settle_receivable(uuid, text);

create or replace function public.settle_receivable(
  p_id                uuid,
  p_method            text,
  p_receipt_path      text default null,
  p_payment_reference text default null
) returns public.receivables
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row      public.receivables;
  v_movement public.cash_movements;
  v_mov_id   uuid;
  v_ref      text := nullif(trim(p_payment_reference), '');
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado';
  end if;
  if not exists (select 1 from public.payment_methods where code = p_method and is_active) then
    raise exception 'Forma de pago inválida: %', p_method;
  end if;
  perform public.assert_payment_proof(p_method, v_ref, p_receipt_path);

  select * into v_row from public.receivables where id = p_id for update;
  if not found then
    raise exception 'Cuenta por cobrar no encontrada';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'La deuda ya no está pendiente (estado: %)', v_row.status;
  end if;

  if p_method = 'EFECTIVO' then
    v_movement := public.add_cash_movement(
      'income', 'cobro_cuenta', v_row.amount_bs,
      'Cobro cuenta por cobrar', null, p_method, null
    );
    v_mov_id := v_movement.id;
  end if;

  update public.receivables
    set status = 'paid', settled_by = auth.uid(), settled_at = now(),
        settle_method = p_method, cash_movement_id = v_mov_id,
        settle_receipt_path = p_receipt_path, settle_payment_reference = v_ref
    where id = p_id
    returning * into v_row;

  if v_row.reservation_id is not null then
    update public.reservations set payment_status = 'paid' where id = v_row.reservation_id;
  end if;

  return v_row;
end;
$$;

grant execute on function public.settle_receivable(uuid, text, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- 7) check_out_room: ya recibía el respaldo, pero no exigía el número de
--    tarjeta. Se agrega la misma validación para que la regla no tenga
--    excepciones. Firma sin cambios.
-- ---------------------------------------------------------------------
create or replace function public.check_out_room(
  p_room_id               uuid,
  p_payment_method        text default 'EFECTIVO',
  p_receipt_path          text default null,
  p_payment_reference     text default null,
  p_receivable_account_id uuid default null
) returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reservation_id uuid;
  v_room_total     numeric(10,2);
  v_extras         numeric(10,2);
  v_total          numeric(10,2);
  v_status         varchar(15);
  v_room_number    text;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin', 'accountant') then
    raise exception 'No autorizado para hacer check-out';
  end if;

  if not exists (
    select 1 from public.payment_methods where code = p_payment_method and is_active
  ) then
    raise exception 'Forma de pago inválida: %', p_payment_method;
  end if;

  -- Lo ÚNICO que cambia respecto de 20260729000200_receivables.sql.
  perform public.assert_payment_proof(p_payment_method, p_payment_reference, p_receipt_path);

  select operational_status, room_number into v_status, v_room_number
  from public.rooms where id = p_room_id for update;
  if v_status <> 'occupied' then
    raise exception 'La habitación no está ocupada (estado actual: %)', coalesce(v_status, 'inexistente');
  end if;

  select id, total_amount_bs into v_reservation_id, v_room_total
  from public.reservations
  where room_id = p_room_id and status = 'checked_in'
  order by check_in_date desc
  limit 1;

  if v_reservation_id is null then
    raise exception 'No hay una reserva activa para esta habitación';
  end if;

  select coalesce(sum(fc.amount_bs), 0) into v_extras
  from public.folio_charges fc
  join public.folios f on f.id = fc.folio_id
  where f.reservation_id = v_reservation_id;

  v_total := coalesce(v_room_total, 0) + v_extras;

  update public.reservations
    set payment_method = p_payment_method,
        receipt_path = p_receipt_path,
        payment_reference = nullif(trim(p_payment_reference), '')
    where id = v_reservation_id;

  if p_payment_method = 'CTAS_POR_COBRAR' then
    -- Cuenta por cobrar: queda pendiente de cobro, se registra la deuda.
    if p_receivable_account_id is null then
      raise exception 'Elegí la cuenta por cobrar a la que se factura';
    end if;
    if not exists (select 1 from public.receivable_accounts where id = p_receivable_account_id and is_active) then
      raise exception 'Cuenta por cobrar inválida o inactiva';
    end if;

    update public.reservations set payment_status = 'pending' where id = v_reservation_id;

    if v_total > 0 then
      insert into public.receivables (account_id, reservation_id, amount_bs, concept)
      values (p_receivable_account_id, v_reservation_id, v_total,
              'Hospedaje Hab. ' || coalesce(v_room_number, '?'));
    end if;
  else
    update public.reservations set payment_status = 'paid' where id = v_reservation_id;

    -- Efectivo -> caja (excepción de root sin caja, ver 20260727000400).
    if p_payment_method = 'EFECTIVO' and v_total > 0
       and (public.current_user_role() <> 'root'
            or exists (select 1 from public.cash_sessions where status = 'open')) then
      perform public.add_cash_movement(
        'income', 'cobro_habitacion', v_total,
        'Check-out habitación', null, p_payment_method, null
      );
    end if;
  end if;

  update public.reservations set status = 'checked_out' where id = v_reservation_id;
  update public.folios set closed_at = now() where reservation_id = v_reservation_id;
  update public.rooms set operational_status = 'dirty' where id = p_room_id;

  return v_total;
end;
$$;

grant execute on function public.check_out_room(uuid, text, text, text, uuid) to authenticated;

