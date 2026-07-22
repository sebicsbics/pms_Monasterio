-- =====================================================================
-- Nuevo rol `reception_admin` (change: reception-admin-role).
--
-- Escritura en paridad con `reception` en todas las tablas/RPC de proceso
-- de recepción, EXCEPTO el límite de dinero de folios: `check_out_room`,
-- `add_folio_charge` y `add_folio_product_charge` siguen sin incluir
-- `reception_admin` (folios = solo lectura para este rol). Tampoco se
-- agrega a ninguna política/RPC exclusiva de `root`/`accountant`
-- (employees, login_events, time_entries, link_employee_user).
--
-- Enumeración plana (sin helper de jerarquía de roles), consistente con el
-- resto del repo.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) CHECK constraint de profiles.role: dropear + recrear con el nuevo
--    valor. El constraint original es inline en
--    20260703080000_users_and_roles.sql:9-10 y Postgres lo auto-nombra
--    `profiles_role_check` (convención tabla_columna_check).
-- ---------------------------------------------------------------------
alter table public.profiles
  drop constraint if exists profiles_role_check;
alter table public.profiles
  add constraint profiles_role_check
  check (role in ('root', 'accountant', 'reception', 'reception_admin'));

-- ---------------------------------------------------------------------
-- 2) create_staff_member: ampliar el validador de p_role (definición
--    final en 20260703280000_fix_staff_and_delete.sql) para poder asignar
--    el nuevo rol desde el alta/vínculo de personal.
-- ---------------------------------------------------------------------
create or replace function public.create_staff_member(
  p_first_name text,
  p_last_name  text,
  p_email      text,
  p_job_title  text,
  p_hire_date  date,
  p_salary     numeric,
  p_user_id    uuid default null,
  p_role       text default null,
  p_username   text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_person uuid;
begin
  if public.current_user_role() not in ('root', 'accountant') then
    raise exception 'No autorizado';
  end if;
  if p_role is not null and p_role not in ('root', 'accountant', 'reception', 'reception_admin') then
    raise exception 'Rol inválido: %', p_role;
  end if;

  -- ¿Ya existe una persona con ese email? Reusarla; si no, crearla.
  select id into v_person from public.people where email = p_email;
  if v_person is null then
    insert into public.people (first_name, last_name, email)
      values (p_first_name, p_last_name, p_email)
      returning id into v_person;
  else
    update public.people
      set first_name = p_first_name, last_name = p_last_name
      where id = v_person;
  end if;

  if exists (select 1 from public.employees where person_id = v_person) then
    raise exception 'Esa persona ya está registrada como empleado';
  end if;

  insert into public.employees (person_id, job_title, hire_date, salary, user_id)
    values (v_person, p_job_title, coalesce(p_hire_date, current_date),
            p_salary, p_user_id);

  if p_user_id is not null then
    update public.profiles
      set role     = coalesce(p_role, role),
          username = coalesce(nullif(p_username, ''), username)
      where id = p_user_id;
  end if;

  return v_person;
end $$;

-- ---------------------------------------------------------------------
-- 3) Housekeeping / tasks / mantenimiento: paridad de escritura.
-- ---------------------------------------------------------------------

-- tasks (20260703120000_housekeeping_tasks.sql:22-23)
drop policy if exists "tasks_operations" on public.tasks;
create policy "tasks_operations" on public.tasks
  for all
  using (public.current_user_role() in ('root', 'reception', 'reception_admin'))
  with check (public.current_user_role() in ('root', 'reception', 'reception_admin'));

-- maintenance_ticket_parts (20260703180000_maintenance_parts.sql:25-26)
drop policy if exists "mtp_operations" on public.maintenance_ticket_parts;
create policy "mtp_operations" on public.maintenance_ticket_parts
  for all
  using (public.current_user_role() in ('root', 'reception', 'reception_admin'))
  with check (public.current_user_role() in ('root', 'reception', 'reception_admin'));

-- maintenance_tickets: mt_insert/mt_update (20260703210000_maintenance_events_and_delete.sql:58,60-61)
-- mt_select ya incluye accountant; mt_delete sigue root-only.
drop policy if exists "mt_insert" on public.maintenance_tickets;
create policy "mt_insert" on public.maintenance_tickets
  for insert with check (public.current_user_role() in ('root', 'reception', 'reception_admin'));
drop policy if exists "mt_update" on public.maintenance_tickets;
create policy "mt_update" on public.maintenance_tickets
  for update using (public.current_user_role() in ('root', 'reception', 'reception_admin'))
              with check (public.current_user_role() in ('root', 'reception', 'reception_admin'));

