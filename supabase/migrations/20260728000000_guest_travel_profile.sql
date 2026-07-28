-- =====================================================================
-- Perfil de viaje del huésped (change: guest-travel-profile).
--
-- El check-in recolectaba datos básicos (documento, país, ciudad, fecha de
-- nacimiento). Se agregan 4 campos de registro turístico, para TODOS los
-- huéspedes (titular + acompañantes):
--   - origin_city    : ciudad de procedencia (distinta de `city` =
--                       residencia/ciudad declarada).
--   - travel_purpose : motivo de viaje (Turismo/Trabajo/...; texto libre).
--   - occupation     : profesión / ocupación.
--   - transport_means: medio de transporte con el que llegó.
--
-- Se cablean en los 3 puntos donde se escribe una ficha de guest:
--   - check_in_reservation_with_guests (titular de Llegadas)
--   - walk_in_check_in_with_guests     (titular walk-in del tablero)
--   - add_reservation_companions       (todos los acompañantes)
--
-- Los titulares se actualizan DESPUÉS del check-in base (update sobre el
-- guest de la reserva), para no tener que reescribir check_in_reservation /
-- walk_in_check_in. Aditivo, no destructivo.
-- =====================================================================

alter table public.guests
  add column if not exists origin_city     text,
  add column if not exists travel_purpose  text,
  add column if not exists occupation      text,
  add column if not exists transport_means text;

comment on column public.guests.origin_city is 'Ciudad de procedencia (origen del viaje).';
comment on column public.guests.travel_purpose is 'Motivo de viaje (Turismo/Trabajo/Negocios/...).';
comment on column public.guests.occupation is 'Profesión / ocupación del huésped.';
comment on column public.guests.transport_means is 'Medio de transporte con el que llegó.';

