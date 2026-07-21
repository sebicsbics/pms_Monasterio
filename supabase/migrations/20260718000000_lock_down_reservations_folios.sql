-- =====================================================================
-- Paso 1/2 del lockdown de reservations/folios/folio_charges. Cierra el
-- riesgo documentado en 20260716030000_rate_overrides.sql:11-21 ("dev_all"
-- en reservations/folios permite bypass de la auditoría de tarifa via
-- update crudo desde el cliente).
--
-- Este paso: las 5 funciones que escriben reservations/folios/
-- folio_charges pero aún corrían en modo INVOKER (dependían solo del
-- gateo de pestañas en la UI, no de RLS) pasan a SECURITY DEFINER con el
-- mismo guardia de rol ya usado en override_reservation_rate.
-- (check_out_room y add_folio_charge/add_folio_product_charge eran
-- alcanzables por 'accountant' sin gateo de UI -- se agregan al guardia
-- porque necesitan seguir funcionando para ese rol tras el lockdown).
--
-- El paso 2 (reemplazo de las políticas "dev_all" por SELECT restringido
-- por rol) va en la migración siguiente
-- (20260718000001_lock_down_reservations_folios_rls.sql) para mantener
-- ambos cambios como commits lógicos separados.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1a) check_out_room -- preserva firma (uuid, text, text, text) y lógica.
-- ---------------------------------------------------------------------
create or replace function public.check_out_room(
  p_room_id uuid,
  p_payment_method text default 'EFECTIVO',
  p_receipt_path text default null,
  p_payment_reference text default null
)
returns numeric
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
begin
  if public.current_user_role() not in ('root', 'reception', 'accountant') then
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

  -- Registrar forma de pago, comprobante/referencia y marcar cobrada.
  update public.reservations
    set payment_method = p_payment_method,
        payment_status = 'paid',
        receipt_path = p_receipt_path,
        payment_reference = p_payment_reference
    where id = v_reservation_id;

  -- Efectivo -> alimenta la caja (requiere caja abierta; si no, revierte todo).
  if p_payment_method = 'EFECTIVO' and v_total > 0 then
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

