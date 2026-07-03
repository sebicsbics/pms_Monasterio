-- =====================================================================
-- MÓDULO TAREAS (housekeeping): recepción asigna tareas a las mucamas.
-- =====================================================================

-- ---------- TAREAS ----------
create table if not exists public.tasks (
  id           uuid primary key default gen_random_uuid(),
  task_type    text not null check (task_type in ('cleaning', 'minibar', 'maintenance', 'other')),
  room_id      uuid references public.rooms(id),
  assigned_to  uuid references public.employees(person_id),
  status       text not null default 'pending' check (status in ('pending', 'in_progress', 'done')),
  notes        text,
  created_at   timestamptz not null default now(),
  completed_at timestamptz
);
create index if not exists idx_tasks_status on public.tasks (status);

alter table public.tasks enable row level security;
-- Housekeeping es operación: root y recepción.
create policy "tasks_operations" on public.tasks
  for all
  using (public.current_user_role() in ('root', 'reception'))
  with check (public.current_user_role() in ('root', 'reception'));

-- =====================================================================
-- VISTA: personal asignable (mucamas, etc.) — SOLO nombre y cargo.
-- Sin security_invoker => corre como dueño y NO expone la RLS de
-- employees, pero tampoco incluye el sueldo (proyección segura).
-- =====================================================================
create or replace view public.assignable_staff as
select
  e.person_id,
  (p.first_name || ' ' || p.last_name) as full_name,
  e.job_title
from public.employees e
join public.people p on p.id = e.person_id
where e.status = 'active';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant select on public.assignable_staff to authenticated;
  end if;
end$$;