-- ---------------------------------------------------------------------
-- 1) add_reservation_companions: escribe también los 4 campos de viaje.
-- ---------------------------------------------------------------------
create or replace function public.add_reservation_companions(
  p_reservation_id uuid,
  p_companions     jsonb
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c        jsonb;
  v_doc    text;
  v_person uuid;
begin
  for c in
    select value from jsonb_array_elements(coalesce(p_companions, '[]'::jsonb)) as t(value)
  loop
    if coalesce(trim(c->>'first_name'), '') = ''
       or coalesce(trim(c->>'last_name'), '') = '' then
      raise exception 'Cada huésped requiere nombre y apellido';
    end if;

    v_doc := nullif(trim(c->>'document'), '');

    v_person := null;
    if v_doc is not null then
      select person_id into v_person
      from public.guests where passport_number = v_doc;
    end if;

    if v_person is not null then
      update public.people set
        first_name = trim(c->>'first_name'),
        last_name  = trim(c->>'last_name'),
        birth_date = coalesce(nullif(c->>'birth_date', '')::date, birth_date)
      where id = v_person;
      update public.guests set
        country_code    = coalesce(nullif(c->>'country_code', ''), country_code),
        city            = coalesce(nullif(c->>'city', ''), city),
        origin_city     = coalesce(nullif(c->>'origin_city', ''), origin_city),
        travel_purpose  = coalesce(nullif(c->>'travel_purpose', ''), travel_purpose),
        occupation      = coalesce(nullif(c->>'occupation', ''), occupation),
        transport_means = coalesce(nullif(c->>'transport_means', ''), transport_means)
      where person_id = v_person;
    else
      insert into public.people (first_name, last_name, birth_date)
      values (
        trim(c->>'first_name'), trim(c->>'last_name'),
        nullif(c->>'birth_date', '')::date
      )
      returning id into v_person;
      insert into public.guests (
        person_id, passport_number, country_code, city,
        origin_city, travel_purpose, occupation, transport_means
      )
      values (
        v_person, v_doc,
        nullif(c->>'country_code', ''), nullif(c->>'city', ''),
        nullif(c->>'origin_city', ''), nullif(c->>'travel_purpose', ''),
        nullif(c->>'occupation', ''), nullif(c->>'transport_means', '')
      );
    end if;

    insert into public.reservation_guests (reservation_id, person_id)
    values (p_reservation_id, v_person)
    on conflict (reservation_id, person_id) do nothing;
  end loop;
end;
$$;

revoke execute on function public.add_reservation_companions(uuid, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2) check_in_reservation_with_guests: +4 params del titular. Drop del
--    overload viejo (7 args) antes de crear el nuevo (11) — mismo overload
--    trap documentado en 20260717000000_walkin_editable_rate.sql.
-- ---------------------------------------------------------------------
drop function if exists public.check_in_reservation_with_guests(
  uuid, text, date, text, text, boolean, jsonb
);

create or replace function public.check_in_reservation_with_guests(
  p_reservation_id  uuid,
  p_document        text,
  p_birth_date      date,
  p_country_code    text,
  p_city            text,
  p_wants_offers    boolean,
  p_origin_city     text default null,
  p_travel_purpose  text default null,
  p_occupation      text default null,
  p_transport_means text default null,
  p_companions      jsonb default '[]'::jsonb
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_companions jsonb := coalesce(p_companions, '[]'::jsonb);
  v_num_guests int;
  v_guest_id   uuid;
begin
  select num_guests, guest_id into v_num_guests, v_guest_id
  from public.reservations where id = p_reservation_id;

  if v_num_guests is not null
     and jsonb_array_length(v_companions) + 1 > v_num_guests then
    raise exception 'La reserva admite % huésped(es); estás registrando %',
      v_num_guests, jsonb_array_length(v_companions) + 1;
  end if;

  perform public.check_in_reservation(
    p_reservation_id, p_document, p_birth_date, p_country_code, p_city, p_wants_offers
  );

  -- Perfil de viaje del titular (después del check-in base).
  update public.guests set
    origin_city     = coalesce(nullif(p_origin_city, ''), origin_city),
    travel_purpose  = coalesce(nullif(p_travel_purpose, ''), travel_purpose),
    occupation      = coalesce(nullif(p_occupation, ''), occupation),
    transport_means = coalesce(nullif(p_transport_means, ''), transport_means)
  where person_id = v_guest_id;

  perform public.add_reservation_companions(p_reservation_id, v_companions);
end;
$$;

grant execute on function public.check_in_reservation_with_guests(
  uuid, text, date, text, text, boolean, text, text, text, text, jsonb
) to authenticated;

-- ---------------------------------------------------------------------
-- 3) walk_in_check_in_with_guests: +4 params del titular. Drop del overload
--    viejo (14 args) antes de crear el nuevo (18).
-- ---------------------------------------------------------------------
drop function if exists public.walk_in_check_in_with_guests(
  uuid, uuid, text, text, text, text, date, text, text, boolean, int, numeric, text, jsonb
);

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
  p_nights          int,
  p_rate_bs         numeric default null,
  p_rate_reason     text default null,
  p_origin_city     text default null,
  p_travel_purpose  text default null,
  p_occupation      text default null,
  p_transport_means text default null,
  p_companions      jsonb default '[]'::jsonb
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_companions jsonb := coalesce(p_companions, '[]'::jsonb);
  v_max        int;
  v_res        uuid;
  v_guest_id   uuid;
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

  select guest_id into v_guest_id from public.reservations where id = v_res;

  update public.guests set
    origin_city     = coalesce(nullif(p_origin_city, ''), origin_city),
    travel_purpose  = coalesce(nullif(p_travel_purpose, ''), travel_purpose),
    occupation      = coalesce(nullif(p_occupation, ''), occupation),
    transport_means = coalesce(nullif(p_transport_means, ''), transport_means)
  where person_id = v_guest_id;

  perform public.add_reservation_companions(v_res, v_companions);

  return v_res;
end;
$$;

grant execute on function public.walk_in_check_in_with_guests(
  uuid, uuid, text, text, text, text, date, text, text, boolean, int, numeric, text,
  text, text, text, text, jsonb
) to authenticated;
