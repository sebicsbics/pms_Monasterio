-- =====================================================================
-- FIX: los cobros que no son en efectivo no llegaban a caja.
-- (change: non-cash-income-to-caja)
--
-- EL BUG
-- `check_out_room`, `add_event_payment` y `settle_receivable` sólo creaban
-- el movimiento de caja cuando el método era EFECTIVO. Cualquier cobro por
-- QR, tarjeta, depósito o transferencia se cobraba de verdad, se marcaba
-- la reserva como 'paid'... y no dejaba NINGÚN rastro en `cash_movements`.
--
-- Mientras la caja era sólo el cajón físico, eso casi tenía sentido. Dejó
-- de tenerlo cuando la caja pasó a tener la pestaña "Otros medios"
-- (20260805 / feat(cash)): esa pestaña se alimenta de `cash_movements`, y
-- estaba vacía porque nadie escribía ahí. En 90 días de producción eso son
-- 18 cobros de check-out (~16.360 Bs) invisibles, contra 5 en efectivo.
--
-- LA REGLA
-- Todo cobro que representa PLATA QUE ENTRA se registra, sea del medio que
-- sea. El split efectivo / otros medios lo hace la UI a partir de
-- `payment_method`; el saldo esperado del arqueo sigue contando sólo
-- efectivo, así que registrar los demás NO descuadra el cierre.
--
-- QUÉ NO se registra, y por qué:
--   CTAS_POR_COBRAR -> todavía no entró plata; se crea una deuda.
--   CORTESIA        -> no se cobra nada.
--   INTERCAMBIO     -> canje de servicios, no hay flujo de dinero.
--   MIXTO / OTRO    -> no se pueden atribuir a un medio; registrarlos
--                      inventaría un dato que no tenemos.
-- =====================================================================

create or replace function public.payment_records_income(p_method text)
returns boolean
language sql
immutable
set search_path = public
as $$
  select p_method in ('EFECTIVO', 'QR', 'TARJETA', 'DEPOSITO', 'TRANSFERENCIA');
$$;

grant execute on function public.payment_records_income(text) to authenticated;

comment on function public.payment_records_income(text) is
  'Si esta forma de pago representa plata que entra de verdad, y por lo '
  'tanto tiene que quedar registrada en cash_movements. Excluye deuda '
  '(CTAS_POR_COBRAR), cortesías, intercambios y los códigos que no se '
  'pueden atribuir a un medio concreto (MIXTO, OTRO).';

-- ---------------------------------------------------------------------
-- 1) check_out_room. Cuerpo idéntico al vigente salvo la condición del
--    movimiento (EFECTIVO -> payment_records_income) y que ahora se le
--    pasa el respaldo, para poder abrir la foto del QR o ver el código de
--    la tarjeta desde la caja misma.
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

    -- ANTES: sólo EFECTIVO. Ahora, todo cobro real.
    -- (Se conserva la excepción de root sin caja, ver 20260727000400.)
    if public.payment_records_income(p_payment_method) and v_total > 0
       and (public.current_user_role() <> 'root'
            or exists (select 1 from public.cash_sessions where status = 'open')) then
      perform public.add_cash_movement(
        'income', 'cobro_habitacion', v_total,
        'Check-out Hab. ' || coalesce(v_room_number, '?'),
        p_receipt_path, p_payment_method, p_payment_reference
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

-- ---------------------------------------------------------------------
-- 2) add_event_payment: mismo defecto, misma corrección.
-- ---------------------------------------------------------------------
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

  if public.payment_records_income(p_method) then
    perform public.add_cash_movement(
      'income', 'evento', p_amount,
      case when p_is_deposit then 'Adelanto evento' else 'Pago evento' end,
      p_receipt_path, p_method, v_ref
    );
  end if;
end $$;

grant execute on function public.add_event_payment(
  uuid, numeric, text, boolean, text, text
) to authenticated;

-- ---------------------------------------------------------------------
-- 3) settle_receivable: mismo defecto, misma corrección. Acá la plata SÍ
--    entra (se está cobrando la deuda), sea por el medio que sea.
-- ---------------------------------------------------------------------
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

  if public.payment_records_income(p_method) then
    v_movement := public.add_cash_movement(
      'income', 'cobro_cuenta', v_row.amount_bs,
      'Cobro cuenta por cobrar', p_receipt_path, p_method, v_ref
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
