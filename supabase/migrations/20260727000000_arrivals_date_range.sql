-- =====================================================================
-- Llegadas por RANGO de fechas (change: arrivals-date-range).
--
-- La versión original `arrivals(p_date)` (20260703050000) devuelve las
-- llegadas confirmadas hasta una fecha. Recepción necesita además poder
-- mirar un rango a futuro (ej. "próxima semana"). Se agrega una nueva
-- firma `arrivals(p_from, p_to)`:
--   - p_to: cota superior (obligatoria).
--   - p_from NULL: sin cota inferior => incluye llegadas vencidas (mismo
--     comportamiento que la vista de hoy original). Con valor: filtra
--     desde esa fecha (rangos a futuro no arrastran vencidas).
--
-- Se deja intacta la firma de 1 argumento (distinta aridad, sin colisión)
-- por compatibilidad; el frontend pasa a usar la nueva.
-- =====================================================================

create or replace function public.arrivals(p_from date, p_to date)
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
set search_path = public
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