-- maintenance_schedules (20260703190000_maintenance_schedules.sql:33-34)
drop policy if exists "msch_operations" on public.maintenance_schedules;
create policy "msch_operations" on public.maintenance_schedules
  for all
  using (public.current_user_role() in ('root', 'reception', 'reception_admin'))
  with check (public.current_user_role() in ('root', 'reception', 'reception_admin'));

-- housekeeping_assignments (20260722000000_housekeeping_daily_assignments.sql:31-32)
drop policy if exists "housekeeping_assignments_operations" on public.housekeeping_assignments;
create policy "housekeeping_assignments_operations" on public.housekeeping_assignments
  for all
  using (public.current_user_role() in ('root', 'reception', 'reception_admin'))
  with check (public.current_user_role() in ('root', 'reception', 'reception_admin'));

-- ---------------------------------------------------------------------
-- 4) Caja (cash_module) — solo lectura directa; parity con reception.
--    (20260709000000_cash_module.sql:51,53,148-149)
-- ---------------------------------------------------------------------
drop policy if exists "cash_sessions_read" on public.cash_sessions;
create policy "cash_sessions_read" on public.cash_sessions
  for select using (public.current_user_role() in ('root', 'reception', 'reception_admin', 'accountant'));

drop policy if exists "cash_movements_read" on public.cash_movements;
create policy "cash_movements_read" on public.cash_movements
  for select using (public.current_user_role() in ('root', 'reception', 'reception_admin', 'accountant'));

drop policy if exists "receipts_staff" on storage.objects;
create policy "receipts_staff" on storage.objects
  for all
  using (bucket_id = 'receipts' and public.current_user_role() in ('root', 'reception', 'reception_admin', 'accountant'))
  with check (bucket_id = 'receipts' and public.current_user_role() in ('root', 'reception', 'reception_admin', 'accountant'));

-- ---------------------------------------------------------------------
-- 5) Events module — parity con reception en lectura y escritura.
--    (20260709020000_events_module.sql:77,80,83,86)
-- ---------------------------------------------------------------------
drop policy if exists "event_types_read" on public.event_types;
create policy "event_types_read" on public.event_types
  for select using (public.current_user_role() in ('root', 'reception', 'reception_admin', 'accountant'));
drop policy if exists "event_types_write" on public.event_types;
create policy "event_types_write" on public.event_types for all
  using (public.current_user_role() in ('root', 'reception', 'reception_admin'))
  with check (public.current_user_role() in ('root', 'reception', 'reception_admin'));

drop policy if exists "event_areas_read" on public.event_areas;
create policy "event_areas_read" on public.event_areas
  for select using (public.current_user_role() in ('root', 'reception', 'reception_admin', 'accountant'));
drop policy if exists "event_areas_write" on public.event_areas;
create policy "event_areas_write" on public.event_areas for all
  using (public.current_user_role() in ('root', 'reception', 'reception_admin'))
  with check (public.current_user_role() in ('root', 'reception', 'reception_admin'));

drop policy if exists "events_read" on public.events;
create policy "events_read" on public.events
  for select using (public.current_user_role() in ('root', 'reception', 'reception_admin', 'accountant'));
drop policy if exists "events_write" on public.events;
create policy "events_write" on public.events for all
  using (public.current_user_role() in ('root', 'reception', 'reception_admin'))
  with check (public.current_user_role() in ('root', 'reception', 'reception_admin'));

drop policy if exists "event_area_use_read" on public.event_area_use;
create policy "event_area_use_read" on public.event_area_use
  for select using (public.current_user_role() in ('root', 'reception', 'reception_admin', 'accountant'));
drop policy if exists "event_area_use_write" on public.event_area_use;
create policy "event_area_use_write" on public.event_area_use for all
  using (public.current_user_role() in ('root', 'reception', 'reception_admin'))
  with check (public.current_user_role() in ('root', 'reception', 'reception_admin'));

drop policy if exists "event_payments_read" on public.event_payments;
create policy "event_payments_read" on public.event_payments
  for select using (public.current_user_role() in ('root', 'reception', 'reception_admin', 'accountant'));

-- ---------------------------------------------------------------------
-- 6) Reservas: create_reservation / check_in_reservation ganan paridad de
--    escritura. Definiciones finales en
--    20260718000000_lock_down_reservations_folios.sql:260,363 —
--    restatement completo del cuerpo (CREATE OR REPLACE no permite parches
--    parciales de una función PL/pgSQL).
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
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
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
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
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

-- ---------------------------------------------------------------------
-- 7) Reservas/folios: SELECT-only parity (reception ya es SELECT-only
--    aquí; agregar reception_admin no es una escalada).
--    (20260718000001_lock_down_reservations_folios_rls.sql:18-27)
-- ---------------------------------------------------------------------
drop policy if exists "reservations_select" on public.reservations;
create policy "reservations_select" on public.reservations
  for select using (public.current_user_role() in ('root', 'reception', 'reception_admin', 'accountant'));

