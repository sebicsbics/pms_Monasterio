-- =====================================================================
-- stay_guests: nacionalidad de cada huésped.
--
-- La hoja de desayuno que recepción arma de noche para las camareras
-- necesita el nombre de TODOS los huéspedes de la habitación con su
-- nacionalidad. `stay_guests` ya daba los nombres (titular +
-- acompañantes); faltaba el país, que vive en `guests.country_code`.
--
-- La columna va al final porque `create or replace view` no permite
-- insertar columnas en el medio. Para el titular el join a `guests` es
-- interno (siempre existe); para los acompañantes es left join, así que
-- `country_code` puede venir null y la UI lo resuelve como "—".
-- =====================================================================

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
  g.passport_number        as document,
  g.country_code
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
  g.passport_number,
  g.country_code
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
  'enlazado en ambas tablas. Solo estadías en curso (checked_in). '
  'country_code puede ser null en acompañantes sin ficha de guests.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant select on public.stay_guests to authenticated;
  end if;
end$$;
