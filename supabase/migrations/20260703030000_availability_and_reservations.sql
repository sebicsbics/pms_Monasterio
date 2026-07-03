-- =====================================================================
-- FASE 4 — Disponibilidad + creación de reservas (multicanal).
-- =====================================================================

-- Cuántas personas en la reserva (no existía). Aditivo, seguro para la web.
alter table public.reservations
  add column if not exists num_guests int check (num_guests is null or num_guests > 0);

-- =====================================================================
-- FUNCIÓN: habitaciones disponibles para un rango de fechas y nº de personas.
-- Una habitación está disponible si:
--   - está activa (ciclo de vida) y no en mantenimiento
--   - tiene al menos un tipo ofrecible con capacidad >= personas
--   - NO tiene ninguna reserva (confirmed/checked_in) que se solape
-- Devuelve, por habitación, sus tipos aptos (jsonb) para que recepción elija.
-- =====================================================================
create or replace function public.available_rooms(
  p_check_in  date,
  p_check_out date,
  p_pax       int
) returns table (
  room_id        uuid,
  room_number    text,
  floor          int,
  zone           text,
  suitable_types jsonb
)
language sql
stable
as $$
  select
    rm.id,
    rm.room_number::text,
    rm.floor,
    rm.zone::text,
    jsonb_agg(
      jsonb_build_object(
        'id', rt.id,
        'name', rt.name,
        'basePriceBs', rt.base_price_bs,
        'maxOccupancy', rt.max_occupancy
      ) order by rt.base_price_bs
    ) as suitable_types
  from public.rooms rm
  join public.room_type_options o on o.room_id = rm.id
  join public.room_types rt
    on rt.id = o.room_type_id and rt.max_occupancy >= p_pax
  where rm.status = 'active'
    and rm.operational_status <> 'maintenance'
    and not exists (
      select 1 from public.reservations r
      where r.room_id = rm.id
        and r.status in ('confirmed', 'checked_in')
        and r.check_in_date < p_check_out
        and p_check_in < r.check_out_date
    )
  group by rm.id, rm.room_number, rm.floor, rm.zone
  order by rm.floor, rm.room_number::int;
$$;

-- =====================================================================
-- FUNCIÓN: crear reserva (ATÓMICA, anti-overbooking).
-- Deduplica al huésped por documento (igual que el walk-in).
-- La reserva queda en 'confirmed' (aún no hace check-in).
-- =====================================================================
create or replace function public.create_reservation(
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
  p_check_in     date,
  p_check_out    date,
  p_num_guests   int,
  p_method       text
) returns uuid
language plpgsql
as $$
declare
  v_person_id      uuid;
  v_reservation_id uuid;
  v_rate           numeric(10,2);
  v_max_occ        int;
  v_nights         int;
begin
  if p_check_out <= p_check_in then
    raise exception 'La fecha de salida debe ser posterior a la de entrada';
  end if;
  if p_num_guests < 1 then
    raise exception 'Debe haber al menos 1 persona';
  end if;

  -- El tipo debe ser opción válida de la habitación y tener capacidad.
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

  -- Bloqueo pesimista de la habitación para serializar reservas concurrentes.
  perform 1 from public.rooms where id = p_room_id for update;

  -- Revalidar disponibilidad DENTRO del bloqueo (anti-overbooking).
  if exists (
    select 1 from public.reservations r
    where r.room_id = p_room_id
      and r.status in ('confirmed', 'checked_in')
      and r.check_in_date < p_check_out
      and p_check_in < r.check_out_date
  ) then
    raise exception 'La habitación ya no está disponible para esas fechas';
  end if;

  -- Huésped: reutilizar por documento o crear nuevo.
  if nullif(p_document, '') is not null then
    select person_id into v_person_id
    from public.guests where passport_number = p_document;
  end if;

  if v_person_id is not null then
    update public.people set
      first_name = p_first_name, last_name = p_last_name,
      email = coalesce(nullif(p_email, ''), email),
      birth_date = coalesce(p_birth_date, birth_date)
    where id = v_person_id;
    update public.guests set
      country_code = coalesce(nullif(p_country_code, ''), country_code),
      city = coalesce(nullif(p_city, ''), city),
      wants_offers = p_wants_offers
    where person_id = v_person_id;
  else
    insert into public.people (first_name, last_name, email, birth_date)
    values (p_first_name, p_last_name, nullif(p_email, ''), p_birth_date)
    returning id into v_person_id;
    insert into public.guests (person_id, passport_number, country_code, city, wants_offers)
    values (v_person_id, nullif(p_document, ''), nullif(p_country_code, ''),
            nullif(p_city, ''), p_wants_offers);
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

-- Permisos (guardado para local).
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant execute on function public.available_rooms(date,date,int) to anon, authenticated;
    grant execute on function public.create_reservation(uuid,uuid,text,text,text,text,date,text,text,boolean,date,date,int,text)
      to anon, authenticated;
  end if;
end$$;
