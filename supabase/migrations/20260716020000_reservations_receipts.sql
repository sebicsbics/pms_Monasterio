-- =====================================================================
-- Extiende el patrón de comprobantes (ya usado en cash_movements) al
-- check-out de folio: la reserva gana receipt_path (imagen de comprobante
-- QR, reutilizando el bucket privado 'receipts' existente) y
-- payment_reference (código de referencia de tarjeta, cuando no hay imagen).
-- Columnas separadas porque receipt_path implica "ruta en storage" y
-- mezclar un código de texto plano ahí rompe esa invariante.
-- =====================================================================

alter table public.reservations
  add column if not exists receipt_path text;

alter table public.reservations
  add column if not exists payment_reference text;

-- check_out_room gana p_receipt_path / p_payment_reference (opcionales,
-- igual que receipt_path ya es opcional en cash_movements). Se elimina la
-- firma anterior (uuid, text) para evitar ambigüedad de sobrecarga: con
-- valores por defecto, una llamada (uuid, text) calzaría en ambas firmas.
drop function if exists public.check_out_room(uuid, text);

create or replace function public.check_out_room(
  p_room_id uuid,
  p_payment_method text default 'efectivo',
  p_receipt_path text default null,
  p_payment_reference text default null
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
  if not exists (
    select 1 from public.payment_methods where code = p_payment_method and active
  ) then
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

  -- Registrar forma de pago, comprobante/referencia y marcar cobrada.
  update public.reservations
    set payment_method = p_payment_method,
        payment_status = 'paid',
        receipt_path = p_receipt_path,
        payment_reference = p_payment_reference
    where id = v_reservation_id;

  -- Efectivo -> alimenta la caja (requiere caja abierta; si no, revierte todo).
  if p_payment_method = 'efectivo' and v_total > 0 then
    perform public.add_cash_movement(
      'income', 'cobro_habitacion', v_total,
      'Check-out habitación', null, p_payment_method
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
    grant execute on function public.check_out_room(uuid, text, text, text) to anon, authenticated;
  end if;
end$$;
