-- =====================================================================
-- Integración check-out ↔ caja chica: forma de pago + efectivo alimenta caja.
--
-- El check-out ahora recibe la forma de pago (efectivo/qr/transferencia/tarjeta),
-- la registra en la reserva, y si es EFECTIVO inserta el ingreso en la caja
-- abierta (reusa add_cash_movement, que valida rol y caja). Todo en una
-- transacción: si no hay caja abierta para efectivo, el check-out se revierte.
-- =====================================================================

drop function if exists public.check_out_room(uuid);

create or replace function public.check_out_room(
  p_room_id uuid,
  p_payment_method text default 'efectivo'
)
returns numeric
language plpgsql
as $$
declare
  v_reservation_id uuid;
  v_room_total     numeric(10,2);
  v_extras         numeric(10,2);
  v_total          numeric(10,2);
  v_status         varchar(15);
begin
  if p_payment_method not in ('efectivo', 'qr', 'transferencia', 'tarjeta') then
    raise exception 'Forma de pago inválida: %', p_payment_method;
  end if;

  select operational_status into v_status
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

  -- Registrar forma de pago y marcar cobrada.
  update public.reservations
    set payment_method = p_payment_method, payment_status = 'paid'
    where id = v_reservation_id;

  -- Efectivo -> alimenta la caja (requiere caja abierta; si no, revierte todo).
  if p_payment_method = 'efectivo' and v_total > 0 then
    perform public.add_cash_movement(
      'income', 'cobro_habitacion', v_total,
      'Check-out habitación', null
    );
  end if;

  update public.reservations set status = 'checked_out' where id = v_reservation_id;
  update public.folios set closed_at = now() where reservation_id = v_reservation_id;
  update public.rooms set operational_status = 'dirty' where id = p_room_id;

  return v_total;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function public.check_out_room(uuid, text) to anon, authenticated;
  end if;
end$$;
