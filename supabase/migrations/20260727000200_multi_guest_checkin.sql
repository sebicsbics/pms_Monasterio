-- =====================================================================
-- Check-in multi-huésped (change: multi-guest-checkin).
--
-- Hasta ahora el check-in solo capturaba el perfil del titular
-- (reservation.guest_id). Ahora se pueden registrar TODOS los huéspedes de
-- la habitación con perfil completo (documento, nacimiento, país, ciudad).
--
-- Modelo: reservation.guest_id sigue siendo el TITULAR (fuente única, no se
-- toca). Los acompañantes se enlazan en la tabla nueva reservation_guests.
-- La unicidad de documento es a nivel de aplicación (reuse-by-document),
-- mismo patrón que el titular (check_in_reservation) y walk_in_check_in —
-- no se agrega índice único sobre guests.passport_number para no romper
-- datos históricos cargados.
-- =====================================================================

create table if not exists public.reservation_guests (
  id             uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  person_id      uuid not null references public.people(id),
  created_at     timestamptz not null default now(),
  unique (reservation_id, person_id)
);

alter table public.reservation_guests enable row level security;

drop policy if exists "reservation_guests_read" on public.reservation_guests;
create policy "reservation_guests_read" on public.reservation_guests
  for select using (
    public.current_user_role() in ('root', 'reception', 'reception_admin', 'accountant')
  );

-- ---------------------------------------------------------------------
-- check_in_reservation_with_guests: hace el check-in del titular
-- reutilizando check_in_reservation (valida estado, ocupa habitación, abre
-- folio) y además registra los acompañantes. Atómico (una sola función).
--
-- p_companions: jsonb array. Cada elemento:
--   { first_name, last_name, document, birth_date, country_code, city }
-- first_name/last_name son obligatorios; el resto opcional. Si el documento
-- ya pertenece a un huésped existente, se reutiliza esa persona (dedupe).
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
  c            jsonb;
  v_doc        text;
  v_person     uuid;
begin
  -- Tope de ocupación: titular (1) + acompañantes no puede exceder
  -- num_guests de la reserva.
  select num_guests into v_num_guests
  from public.reservations where id = p_reservation_id;

  if v_num_guests is not null
     and jsonb_array_length(v_companions) + 1 > v_num_guests then
    raise exception 'La reserva admite % huésped(es); estás registrando %',
      v_num_guests, jsonb_array_length(v_companions) + 1;
  end if;

  -- Titular: reutiliza la RPC existente (valida 'confirmed', ocupa
  -- habitación, abre folio, y rechaza documento de otro huésped).
  perform public.check_in_reservation(
    p_reservation_id, p_document, p_birth_date, p_country_code, p_city, p_wants_offers
  );

  for c in select value from jsonb_array_elements(v_companions) as t(value)
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
      -- Huésped conocido por documento: actualizar ficha sin borrar lo que
      -- no venga.
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

grant execute on function public.check_in_reservation_with_guests(
  uuid, text, date, text, text, boolean, jsonb
) to authenticated;
