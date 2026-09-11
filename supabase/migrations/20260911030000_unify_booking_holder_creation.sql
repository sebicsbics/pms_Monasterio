-- =====================================================================
-- Unificación de alta de booking/holder + drop de triggers de respaldo.
-- (change: reservation-booker-vs-guest, PR2b-db, 5/8, 2 de 2).
--
-- POR QUÉ
-- Con 20260911020000 ya aplicada, el check-in resuelve titular y confirma
-- correctamente. Esta migración cierra la nota del orquestador tras
-- PR2a-db: create_bulk_reservation ya armaba booking+holder a mano, pero
-- create_reservation seguía dependiendo del trigger de PR1
-- (`reservations_create_holder`) y walk_in_check_in ni siquiera seteaba
-- `booking_id` (dependía de `reservations_create_booking`). Dos mecanismos
-- de alta de holder al mismo tiempo es justo el tipo de inconsistencia que
-- este cambio busca eliminar.
--
--   1) walk_in_check_in/_with_guests: crean la booking y el holder A MANO
--      (igual que las rutas de alta), con confirmed_at = now() (el walk-in
--      ES el check-in, no hay estadía "pendiente de confirmar").
--   2) create_reservation: se reescribe para insertar el holder a mano
--      (dejaba de hacerlo el trigger).
--   3) create_bulk_reservation: confirmed_at explícito (NULL) en el
--      insert del holder precargado -- mismo comportamiento que ya tenía
--      por default de columna, ahora explícito para que quede documentado
--      junto al resto de las rutas de alta.
--   4) Ahora que TODA ruta de alta arma booking+holder explícitamente, los
--      triggers de respaldo de PR1 (`reservations_create_booking`,
--      `reservations_create_holder`) ya no hacen falta -- se dropean junto
--      con sus funciones. `seed.sql` se actualiza para insertar
--      bookings/holder a mano también, porque `db reset` corre las
--      migraciones ANTES del seed y ya no hay trigger que lo resuelva.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) walk_in_check_in: arma booking + holder A MANO (confirmed_at =
--    now(), es un check-in inmediato). Misma aridad -> CREATE OR REPLACE.
-- ---------------------------------------------------------------------
create or replace function public.walk_in_check_in(
  p_room_id uuid, p_room_type_id uuid, p_first_name text, p_last_name text,
  p_document text, p_email text, p_birth_date date, p_country_code text,
  p_city text, p_wants_offers boolean, p_nights integer,
  p_rate_bs numeric default null::numeric,
  p_rate_reason text default null::text
) returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_person_id       uuid;
  v_booking_id      uuid;
  v_reservation_id  uuid;
  v_room_type_rate  numeric(10,2);
  v_status          varchar(15);
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado para hacer check-in';
  end if;

  if p_nights < 1 then
    raise exception 'Las noches deben ser al menos 1';
  end if;

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
  end if;

  if nullif(p_document, '') is not null then
    select person_id into v_person_id
    from public.guests where passport_number = p_document;
  end if;

  if v_person_id is not null then
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
    insert into public.people (first_name, last_name, email, birth_date)
    values (p_first_name, p_last_name, nullif(p_email, ''), p_birth_date)
    returning id into v_person_id;
    insert into public.guests (person_id, passport_number, country_code, city, wants_offers)
    values (
      v_person_id, nullif(p_document, ''),
      nullif(p_country_code, ''), nullif(p_city, ''), p_wants_offers
    );
  end if;

  -- Booking del walk-in: el contacto ES el huésped que se presentó
  -- (nadie más "reservó" por él).
  insert into public.bookings (contact_person_id, payer_mode)
  values (v_person_id, 'each_stay')
  returning id into v_booking_id;

  insert into public.reservations (
    guest_id, room_id, room_type_id, check_in_date, check_out_date,
    reservation_method, payment_status, total_amount_bs, status, booking_id
  ) values (
    v_person_id, p_room_id, p_room_type_id, current_date, current_date + p_nights,
    'walk-in', 'pending', v_room_type_rate * p_nights, 'checked_in', v_booking_id
  ) returning id into v_reservation_id;

  -- Titular explícito: el walk-in ES el check-in, no hay estadía
  -- "pendiente de confirmar".
  insert into public.reservation_guests (reservation_id, person_id, role, confirmed_at)
  values (v_reservation_id, v_person_id, 'holder', now());

  insert into public.folios (reservation_id) values (v_reservation_id);
  update public.rooms set operational_status = 'occupied' where id = p_room_id;

  if p_rate_bs is not null and p_rate_bs <> v_room_type_rate then
    perform public.apply_rate_change(
      v_reservation_id, p_room_type_id, v_room_type_rate, p_nights, p_rate_bs, p_rate_reason
    );
  end if;

  return v_reservation_id;
