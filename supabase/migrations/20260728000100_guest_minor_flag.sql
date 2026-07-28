-- =====================================================================
-- Huésped menor de 14 (change: guest-minor-flag).
--
-- Los acompañantes menores de 14 años no cargan la ficha completa de
-- adulto (documento, procedencia, motivo de viaje, ocupación, transporte).
-- Se agrega guests.is_minor para marcarlos; la UI oculta esos campos
-- cuando está tildado. Solo aplica a acompañantes (el titular es adulto).
--
-- Nota: guests.city (ciudad de residencia, para analítica/SIG) y
-- guests.origin_city (ciudad de procedencia, requisito legal) son campos
-- DISTINTOS y se conservan ambos.
-- =====================================================================

alter table public.guests
  add column if not exists is_minor boolean not null default false;

comment on column public.guests.is_minor is
  'Huésped menor de 14 años: no se le pide la ficha completa de adulto '
  '(documento, procedencia, motivo de viaje, ocupación, transporte).';

-- add_reservation_companions: persiste is_minor de cada acompañante.
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
  v_minor  boolean;
  v_person uuid;
begin
  for c in
    select value from jsonb_array_elements(coalesce(p_companions, '[]'::jsonb)) as t(value)
  loop
    if coalesce(trim(c->>'first_name'), '') = ''
       or coalesce(trim(c->>'last_name'), '') = '' then
      raise exception 'Cada huésped requiere nombre y apellido';
    end if;

    v_doc   := nullif(trim(c->>'document'), '');
    v_minor := coalesce((c->>'is_minor')::boolean, false);

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
        transport_means = coalesce(nullif(c->>'transport_means', ''), transport_means),
        is_minor        = v_minor
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
        origin_city, travel_purpose, occupation, transport_means, is_minor
      )
      values (
        v_person, v_doc,
        nullif(c->>'country_code', ''), nullif(c->>'city', ''),
        nullif(c->>'origin_city', ''), nullif(c->>'travel_purpose', ''),
        nullif(c->>'occupation', ''), nullif(c->>'transport_means', ''), v_minor
      );
    end if;

    insert into public.reservation_guests (reservation_id, person_id)
    values (p_reservation_id, v_person)
    on conflict (reservation_id, person_id) do nothing;
  end loop;
end;
$$;

revoke execute on function public.add_reservation_companions(uuid, jsonb) from public, anon, authenticated;
