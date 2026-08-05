-- =====================================================================
-- Huéspedes de la estadía: visibilidad en el tablero + alta mid-stay.
-- (change: stay-guests-and-add-guest)
--
-- Tres cosas:
--   1) Vista `stay_guests`: TODOS los huéspedes de una reserva (titular +
--      acompañantes) en una sola lista, para mostrarlos sobre el folio.
--   2) `add_guests_to_stay`: agregar huéspedes a una habitación YA ocupada
--      (el caso real: entra un hombre solo y a los dos días llega su
--      esposa). El incremento se cobra como CARGO AL FOLIO — no se toca
--      `total_amount_bs`, así el folio impreso muestra explícitamente por
--      qué subió el total y la auditoría de tarifas (rate_overrides) sigue
--      significando "cambio de tarifa", no "cambio de ocupación".
--   3) FIX de Llegadas: `check_in_reservation_with_guests` rechazaba
--      registrar más huéspedes que `num_guests` de la reserva. Es una
--      restricción equivocada: `num_guests` es lo que se ESTIMÓ al tomar
--      la reserva (muchas veces 1, o null), no la capacidad real de la
--      habitación. El tope correcto es `room_types.max_occupancy` — el
--      mismo que ya usa el walk-in del tablero
--      (20260727000300_walkin_multi_guest.sql). Además ahora sincroniza
--      `num_guests` con la cantidad realmente registrada.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) stay_guests: titular + acompañantes de cada reserva.
--    security_invoker: hereda las políticas de people/guests/reservations
--    del usuario que consulta (mismo patrón que `in_house`).
-- ---------------------------------------------------------------------
create or replace view public.stay_guests
with (security_invoker = on) as
select
  r.id                     as reservation_id,
  r.room_id,
  p.id                     as person_id,
  p.first_name,
  p.last_name,
  true                     as is_holder,
  coalesce(g.is_minor, false) as is_minor,
  g.passport_number        as document
from public.reservations r
join public.guests g on g.person_id = r.guest_id
join public.people p on p.id = g.person_id
where r.status = 'checked_in'
union all
select
  r.id,
  r.room_id,
  p.id,
  p.first_name,
  p.last_name,
  false,
  coalesce(g.is_minor, false),
  g.passport_number
from public.reservations r
join public.reservation_guests rg on rg.reservation_id = r.id
join public.people p on p.id = rg.person_id
left join public.guests g on g.person_id = p.id
where r.status = 'checked_in'
  and rg.person_id <> r.guest_id;

comment on view public.stay_guests is
  'Todos los huéspedes de una reserva: el titular (reservations.guest_id, '
  'is_holder = true) y los acompañantes (reservation_guests). Se excluye '
  'al titular del tramo de acompañantes para no duplicarlo si quedó '
  'enlazado en ambas tablas. Solo estadías en curso (checked_in): sin ese '
  'filtro, consultar por room_id devolvería también a los huéspedes de '
  'estadías anteriores de la misma habitación.';

-- ---------------------------------------------------------------------
-- 2) add_guests_to_stay: alta de huéspedes en una habitación ocupada.
--
-- p_companions: mismo shape jsonb que el check-in (first_name, last_name,
--   is_minor, document, birth_date, country_code, city, origin_city,
--   travel_purpose, occupation, transport_means).
-- p_extra_charge_bs: incremento a cobrar (0 = sin cargo, ej. un menor).
-- p_charge_description: descripción de la línea del folio. Si viene vacía
--   se arma una por defecto con los nombres agregados.
--
-- Devuelve la cantidad de huéspedes que quedó registrada en la habitación.
-- ---------------------------------------------------------------------
create or replace function public.add_guests_to_stay(
  p_room_id            uuid,
  p_companions         jsonb,
  p_extra_charge_bs    numeric default 0,
  p_charge_description text default null
) returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_companions jsonb := coalesce(p_companions, '[]'::jsonb);
  v_new        int   := jsonb_array_length(v_companions);
  v_reservation uuid;
  v_room_type   uuid;
  v_max_occ     int;
  v_current     int;
  v_total       int;
  v_desc        text;
  v_names       text;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado para agregar huéspedes';
  end if;

  if v_new = 0 then
    raise exception 'No hay huéspedes para agregar';
  end if;

  if p_extra_charge_bs is null or p_extra_charge_bs < 0 then
    raise exception 'El incremento debe ser un monto mayor o igual a 0';
  end if;

  select r.id, r.room_type_id into v_reservation, v_room_type
  from public.reservations r
  where r.room_id = p_room_id and r.status = 'checked_in'
  order by r.check_in_date desc
  limit 1;

  if v_reservation is null then
    raise exception 'No hay una estadía activa en esta habitación';
  end if;

  -- Tope real de la habitación (no num_guests, que es una estimación).
  select max_occupancy into v_max_occ
  from public.room_types where id = v_room_type;

  select count(*) into v_current
  from public.stay_guests where reservation_id = v_reservation;

  v_total := v_current + v_new;
  if v_max_occ is not null and v_total > v_max_occ then
    raise exception 'La habitación admite % huésped(es); quedarían %',
      v_max_occ, v_total;
  end if;

  -- Alta de las fichas (dedupe por documento, mismo criterio que check-in).
  perform public.add_reservation_companions(v_reservation, v_companions);

  -- La ocupación declarada pasa a ser la real.
  update public.reservations
    set num_guests = greatest(coalesce(num_guests, 0), v_total)
    where id = v_reservation;

  -- Incremento como línea de folio, visible en el folio impreso.
  if p_extra_charge_bs > 0 then
    v_desc := nullif(trim(coalesce(p_charge_description, '')), '');
    if v_desc is null then
      select string_agg(
               trim(c->>'first_name') || ' ' || trim(c->>'last_name'), ', '
             )
      into v_names
      from jsonb_array_elements(v_companions) as t(c);
      v_desc := 'Huésped adicional: ' || coalesce(v_names, '');
    end if;
    perform public.add_folio_charge(p_room_id, v_desc, p_extra_charge_bs);
  end if;

  return v_total;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function public.add_guests_to_stay(uuid, jsonb, numeric, text)
      to authenticated;
    grant select on public.stay_guests to anon, authenticated;
  end if;