drop policy if exists "folios_select" on public.folios;
create policy "folios_select" on public.folios
  for select using (public.current_user_role() in ('root', 'reception', 'reception_admin', 'accountant'));

drop policy if exists "folio_charges_select" on public.folio_charges;
create policy "folio_charges_select" on public.folio_charges
  for select using (public.current_user_role() in ('root', 'reception', 'reception_admin', 'accountant'));

-- ---------------------------------------------------------------------
-- 8) rate_overrides: SELECT parity (20260716030000_rate_overrides.sql:37)
--    + override_reservation_rate RPC (línea 59 del mismo archivo). Este
--    RPC no estaba explícito en el checklist de diseño; se incluye aquí
--    por REQ-2 (paridad de escritura en procesos de recepción — cambiar
--    tarifa de una reserva ya creada NO es una de las 3 RPC de folio
--    excluidas por el límite de dinero). Ver nota en apply-progress.
-- ---------------------------------------------------------------------
drop policy if exists "rate_overrides_read" on public.rate_overrides;
create policy "rate_overrides_read" on public.rate_overrides
  for select using (public.current_user_role() in ('root', 'reception', 'reception_admin', 'accountant'));

create or replace function public.override_reservation_rate(
  p_reservation_id uuid,
  p_new_rate       numeric,
  p_reason         text
)
returns public.reservations
language plpgsql
security definer
set search_path = public
as $$
declare
  v_prev    numeric(10,2);
  v_nights  int;
  v_row     public.reservations;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado para cambiar la tarifa';
  end if;

  if p_reason is null or char_length(trim(p_reason)) = 0 then
    raise exception 'La justificación es obligatoria';
  end if;

  if p_new_rate is null or p_new_rate <= 0 then
    raise exception 'La tarifa debe ser un monto positivo';
  end if;

  select total_amount_bs, greatest(check_out_date - check_in_date, 1)
    into v_prev, v_nights
  from public.reservations
  where id = p_reservation_id;

  if not found then
    raise exception 'Reserva no encontrada';
  end if;

  update public.reservations
    set total_amount_bs = p_new_rate * v_nights
    where id = p_reservation_id
    returning * into v_row;

  insert into public.rate_overrides (
    reservation_id, previous_rate_bs, new_rate_bs, reason, changed_by
  ) values (
    p_reservation_id, v_prev, p_new_rate, p_reason, auth.uid()
  );

  return v_row;
end;
$$;

-- ---------------------------------------------------------------------
-- 9) walk_in_check_in: justificación de tarifa custom
--    (20260717000000_walkin_editable_rate.sql:93) gana paridad de
--    escritura. Restatement completo del cuerpo.
-- ---------------------------------------------------------------------
create or replace function public.walk_in_check_in(
  p_room_id      uuid,
  p_room_type_id uuid,
  p_first_name   text,
  p_last_name    text,
  p_document     text,
  p_email        text,
  p_birth_date   date,
  p_country_code text,
  p_city         text,
  p_wants_offers boolean,
  p_nights       int,
  p_rate_bs      numeric default null,
  p_rate_reason  text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_person_id       uuid;
  v_reservation_id  uuid;
  v_room_type_rate  numeric(10,2);
  v_effective_rate  numeric(10,2);
  v_status          varchar(15);
begin
  if p_nights < 1 then
    raise exception 'Las noches deben ser al menos 1';
  end if;

  -- Bloqueo pesimista de la habitación.
  select operational_status into v_status
  from public.rooms where id = p_room_id for update;
  if v_status is null then
    raise exception 'Habitación no encontrada';
  end if;
  if v_status <> 'available' then
    raise exception 'La habitación no está disponible (estado actual: %)', v_status;
  end if;

  if not exists (
    select 1 from public.room_type_options
    where room_id = p_room_id and room_type_id = p_room_type_id
  ) then
    raise exception 'El tipo seleccionado no corresponde a esta habitación';
  end if;

  select base_price_bs into v_room_type_rate
  from public.room_types where id = p_room_type_id;

  v_effective_rate := v_room_type_rate;

  if p_rate_bs is not null and p_rate_bs <> v_room_type_rate then
    if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
      raise exception 'No autorizado para cambiar la tarifa';
    end if;
    if p_rate_reason is null or char_length(trim(p_rate_reason)) = 0 then
      raise exception 'La justificación es obligatoria para cambiar la tarifa';
    end if;
    if p_rate_bs <= 0 then
      raise exception 'La tarifa debe ser un monto positivo';
    end if;
    v_effective_rate := p_rate_bs;
  end if;

  -- ¿Huésped ya conocido por documento?
  if nullif(p_document, '') is not null then
    select person_id into v_person_id
    from public.guests where passport_number = p_document;
  end if;

  if v_person_id is not null then
    -- Huésped que vuelve: actualizamos su ficha (sin borrar lo que no venga).
    update public.people set
      first_name = p_first_name,
      last_name  = p_last_name,
      email      = coalesce(nullif(p_email, ''), email),
      birth_date = coalesce(p_birth_date, birth_date)
    where id = v_person_id;
    update public.guests set
      country_code = coalesce(nullif(p_country_code, ''), country_code),
      city         = coalesce(nullif(p_city, ''), city),
      wants_offers = p_wants_offers
    where person_id = v_person_id;
  else
    -- Huésped nuevo.
    insert into public.people (first_name, last_name, email, birth_date)
    values (p_first_name, p_last_name, nullif(p_email, ''), p_birth_date)
    returning id into v_person_id;
    insert into public.guests (person_id, passport_number, country_code, city, wants_offers)
    values (
      v_person_id, nullif(p_document, ''),
      nullif(p_country_code, ''), nullif(p_city, ''), p_wants_offers
    );
  end if;

  insert into public.reservations (
    guest_id, room_id, room_type_id, check_in_date, check_out_date,
    reservation_method, payment_status, total_amount_bs, status
  ) values (
    v_person_id, p_room_id, p_room_type_id, current_date, current_date + p_nights,
    'walk-in', 'pending', v_effective_rate * p_nights, 'checked_in'
  ) returning id into v_reservation_id;

  insert into public.folios (reservation_id) values (v_reservation_id);
  update public.rooms set operational_status = 'occupied' where id = p_room_id;

  if v_effective_rate <> v_room_type_rate then
    insert into public.rate_overrides (
      reservation_id, previous_rate_bs, new_rate_bs, reason, changed_by
    ) values (
      v_reservation_id, v_room_type_rate, v_effective_rate, p_rate_reason, auth.uid()
    );
  end if;

  return v_reservation_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 10) rate_overrides parity note (20260716030000_rate_overrides.sql:37):
