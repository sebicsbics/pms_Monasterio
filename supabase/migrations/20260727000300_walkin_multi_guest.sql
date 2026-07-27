-- =====================================================================
-- Check-in multi-huésped en WALK-IN (change: walkin-multi-guest).
--
-- El check-in desde Llegadas ya registra acompañantes (20260727000200).
-- El walk-in desde el tablero seguía registrando solo al titular. Se
-- agrega la misma capacidad, extrayendo la lógica de acompañantes a un
-- helper interno compartido para evitar duplicación/drift.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) add_reservation_companions: helper INTERNO (no se otorga a
--    anon/authenticated — se llama solo desde los wrappers SECURITY
--    DEFINER de abajo, mismo patrón que apply_rate_change). Registra el
--    perfil completo de cada acompañante, con dedupe por documento.
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
        country_code = coalesce(nullif(c->>'country_code', ''), country_code),
        city         = coalesce(nullif(c->>'city', ''), city)
      where person_id = v_person;
    else
      insert into public.people (first_name, last_name, birth_date)
      values (
        trim(c->>'first_name'), trim(c->>'last_name'),
        nullif(c->>'birth_date', '')::date
      )
      returning id into v_person;
      insert into public.guests (person_id, passport_number, country_code, city)
      values (
        v_person, v_doc,
        nullif(c->>'country_code', ''), nullif(c->>'city', '')
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
-- 2) check_in_reservation_with_guests: usa el helper (antes tenía el loop
--    inline). Mantiene el tope de ocupación y el check-in del titular.
-- ---------------------------------------------------------------------
create or replace function public.check_in_reservation_with_guests(
  p_reservation_id uuid,
  p_document       text,
  p_birth_date     date,
  p_country_code   text,
  p_city           text,
  p_wants_offers   boolean,
  p_companions     jsonb default '[]'::jsonb
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_companions jsonb := coalesce(p_companions, '[]'::jsonb);
  v_num_guests int;
begin
  select num_guests into v_num_guests
  from public.reservations where id = p_reservation_id;

  if v_num_guests is not null
     and jsonb_array_length(v_companions) + 1 > v_num_guests then
    raise exception 'La reserva admite % huésped(es); estás registrando %',
      v_num_guests, jsonb_array_length(v_companions) + 1;
  end if;

  perform public.check_in_reservation(
    p_reservation_id, p_document, p_birth_date, p_country_code, p_city, p_wants_offers
  );

  perform public.add_reservation_companions(p_reservation_id, v_companions);
end;
$$;

-- ---------------------------------------------------------------------
-- 3) walk_in_check_in_with_guests: hace el walk-in del titular
--    reutilizando walk_in_check_in y registra los acompañantes. Tope de
--    ocupación contra room_types.max_occupancy del tipo elegido.
-- ---------------------------------------------------------------------
create or replace function public.walk_in_check_in_with_guests(
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
  p_rate_reason  text default null,
  p_companions   jsonb default '[]'::jsonb
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_companions jsonb := coalesce(p_companions, '[]'::jsonb);
  v_max        int;
  v_res        uuid;
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

  perform public.add_reservation_companions(v_res, v_companions);

  return v_res;
end;
$$;

grant execute on function public.walk_in_check_in_with_guests(
  uuid, uuid, text, text, text, text, date, text, text, boolean, int, numeric, text, jsonb
) to authenticated;
