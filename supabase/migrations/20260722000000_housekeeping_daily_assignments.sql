-- =====================================================================
-- MÓDULO HOUSEKEEPING DIARIO: tablero unificado stayover + turnover.
-- Una fila por (room_id, service_date), generada desde reservations.
-- =====================================================================

create table if not exists public.housekeeping_assignments (
  id           uuid primary key default gen_random_uuid(),
  room_id      uuid not null references public.rooms(id),
  service_date date not null,
  assigned_to  uuid references public.employees(person_id),
  status       varchar(15) not null default 'pending'
               check (status in ('pending', 'in_progress', 'done')),
  kind         varchar(10) not null check (kind in ('stayover', 'turnover')),
  notes        text,
  completed_at timestamptz,
  created_at   timestamptz not null default now(),
  unique (room_id, service_date)
);
create index if not exists idx_housekeeping_assignments_date
  on public.housekeeping_assignments (service_date);

alter table public.housekeeping_assignments enable row level security;

-- NOTA: el diseño original mencionaba un rol 'reception_admin' que NO existe
-- en ninguna parte del sistema (no está en el tipo UserRole, ni en ninguna
-- migración, ni asignado a ningún profile). Se descartó ese rol y se usa el
-- mismo par (root, reception) que la tabla `tasks`, que es la que este
-- módulo replica.
create policy "housekeeping_assignments_operations" on public.housekeeping_assignments
  for all
  using (public.current_user_role() in ('root', 'reception'))
  with check (public.current_user_role() in ('root', 'reception'));

-- =====================================================================
-- FUNCIÓN: generación idempotente del tablero del día.
-- Deriva candidatos de `reservations` (fuente de verdad):
--   stayover = estadía activa que cubre el día (sin checkout ese día)
--   turnover = checkout programado ese mismo día
-- INSERT ... ON CONFLICT DO NOTHING: nunca pisa status/assigned_to/notes
-- de filas ya existentes (re-ejecutable sin destruir trabajo en curso).
-- =====================================================================
create or replace function public.generate_housekeeping_assignments(
  p_service_date date
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.current_user_role() not in ('root', 'reception') then
    raise exception 'No autorizado para generar el tablero de housekeeping';
  end if;

  insert into public.housekeeping_assignments (room_id, service_date, kind, status)
  select r.room_id, p_service_date, 'stayover', 'pending'
  from public.reservations r
  where r.room_id is not null
    and r.status = 'checked_in'
    and r.check_in_date <= p_service_date
    and r.check_out_date > p_service_date

  union

  select r.room_id, p_service_date, 'turnover', 'pending'
  from public.reservations r
  where r.room_id is not null
    and r.check_out_date = p_service_date
    and r.status in ('checked_in', 'checked_out')

  on conflict (room_id, service_date) do nothing;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function public.generate_housekeeping_assignments(date)
      to authenticated;
  end if;
end$$;
