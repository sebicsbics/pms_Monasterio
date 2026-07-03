-- =====================================================================
-- FASE 5b — Perfil de huésped (email, cumpleaños, país, ciudad, consentimiento)
-- + deduplicación por DOCUMENTO en el walk-in.
-- No agrega columnas: people/guests ya tienen los campos. Solo:
--   1) documento único (índice parcial, compatible con la web)
--   2) walk_in_check_in v2: captura perfil y reutiliza huésped por documento
-- =====================================================================

-- El documento identifica al huésped. Único cuando no es nulo
-- (los huéspedes de la web sin documento quedan permitidos).
create unique index if not exists guests_passport_unique
  on public.guests (passport_number)
  where passport_number is not null;

-- Reemplazamos la función anterior por la versión con perfil completo.
drop function if exists public.walk_in_check_in(uuid, uuid, text, text, text, int);

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
  p_nights       int
) returns uuid
language plpgsql
as $$
declare
  v_person_id      uuid;
  v_reservation_id uuid;
  v_rate           numeric(10,2);
  v_status         varchar(15);
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

  select base_price_bs into v_rate
  from public.room_types where id = p_room_type_id;

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
    'walk-in', 'pending', v_rate * p_nights, 'checked_in'
  ) returning id into v_reservation_id;

  insert into public.folios (reservation_id) values (v_reservation_id);
  update public.rooms set operational_status = 'occupied' where id = p_room_id;

  return v_reservation_id;
end;
$$;

-- Permisos de ejecución (guardado para local).
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant execute on function public.walk_in_check_in(uuid,uuid,text,text,text,text,date,text,text,boolean,int)
      to anon, authenticated;
  end if;
end$$;