--     handled in section 8 above.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- 11) add_cash_movement / add_event_payment — RPC guards not present in
--     the original design checklist (found by a fresh grep during apply;
--     under-inclusion is the higher-risk failure per spec/design). Both
--     are cash_module/events_module writes (REQ-2 enumerated tables),
--     NOT folio-settlement RPCs, so parity applies. See apply-progress
--     deviations note.
--     (20260716000000_payment_methods_lookup.sql:120,
--      20260718000002_unify_event_payments_method.sql:35)
-- ---------------------------------------------------------------------
create or replace function public.add_cash_movement(
  p_kind text, p_category text, p_amount numeric,
  p_concept text, p_receipt_path text, p_payment_method text default null
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
     and not exists (select 1 from public.payment_methods where code = p_payment_method and is_active) then
    raise exception 'Forma de pago inválida: %', p_payment_method;
  end if;
  insert into public.cash_movements
    (session_id, kind, category, amount_bs, concept, receipt_path, created_by, payment_method)
    values (v_session, p_kind, p_category, p_amount, p_concept, p_receipt_path, auth.uid(), p_payment_method)
    returning * into row;
  return row;
end $$;

create or replace function public.add_event_payment(
  p_event_id uuid, p_amount numeric, p_method text, p_is_deposit boolean
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado';
  end if;
  if not exists (
    select 1 from public.payment_methods where code = p_method and is_active
  ) then
    raise exception 'Forma de pago inválida: %', p_method;
  end if;

  insert into public.event_payments (event_id, amount_bs, method, is_deposit, created_by)
    values (p_event_id, p_amount, p_method, coalesce(p_is_deposit, false), auth.uid());

  if p_method = 'EFECTIVO' then
    perform public.add_cash_movement(
      'income', 'evento', p_amount,
      case when p_is_deposit then 'Adelanto evento' else 'Pago evento' end,
      null
    );
  end if;
end $$;

-- =====================================================================
-- MONEY BOUNDARY (REQ-3) — EXPLICITLY NOT TOUCHED, DO NOT ADD
-- reception_admin HERE:
--   - check_out_room        (20260718000000_lock_down_reservations_folios.sql:42)
--   - add_folio_charge      (20260718000000_lock_down_reservations_folios.sql:122)
--   - add_folio_product_charge (20260718000000_lock_down_reservations_folios.sql:178)
-- These stay guarded by ('root', 'reception', 'accountant') only.
-- folios/folio_charges keep SELECT-only for reception_admin (section 7).
--
-- OUT OF SCOPE (REQ-5) — NOT TOUCHED, root/accountant-only:
--   - login_events   (20260703230000_login_events.sql)
--   - time_entries   (20260703240000_time_entries.sql)
--   - employees module / link_employee_user (20260703110000, 20260703250000)
-- =====================================================================
