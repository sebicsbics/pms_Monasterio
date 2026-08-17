-- =====================================================================
-- El anticipo se descuenta en el check-out (change: checkout-anticipos).
--
-- BUG: `check_out_room` cobraba el folio COMPLETO aunque la reserva
-- tuviera anticipos. La plata del anticipo ya había entrado a caja al
-- registrarlo (record_anticipo → add_cash_movement('income','adelanto')),
-- así que el check-out la volvía a registrar como ingreso: caja quedaba
-- inflada por el monto del anticipo y al huésped se le cobraba dos veces.
--
-- Arreglo: el folio sigue valiendo lo mismo (v_total), pero lo que se
-- COBRA y se registra en caja es el saldo:
--
--   saldo = total del folio − anticipos netos (monto − reembolsado)
--
-- El saldo nunca baja de 0: si el anticipo excede el folio, el excedente
-- es un reembolso (refund_anticipo), no un egreso automático del
-- check-out. Cobrar 0 significa no tocar caja — ya se tocó al recibir el
-- anticipo.
--
-- La función devuelve el SALDO cobrado (no el total del folio): es lo que
-- recepción tiene que recibir en mano y lo que la UI muestra como "total
-- cobrado".
-- =====================================================================

drop function if exists public.check_out_room(uuid, text, text, text, uuid, numeric, numeric, text);

create or replace function public.check_out_room(
  p_room_id               uuid,
  p_payment_method        text default 'EFECTIVO',
  p_receipt_path          text default null,
  p_payment_reference     text default null,
  p_receivable_account_id uuid default null,
  p_cash_bs               numeric default null,
  p_non_cash_bs           numeric default null,
  p_non_cash_method       text default null
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
  v_anticipos      numeric(10,2);
  v_due            numeric(10,2);
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

  -- En MIXTO el respaldo pertenece a la parte electrónica, no al método
  -- 'MIXTO' en sí: lo valida record_mixed_income más abajo.
  if p_payment_method <> 'MIXTO' then
    perform public.assert_payment_proof(p_payment_method, p_payment_reference, p_receipt_path);
  end if;

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

  -- Anticipos netos de la reserva: lo ya pagado por adelantado, menos lo
  -- que se le haya devuelto. (No se puede tomar `for update` junto con un
  -- agregado; la carrera contra un reembolso simultáneo la corta el lock
  -- de la habitación tomado arriba, que es por donde pasa todo check-out.)
  select coalesce(sum(a.amount_bs - a.refunded_amount_bs), 0) into v_anticipos
  from public.anticipos a
  where a.reservation_id = v_reservation_id;

  v_due := greatest(v_total - v_anticipos, 0);

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

    -- Se factura el SALDO: el anticipo ya está cobrado, no se le debe.
    if v_due > 0 then
      insert into public.receivables (account_id, reservation_id, amount_bs, concept)
      values (p_receivable_account_id, v_reservation_id, v_due,
              'Hospedaje Hab. ' || coalesce(v_room_number, '?'));
    end if;
  else
    update public.reservations set payment_status = 'paid' where id = v_reservation_id;

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
$$;

grant execute on function public.check_out_room(
  uuid, text, text, text, uuid, numeric, numeric, text
) to authenticated;

comment on function public.check_out_room(uuid, text, text, text, uuid, numeric, numeric, text) is
  'Cierra la estadía y cobra el SALDO (total del folio menos anticipos netos). '
  'Devuelve el saldo cobrado, no el total del folio.';