-- ---------------------------------------------------------------------
-- 1b) add_folio_charge -- preserva firma (uuid, text, numeric) y lógica.
-- ---------------------------------------------------------------------
create or replace function public.add_folio_charge(
  p_room_id     uuid,
  p_description text,
  p_amount      numeric
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_folio_id uuid;
  v_charge_id uuid;
begin
  if public.current_user_role() not in ('root', 'reception', 'accountant') then
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
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant execute on function public.add_folio_charge(uuid,text,numeric) to anon, authenticated;
  end if;
end$$;

-- ---------------------------------------------------------------------
-- 1c) add_folio_product_charge -- preserva firma (uuid, uuid, numeric) y lógica.
-- ---------------------------------------------------------------------
create or replace function public.add_folio_product_charge(
  p_room_id    uuid,
  p_product_id uuid,
  p_quantity   numeric
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_folio_id  uuid;
  v_stock     numeric;
  v_price     numeric;
  v_name      text;
  v_charge_id uuid;
begin
  if public.current_user_role() not in ('root', 'reception', 'accountant') then
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
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant execute on function public.add_folio_product_charge(uuid,uuid,numeric)
      to anon, authenticated;
  end if;
end$$;

-- ---------------------------------------------------------------------
-- 1d) create_reservation -- preserva firma y lógica. Ya estaba gateado
--     por pestaña en la UI (root/reception); ahora también a nivel RPC,
--     para no depender únicamente de ese gateo.
-- ---------------------------------------------------------------------
create or replace function public.create_reservation(
  p_room_id      uuid,
  p_room_type_id uuid,
  p_first_name   text,
  p_last_name    text,
  p_phone        text,
  p_email        text,
  p_check_in     date,
  p_check_out    date,
  p_num_guests   int,
  p_method       text
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_person_id      uuid;
  v_reservation_id uuid;
  v_rate           numeric(10,2);
  v_max_occ        int;
  v_nights         int;
begin
  if public.current_user_role() not in ('root', 'reception') then
    raise exception 'No autorizado para crear reservas';
  end if;

  if p_check_out <= p_check_in then
    raise exception 'La fecha de salida debe ser posterior a la de entrada';
  end if;
  if p_num_guests < 1 then
    raise exception 'Debe haber al menos 1 persona';
  end if;
  -- Sin contacto la reserva es inútil.
  if nullif(trim(p_phone), '') is null and nullif(trim(p_email), '') is null then
    raise exception 'Se requiere al menos un contacto (celular o correo)';
  end if;

  select rt.base_price_bs, rt.max_occupancy into v_rate, v_max_occ
  from public.room_type_options o
  join public.room_types rt on rt.id = o.room_type_id
  where o.room_id = p_room_id and o.room_type_id = p_room_type_id;

  if v_rate is null then
    raise exception 'El tipo seleccionado no corresponde a esta habitación';
  end if;
  if v_max_occ < p_num_guests then
    raise exception 'El tipo elegido admite hasta % personas', v_max_occ;
  end if;

  -- Bloqueo pesimista + revalidación de disponibilidad (anti-overbooking).
  perform 1 from public.rooms where id = p_room_id for update;
  if exists (
    select 1 from public.reservations r
    where r.room_id = p_room_id
      and r.status in ('confirmed', 'checked_in')
      and r.check_in_date < p_check_out
      and p_check_in < r.check_out_date
  ) then
    raise exception 'La habitación ya no está disponible para esas fechas';
  end if;

  -- Deduplicación por email (si lo dieron); si no, huésped nuevo.
  if nullif(p_email, '') is not null then
    select id into v_person_id from public.people where email = p_email;
  end if;

  if v_person_id is not null then
    update public.people set
      first_name = p_first_name,
      last_name  = p_last_name,
      phone      = coalesce(nullif(p_phone, ''), phone)
    where id = v_person_id;
    insert into public.guests (person_id) values (v_person_id)
      on conflict (person_id) do nothing;
  else
    insert into public.people (first_name, last_name, email, phone)
    values (p_first_name, p_last_name, nullif(p_email, ''), nullif(p_phone, ''))
    returning id into v_person_id;
    insert into public.guests (person_id) values (v_person_id);
  end if;

  v_nights := p_check_out - p_check_in;

  insert into public.reservations (
    guest_id, room_id, room_type_id, check_in_date, check_out_date,
    reservation_method, payment_status, total_amount_bs, status, num_guests
  ) values (
    v_person_id, p_room_id, p_room_type_id, p_check_in, p_check_out,
    p_method, 'pending', v_rate * v_nights, 'confirmed', p_num_guests
  ) returning id into v_reservation_id;

  return v_reservation_id;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant execute on function public.create_reservation(uuid,uuid,text,text,text,text,date,date,int,text)
      to anon, authenticated;
  end if;
end$$;

-- ---------------------------------------------------------------------
-- 1e) check_in_reservation -- preserva firma y lógica. Ya estaba gateado
--     por pestaña en la UI (root/reception); ahora también a nivel RPC.
-- ---------------------------------------------------------------------
create or replace function public.check_in_reservation(
  p_reservation_id uuid,
  p_document       text,
  p_birth_date     date,
  p_country_code   text,
  p_city           text,
  p_wants_offers   boolean
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room_id    uuid;
  v_person_id  uuid;
  v_status     varchar(20);
  v_room_state varchar(15);
begin
  if public.current_user_role() not in ('root', 'reception') then
    raise exception 'No autorizado para hacer check-in';
  end if;

  -- Traer la reserva y bloquear la habitación.
  select r.room_id, r.guest_id, r.status
  into v_room_id, v_person_id, v_status
  from public.reservations r
  where r.id = p_reservation_id;

  if v_status is null then
    raise exception 'Reserva no encontrada';
  end if;
  if v_status <> 'confirmed' then
    raise exception 'La reserva no está confirmada (estado: %)', v_status;
  end if;

  select operational_status into v_room_state
  from public.rooms where id = v_room_id for update;
  if v_room_state <> 'available' then
    raise exception 'La habitación no está lista (estado: %). Debe estar disponible.', v_room_state;
  end if;

  -- Si el documento ya pertenece a OTRO huésped, avisar en vez de romper.
  if nullif(p_document, '') is not null and exists (
    select 1 from public.guests
    where passport_number = p_document and person_id <> v_person_id
  ) then
    raise exception 'Ya existe otro huésped con el documento %', p_document;
  end if;

  -- Completar el perfil del huésped de la reserva.
  update public.people set birth_date = coalesce(p_birth_date, birth_date)
  where id = v_person_id;
  update public.guests set
    passport_number = coalesce(nullif(p_document, ''), passport_number),
    country_code    = coalesce(nullif(p_country_code, ''), country_code),
    city            = coalesce(nullif(p_city, ''), city),
    wants_offers    = p_wants_offers
  where person_id = v_person_id;

  update public.reservations set status = 'checked_in' where id = p_reservation_id;
  insert into public.folios (reservation_id) values (p_reservation_id)
    on conflict (reservation_id) do nothing;
  update public.rooms set operational_status = 'occupied' where id = v_room_id;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant execute on function public.check_in_reservation(uuid,text,date,text,text,boolean)
      to anon, authenticated;
  end if;
end$$;
