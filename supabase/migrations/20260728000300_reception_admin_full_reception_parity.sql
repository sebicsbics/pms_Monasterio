-- =====================================================================
-- Paridad total de `reception_admin` con `reception`.
--
-- Revierte la exclusión de folios declarada en
-- 20260722010000_reception_admin_role.sql: el rol pasa a poder cargar
-- consumos y hacer check-out, además de generar el tablero de
-- housekeeping y leer los tickets de mantenimiento.
-- Sin cambios en los RPC/policies exclusivos de root/accountant.
-- =====================================================================

-- ---------- 1) Folios: cargos manuales ----------
create or replace function public.add_folio_charge(
  p_room_id uuid, p_description text, p_amount numeric
) returns uuid
language plpgsql security definer set search_path = public
as $function$
declare
  v_folio_id uuid;
  v_charge_id uuid;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin', 'accountant') then
    raise exception 'No autorizado para cargar consumos al folio';
  end if;

  if p_amount is null or p_amount < 0 then
    raise exception 'El monto debe ser mayor o igual a 0';
  end if;
  if nullif(trim(p_description), '') is null then
    raise exception 'La descripción es obligatoria';
  end if;

  select f.id into v_folio_id
  from public.folios f
  join public.reservations r on r.id = f.reservation_id
  where r.room_id = p_room_id and r.status = 'checked_in'
  order by r.check_in_date desc
  limit 1;

  if v_folio_id is null then
    raise exception 'No hay una estadía activa en esta habitación';
  end if;

  insert into public.folio_charges (folio_id, description, amount_bs)
  values (v_folio_id, trim(p_description), p_amount)
  returning id into v_charge_id;

  return v_charge_id;
end;
$function$;

-- ---------- 2) Folios: consumo de productos ----------
create or replace function public.add_folio_product_charge(
  p_room_id uuid, p_product_id uuid, p_quantity numeric
) returns uuid
language plpgsql security definer set search_path = public
as $function$
declare
  v_folio_id  uuid;
  v_stock     numeric;
  v_price     numeric;
  v_name      text;
  v_charge_id uuid;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin', 'accountant') then
    raise exception 'No autorizado para cargar consumos al folio';
  end if;

  if p_quantity is null or p_quantity <= 0 then
    raise exception 'La cantidad debe ser mayor a 0';
  end if;

  select f.id into v_folio_id
  from public.folios f
  join public.reservations r on r.id = f.reservation_id
  where r.room_id = p_room_id and r.status = 'checked_in'
  order by r.check_in_date desc
  limit 1;
  if v_folio_id is null then
    raise exception 'No hay una estadía activa en esta habitación';
  end if;

  -- Bloqueo del producto para evitar descuentos concurrentes erróneos.
  select current_stock, sale_price_bs, name
  into v_stock, v_price, v_name
  from public.products where id = p_product_id for update;
  if v_stock is null then
    raise exception 'Producto no encontrado';
  end if;
  if v_stock < p_quantity then
    raise exception 'Stock insuficiente de % (disponible: %)', v_name, v_stock;
  end if;

  update public.products
    set current_stock = current_stock - p_quantity
    where id = p_product_id;

  insert into public.folio_charges (folio_id, description, amount_bs, product_id, quantity)
  values (
    v_folio_id,
    v_name || ' x' || p_quantity,
    v_price * p_quantity,
    p_product_id,
    p_quantity
  ) returning id into v_charge_id;

  return v_charge_id;
end;
$function$;

-- ---------- 3) Check-out ----------
create or replace function public.check_out_room(
  p_room_id uuid,
  p_payment_method text default 'EFECTIVO',
  p_receipt_path text default null,
  p_payment_reference text default null
) returns numeric
language plpgsql security definer set search_path = public
as $function$
declare
  v_reservation_id uuid;
  v_room_total     numeric(10,2);
  v_extras         numeric(10,2);
  v_total          numeric(10,2);
  v_status         varchar(15);
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin', 'accountant') then
    raise exception 'No autorizado para hacer check-out';
  end if;

  if not exists (
    select 1 from public.payment_methods where code = p_payment_method and is_active
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

  update public.reservations
    set payment_method = p_payment_method,
        payment_status = 'paid',
        receipt_path = p_receipt_path,
        payment_reference = p_payment_reference
    where id = v_reservation_id;

  if p_payment_method = 'EFECTIVO' and v_total > 0
     and (public.current_user_role() <> 'root'
          or exists (select 1 from public.cash_sessions where status = 'open')) then
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
$function$;

-- ---------- 4) Housekeeping: generar tablero ----------
create or replace function public.generate_housekeeping_assignments(p_service_date date)
returns void
language plpgsql security definer set search_path = public
as $function$
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado para generar el tablero de housekeeping';
  end if;

  insert into public.housekeeping_assignments (room_id, service_date, kind, status)
  select r.room_id, p_service_date, 'stayover', 'pending'
  from public.reservations r
  where r.room_id is not null
    and r.status = 'checked_in'
    and r.check_in_date <= p_service_date
    and r.check_out_date > p_service_date

  union

  select r.room_id, p_service_date, 'turnover', 'pending'
  from public.reservations r
  where r.room_id is not null
    and r.check_out_date = p_service_date
    and r.status in ('checked_in', 'checked_out')

  on conflict (room_id, service_date) do nothing;
end;
$function$;

-- ---------- 5) Mantenimiento: lectura ----------
drop policy if exists "mt_select" on public.maintenance_tickets;
create policy "mt_select" on public.maintenance_tickets
  for select using (public.current_user_role() in
    ('root', 'reception', 'reception_admin', 'accountant'));

drop policy if exists "mte_read" on public.maintenance_ticket_events;
create policy "mte_read" on public.maintenance_ticket_events
  for select using (public.current_user_role() in
    ('root', 'reception', 'reception_admin', 'accountant'));

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function public.add_folio_charge(uuid, text, numeric) to authenticated;
    grant execute on function public.add_folio_product_charge(uuid, uuid, numeric) to authenticated;
    grant execute on function public.check_out_room(uuid, text, text, text) to authenticated;
    grant execute on function public.generate_housekeeping_assignments(date) to authenticated;
  end if;
end $$;
