-- =====================================================================
-- FASE 4c — Llegadas del día + check-in desde una reserva existente.
-- Cierra el círculo: reserva (confirmed) -> llega el huésped -> check-in.
-- =====================================================================

-- =====================================================================
-- FUNCIÓN: llegadas hasta una fecha (reservas confirmadas sin check-in).
-- Incluye las de hoy y las vencidas (aún no llegaron).
-- =====================================================================
create or replace function public.arrivals(p_date date)
returns table (
  reservation_id  uuid,
  room_id         uuid,
  room_number     text,
  room_type       text,
  first_name      text,
  last_name       text,
  phone           text,
  email           text,
  check_in_date   date,
  check_out_date  date,
  num_guests      int,
  method          text
)
language sql
stable
as $$
  select
    r.id, rm.id, rm.room_number::text, rt.name::text,
    p.first_name::text, p.last_name::text, p.phone::text, p.email::text,
    r.check_in_date, r.check_out_date, r.num_guests, r.reservation_method::text
  from public.reservations r
  join public.rooms      rm on rm.id = r.room_id
  join public.room_types rt on rt.id = r.room_type_id
  join public.guests     g  on g.person_id = r.guest_id
  join public.people     p  on p.id = g.person_id
  where r.status = 'confirmed'
    and r.check_in_date <= p_date
  order by r.check_in_date, rm.room_number::int;
$$;

-- =====================================================================
-- FUNCIÓN: check-in desde una reserva (ATÓMICA).
-- Completa el perfil del huésped (documento, país, ciudad, cumpleaños,
-- consentimiento), pasa la reserva a checked_in, abre folio y ocupa la
-- habitación.
-- =====================================================================
create or replace function public.check_in_reservation(
  p_reservation_id uuid,
  p_document       text,
  p_birth_date     date,
  p_country_code   text,
  p_city           text,
  p_wants_offers   boolean
) returns void
language plpgsql
as $$
declare
  v_room_id    uuid;
  v_person_id  uuid;
  v_status     varchar(20);
  v_room_state varchar(15);
begin
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
    grant execute on function public.arrivals(date) to anon, authenticated;
    grant execute on function public.check_in_reservation(uuid,text,date,text,text,boolean)
      to anon, authenticated;
  end if;
end$$;
