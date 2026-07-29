-- =====================================================================
-- Mejoras: anticipo en llegadas, dropdown de reservas para anticipos,
-- housekeeping (mucama por texto + duración).
-- (change: housekeeping-arrivals-anticipo)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Housekeeping: mucama por texto libre + timestamp de inicio para medir
--    la duración (in_progress -> done). Se conserva assigned_to (FK,
--    deprecada) por compatibilidad.
-- ---------------------------------------------------------------------
alter table public.housekeeping_assignments
  add column if not exists assigned_to_name text,
  add column if not exists started_at        timestamptz;

comment on column public.housekeeping_assignments.assigned_to_name is
  'Nombre de la mucama (texto libre). Reemplaza a assigned_to (FK a '
  'employees, deprecada) — se puede escribir cualquier nombre.';
comment on column public.housekeeping_assignments.started_at is
  'Momento en que pasó a en_progreso. Con completed_at permite medir '
  'cuánto tardó la limpieza/habilitación.';

-- ---------------------------------------------------------------------
-- 2) arrivals(p_from, p_to): agrega anticipo_total_bs (suma de anticipos
--    activos de la reserva) para mostrar en Llegadas si tiene anticipo.
--    Cambia el tipo de retorno (nueva columna) → hay que dropear antes.
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
    r.check_in_date, r.check_out_date, r.num_guests, r.reservation_method::text,
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

-- ---------------------------------------------------------------------
-- 3) list_reservations_brief(): reservas activas (confirmadas o con
--    huésped adentro) con habitación, huésped y fechas, para poblar el
--    dropdown de "Registrar anticipo". SECURITY DEFINER con guard de rol
--    (mismo alcance que registrar anticipos: root/reception/reception_admin).
-- ---------------------------------------------------------------------
create or replace function public.list_reservations_brief()
returns table (
  id             uuid,
  room_number    text,
  guest_name     text,
  check_in_date  date,
  check_out_date date,
  status         text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin', 'accountant') then
    raise exception 'No autorizado';
  end if;

  return query
    select
      r.id, rm.room_number::text,
      (p.first_name || ' ' || p.last_name)::text,
      r.check_in_date, r.check_out_date, r.status::text
    from public.reservations r
    join public.rooms  rm on rm.id = r.room_id
    join public.guests g   on g.person_id = r.guest_id
    join public.people p   on p.id = g.person_id
    where r.status in ('confirmed', 'checked_in')
    order by r.check_in_date, rm.room_number::int;
end;
$$;

grant execute on function public.list_reservations_brief() to authenticated;
