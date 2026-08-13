-- =====================================================================
-- in_house: cantidad de huéspedes por habitación.
--
-- El tablero de in-house solo mostraba al titular, así que recepción no
-- podía ver de un vistazo cuánta gente hay realmente en cada habitación
-- (ni cuánta en el hotel). La fuente correcta es `stay_guests` (titular +
-- acompañantes), no `reservations.num_guests`, que es la estimación de la
-- reserva. Aun así se toma el mayor de los dos: si por alguna reserva
-- vieja no se cargaron las fichas de los acompañantes, num_guests evita
-- reportar de menos.
-- =====================================================================

create or replace view public.in_house
with (security_invoker = on) as
select
  r.id            as reservation_id,
  rm.id           as room_id,
  rm.room_number,
  rm.floor,
  rm.zone,
  rt.name         as room_type,
  p.first_name,
  p.last_name,
  p.email,
  g.country_code,
  g.city,
  r.check_in_date,
  r.check_out_date,
  r.total_amount_bs as room_total_bs,
  greatest(
    coalesce((
      select count(*) from public.stay_guests sg
      where sg.reservation_id = r.id
    ), 0),
    coalesce(r.num_guests, 0),
    1
  )::int as guest_count
from public.reservations r
join public.rooms       rm on rm.id = r.room_id
join public.room_types  rt on rt.id = r.room_type_id
join public.guests      g  on g.person_id = r.guest_id
join public.people      p  on p.id = g.person_id
where r.status = 'checked_in';

comment on view public.in_house is
  'Estadías en curso. guest_count = huéspedes realmente registrados '
  '(stay_guests), con num_guests como piso por si faltan fichas de '
  'acompañantes de reservas viejas.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant select on public.in_house to authenticated;
  end if;
end$$;