end;
$function$;

revoke execute on function public.walk_in_check_in(
  uuid, uuid, text, text, text, text, date, text, text, boolean, integer, numeric, text
) from public, anon;
grant execute on function public.walk_in_check_in(
  uuid, uuid, text, text, text, text, date, text, text, boolean, integer, numeric, text
) to authenticated;

-- ---------------------------------------------------------------------
-- 2) walk_in_check_in_with_guests: mismo cuerpo salvo el dual-write de
--    agencia/canal a bookings (walk_in_check_in ya arma booking+holder).
--    Misma aridad -> CREATE OR REPLACE.
-- ---------------------------------------------------------------------
create or replace function public.walk_in_check_in_with_guests(
  p_room_id         uuid,
  p_room_type_id    uuid,
  p_first_name      text,
  p_last_name       text,
  p_document        text,
  p_email           text,
  p_birth_date      date,
  p_country_code    text,
  p_city            text,
  p_wants_offers    boolean,
  p_nights          integer,
  p_rate_bs         numeric default null,
  p_rate_reason     text default null,
  p_origin_city     text default null,
  p_travel_purpose  text default null,
  p_occupation      text default null,
  p_transport_means text default null,
  p_companions      jsonb default '[]'::jsonb,
  p_agency_name     text default null,
  p_channel_code    text default null
) returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_companions jsonb := coalesce(p_companions, '[]'::jsonb);
  v_max        int;
  v_res        uuid;
  v_guest_id   uuid;
  v_booking_id uuid;
begin
  select max_occupancy into v_max
  from public.room_types where id = p_room_type_id;

  if v_max is not null and jsonb_array_length(v_companions) + 1 > v_max then
    raise exception 'El tipo elegido admite hasta % personas', v_max;
  end if;

  v_res := public.walk_in_check_in(
    p_room_id, p_room_type_id, p_first_name, p_last_name, p_document, p_email,
    p_birth_date, p_country_code, p_city, p_wants_offers, p_nights,
    p_rate_bs, p_rate_reason
  );

  select guest_id, booking_id into v_guest_id, v_booking_id
  from public.reservations where id = v_res;

  update public.guests set
    origin_city     = coalesce(nullif(p_origin_city, ''), origin_city),
    travel_purpose  = coalesce(nullif(p_travel_purpose, ''), travel_purpose),
    occupation      = coalesce(nullif(p_occupation, ''), occupation),
    transport_means = coalesce(nullif(p_transport_means, ''), transport_means)
  where person_id = v_guest_id;

  perform public.add_reservation_companions(v_res, v_companions);

  update public.reservations set
    agency_name  = nullif(trim(p_agency_name), ''),
    channel_code = nullif(p_channel_code, '')
  where id = v_res;

  update public.bookings set
    agency_name  = coalesce(nullif(trim(p_agency_name), ''), agency_name),
    channel_code = coalesce(nullif(p_channel_code, ''), channel_code)
  where id = v_booking_id;

  return v_res;
end;
$function$;

revoke execute on function public.walk_in_check_in_with_guests(
  uuid, uuid, text, text, text, text, date, text, text, boolean, integer,
  numeric, text, text, text, text, text, jsonb, text, text
) from public, anon;

grant execute on function public.walk_in_check_in_with_guests(
  uuid, uuid, text, text, text, text, date, text, text, boolean, integer,
  numeric, text, text, text, text, text, jsonb, text, text
) to authenticated;