end$$;

-- ---------------------------------------------------------------------
-- 3) FIX Llegadas: el tope pasa a ser max_occupancy y num_guests se
--    sincroniza con lo realmente registrado. Cuerpo idéntico al de
--    20260728000000_guest_travel_profile.sql salvo esa validación.
-- ---------------------------------------------------------------------
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
  v_total      int   := jsonb_array_length(v_companions) + 1;
  v_max_occ    int;
  v_guest_id   uuid;
begin
  -- El tope es la capacidad de la habitación, NO num_guests (que es la
  -- estimación de la reserva y suele venir en 1 o null). Antes esto
  -- impedía registrar al acompañante que sí llegó.
  select rt.max_occupancy, r.guest_id into v_max_occ, v_guest_id
  from public.reservations r
  join public.room_types rt on rt.id = r.room_type_id
  where r.id = p_reservation_id;

  if v_max_occ is not null and v_total > v_max_occ then
    raise exception 'La habitación admite % huésped(es); estás registrando %',
      v_max_occ, v_total;
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

  -- La ocupación declarada pasa a ser la real (la reserva decía 1 y
  -- llegaron 2: el registro turístico tiene que reflejar 2).
  update public.reservations
    set num_guests = greatest(coalesce(num_guests, 0), v_total)
    where id = p_reservation_id;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function public.check_in_reservation_with_guests(
      uuid, text, date, text, text, boolean, text, text, text, text, jsonb
    ) to authenticated;
  end if;
end$$;

-- ---------------------------------------------------------------------
-- 4) arrivals(): expone max_occupancy para que Llegadas sepa hasta
--    cuántos acompañantes puede agregar el recepcionista (antes la UI
--    derivaba las plazas de num_guests y no dejaba sumar ninguna).
--    Cambia el tipo de retorno → drop previo.
-- ---------------------------------------------------------------------
drop function if exists public.arrivals(date, date);

create or replace function public.arrivals(p_from date, p_to date)
returns table (
  reservation_id    uuid,
  room_id           uuid,
  room_number       text,
  room_type         text,
  first_name        text,
  last_name         text,
  phone             text,
  email             text,
  check_in_date     date,
  check_out_date    date,
  num_guests        int,
  max_occupancy     int,
  method            text,
  anticipo_total_bs numeric
)
language sql
stable
set search_path = public
as $$
  select
    r.id, rm.id, rm.room_number::text, rt.name::text,
    p.first_name::text, p.last_name::text, p.phone::text, p.email::text,
    r.check_in_date, r.check_out_date, r.num_guests, rt.max_occupancy,
    r.reservation_method::text,
    coalesce((
      select sum(a.amount_bs) from public.anticipos a
      where a.reservation_id = r.id and a.status = 'active'
    ), 0)
  from public.reservations r
  join public.rooms      rm on rm.id = r.room_id
  join public.room_types rt on rt.id = r.room_type_id
  join public.guests     g  on g.person_id = r.guest_id
  join public.people     p  on p.id = g.person_id
  where r.status = 'confirmed'
    and r.check_in_date <= p_to
    and (p_from is null or r.check_in_date >= p_from)
  order by r.check_in_date, rm.room_number::int;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant execute on function public.arrivals(date, date) to anon, authenticated;
  end if;
end$$;