-- ---------------------------------------------------------------------
-- 3) create_reservation: el holder lo insertaba el trigger de PR1
--    (reservations_create_holder). Se reescribe para insertarlo A MANO
--    (confirmed_at NULL: precargado, se confirma recién en el check-in).
--    Misma firma -> CREATE OR REPLACE.
-- ---------------------------------------------------------------------
create or replace function public.create_reservation(
  p_room_id       uuid,
  p_room_type_id  uuid,
  p_first_name    text,
  p_last_name     text,
  p_phone         text,
  p_email         text,
  p_check_in      date,
  p_check_out     date,
  p_num_guests    int,
  p_method        text,
  p_rate_bs       numeric default null,
  p_reason        text default null,
  p_contact_stays boolean default true
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_person_id      uuid;
  v_booking_id     uuid;
  v_guest_id       uuid;
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

  if nullif(p_email, '') is not null then
    select id into v_person_id from public.people where email = p_email;
  end if;

  if v_person_id is not null then
    update public.people set
      first_name = p_first_name,
      last_name  = p_last_name,
      phone      = coalesce(nullif(p_phone, ''), phone)
    where id = v_person_id;
  else
    insert into public.people (first_name, last_name, email, phone)
    values (p_first_name, p_last_name, nullif(p_email, ''), nullif(p_phone, ''))
    returning id into v_person_id;
  end if;

  insert into public.bookings (contact_person_id) values (v_person_id)
  returning id into v_booking_id;

  if p_contact_stays then
    insert into public.guests (person_id) values (v_person_id)
      on conflict (person_id) do nothing;
    v_guest_id := v_person_id;
  else
    v_guest_id := null;
  end if;

  v_nights := p_check_out - p_check_in;

  insert into public.reservations (
    guest_id, room_id, room_type_id, check_in_date, check_out_date,
    reservation_method, payment_status, total_amount_bs, status, num_guests,
    booking_id
  ) values (
    v_guest_id, p_room_id, p_room_type_id, p_check_in, p_check_out,
    p_method, 'pending', v_rate * v_nights, 'confirmed', p_num_guests,
    v_booking_id
  ) returning id into v_reservation_id;

  -- Titular explícito, precargado (confirmed_at NULL: recién se confirma
  -- en el check-in). Ya no depende del trigger de PR1 (se dropea abajo).
  if v_guest_id is not null then
    insert into public.reservation_guests (reservation_id, person_id, role, confirmed_at)
    values (v_reservation_id, v_guest_id, 'holder', null);
  end if;

  if p_rate_bs is not null and p_rate_bs <> v_rate then
    if p_reason is null or char_length(trim(p_reason)) = 0 then
      raise exception 'La justificación es obligatoria para cambiar la tarifa';
    end if;
    if p_rate_bs <= 0 then
      raise exception 'La tarifa debe ser un monto positivo';
    end if;
    perform public.apply_rate_change(
      v_reservation_id, p_room_type_id, v_rate, v_nights, p_rate_bs, p_reason
    );
  end if;

  return v_reservation_id;
end;
$$;

revoke execute on function public.create_reservation(
  uuid, uuid, text, text, text, text, date, date, int, text, numeric, text, boolean
) from public, anon;
grant execute on function public.create_reservation(
  uuid, uuid, text, text, text, text, date, date, int, text, numeric, text, boolean
) to authenticated;

-- ---------------------------------------------------------------------
-- 4) create_bulk_reservation: el holder precargado también queda
--    confirmed_at NULL (recién se confirma en el check-in) -- antes no
--    seteaba la columna porque no existía. Misma firma.
-- ---------------------------------------------------------------------
create or replace function public.create_bulk_reservation(
  p_rooms      jsonb,
  p_first_name text,
  p_last_name  text,
  p_phone      text,
  p_email      text,
  p_check_in   date,
  p_check_out  date,
  p_method     text,
  p_rate_bs    numeric default null,
  p_reason     text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_person_id      uuid;
  v_booking_id     uuid;
  v_nights         int;
  v_created        jsonb := '[]'::jsonb;
  v_failed         jsonb := '[]'::jsonb;
  elem             jsonb;
  v_room_id        uuid;
  v_room_type_id   uuid;
  v_guests         int;
  v_rate           numeric(10,2);
  v_reservation_id uuid;
  v_occupants      jsonb;
  occ              jsonb;
  v_doc            text;
  v_occ_person     uuid;
  v_is_first       boolean;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado para crear reservas';
  end if;

  if p_check_out <= p_check_in then
    raise exception 'La fecha de salida debe ser posterior a la de entrada';
  end if;
  if nullif(trim(p_phone), '') is null and nullif(trim(p_email), '') is null then
    raise exception 'Se requiere al menos un contacto (celular o correo)';
  end if;
  if jsonb_array_length(coalesce(p_rooms, '[]'::jsonb)) = 0 then
    raise exception 'Seleccioná al menos una habitación';
  end if;

  v_nights := p_check_out - p_check_in;

  if nullif(p_email, '') is not null then
    select id into v_person_id from public.people where email = p_email;
  end if;

  if v_person_id is not null then
    update public.people set
      first_name = p_first_name,
      last_name  = p_last_name,
      phone      = coalesce(nullif(p_phone, ''), phone)
    where id = v_person_id;
  else
    insert into public.people (first_name, last_name, email, phone)
    values (p_first_name, p_last_name, nullif(p_email, ''), nullif(p_phone, ''))
    returning id into v_person_id;
  end if;

  insert into public.bookings (contact_person_id) values (v_person_id)
  returning id into v_booking_id;

  for elem in select value from jsonb_array_elements(p_rooms) as t(value)
  loop
    v_room_id      := (elem->>'room_id')::uuid;
    v_room_type_id := (elem->>'room_type_id')::uuid;
    v_guests       := coalesce((elem->>'num_guests')::int, 1);
    begin
      if v_guests < 1 then
        raise exception 'Cada habitación necesita al menos 1 persona';
      end if;
      if v_guests > 20 then
        raise exception 'Ocupación implausible (% personas)', v_guests;
      end if;

      select rt.base_price_bs into v_rate
      from public.room_type_options o
      join public.room_types rt on rt.id = o.room_type_id
      where o.room_id = v_room_id and o.room_type_id = v_room_type_id;

      if v_rate is null then
        raise exception 'El tipo seleccionado no corresponde a la habitación';
      end if;

      perform 1 from public.rooms where id = v_room_id for update;
      if exists (
        select 1 from public.reservations r
        where r.room_id = v_room_id
          and r.status in ('confirmed', 'checked_in')
          and r.check_in_date < p_check_out
          and p_check_in < r.check_out_date
      ) then
        raise exception 'La habitación ya no está disponible para esas fechas';
      end if;

      insert into public.reservations (
        guest_id, room_id, room_type_id, check_in_date, check_out_date,
        reservation_method, payment_status, total_amount_bs, status, num_guests,
        booking_id
      ) values (
        null, v_room_id, v_room_type_id, p_check_in, p_check_out,
        p_method, 'pending', v_rate * v_nights, 'confirmed', v_guests,
        v_booking_id
      ) returning id into v_reservation_id;

      v_occupants := coalesce(elem->'occupants', '[]'::jsonb);
      v_is_first := true;
      for occ in select value from jsonb_array_elements(v_occupants) as t(value)
      loop
        if coalesce(trim(occ->>'first_name'), '') = ''
           or coalesce(trim(occ->>'last_name'), '') = '' then
          raise exception 'Cada huésped requiere nombre y apellido';
        end if;

        v_doc := nullif(trim(occ->>'document'), '');
        v_occ_person := null;
        if v_doc is not null then
          select person_id into v_occ_person
          from public.guests where passport_number = v_doc;
        end if;

        if v_occ_person is not null then
          update public.people set
            first_name = trim(occ->>'first_name'),
            last_name  = trim(occ->>'last_name'),
            birth_date = coalesce(nullif(occ->>'birth_date', '')::date, birth_date)
          where id = v_occ_person;
        else
          insert into public.people (first_name, last_name, birth_date)
          values (
            trim(occ->>'first_name'), trim(occ->>'last_name'),
            nullif(occ->>'birth_date', '')::date
          )
          returning id into v_occ_person;
          insert into public.guests (person_id, passport_number)
          values (v_occ_person, v_doc);
        end if;

        if v_is_first then
          update public.reservations set guest_id = v_occ_person
            where id = v_reservation_id;
          insert into public.reservation_guests (reservation_id, person_id, role, confirmed_at)
          values (v_reservation_id, v_occ_person, 'holder', null)
          on conflict (reservation_id, person_id) do update set role = 'holder';
          v_is_first := false;
        else
          insert into public.reservation_guests (reservation_id, person_id, role, confirmed_at)
          values (v_reservation_id, v_occ_person, 'companion', null)
          on conflict (reservation_id, person_id) do nothing;
        end if;
      end loop;

      if p_rate_bs is not null and p_rate_bs <> v_rate then
        if p_reason is null or char_length(trim(p_reason)) = 0 then
          raise exception 'La justificación es obligatoria para cambiar la tarifa';
        end if;
        if p_rate_bs <= 0 then
          raise exception 'La tarifa debe ser un monto positivo';
        end if;
        perform public.apply_rate_change(
          v_reservation_id, v_room_type_id, v_rate, v_nights, p_rate_bs, p_reason
        );
      end if;

      v_created := v_created || to_jsonb(v_reservation_id::text);
    exception when others then
      v_failed := v_failed || jsonb_build_object('room_id', v_room_id, 'error', sqlerrm);
    end;
  end loop;

  return jsonb_build_object('created', v_created, 'failed', v_failed);
end;
$$;

revoke execute on function public.create_bulk_reservation(
  jsonb, text, text, text, text, date, date, text, numeric, text
) from public, anon;
grant execute on function public.create_bulk_reservation(
  jsonb, text, text, text, text, date, date, text, numeric, text
) to authenticated;

-- ---------------------------------------------------------------------
-- 5) Unificación: toda ruta de alta arma booking+holder a mano ->
--    dropear los triggers de respaldo de PR1 y sus funciones.
-- ---------------------------------------------------------------------
drop trigger if exists reservations_create_booking on public.reservations;
drop trigger if exists reservations_create_holder on public.reservations;
drop function if exists public._create_booking_for_new_reservation();
drop function if exists public._create_holder_for_new_reservation();
