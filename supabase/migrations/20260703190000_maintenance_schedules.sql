-- =====================================================================
-- MÓDULO MANTENIMIENTO — Fase 3: preventivo recurrente (agendas).
--
-- Una agenda define una revisión periódica (ej: limpiar filtros de AC cada 90
-- días). Al generar el ticket, la función crea un maintenance_ticket kind
-- 'preventive' y avanza next_due_at. La generación es explícita (botón), no un
-- cron: gerencia decide cuándo dispararla.
-- =====================================================================

create table if not exists public.maintenance_schedules (
  id             uuid primary key default gen_random_uuid(),
  title          text not null,
  category       text not null default 'other'
                 check (category in ('ac', 'plumbing', 'electrical', 'appliance',
                                     'furniture', 'structural', 'other')),
  room_id        uuid references public.rooms(id),
  area           text,
  priority       text not null default 'medium'
                 check (priority in ('low', 'medium', 'high', 'urgent')),
  frequency_days integer not null check (frequency_days > 0),
  next_due_at    date not null default current_date,
  last_done_at   date,
  active         boolean not null default true,
  notes          text,
  created_at     timestamptz not null default now()
);
create index if not exists idx_msch_due on public.maintenance_schedules (next_due_at)
  where active;

alter table public.maintenance_schedules enable row level security;
create policy "msch_operations" on public.maintenance_schedules
  for all
  using (public.current_user_role() in ('root', 'reception'))
  with check (public.current_user_role() in ('root', 'reception'));
create policy "msch_read_finance" on public.maintenance_schedules
  for select
  using (public.current_user_role() = 'accountant');

-- ---------- Generar ticket desde una agenda ----------
-- Crea el ticket preventivo y avanza la agenda (last_done = hoy, next_due =
-- hoy + frecuencia). SECURITY INVOKER (por defecto): la RLS de tickets decide
-- si quien llama puede crear (gerencia sola no podría, y está bien).
create or replace function public.create_ticket_from_schedule(p_schedule_id uuid)
returns uuid
language plpgsql
set search_path = public
as $$
declare
  s public.maintenance_schedules;
  v_ticket uuid;
begin
  select * into s from public.maintenance_schedules where id = p_schedule_id;
  if not found then
    raise exception 'Agenda no encontrada';
  end if;

  insert into public.maintenance_tickets
    (kind, category, title, description, room_id, area, priority)
  values
    ('preventive', s.category, s.title, s.notes, s.room_id, s.area, s.priority)
  returning id into v_ticket;

  update public.maintenance_schedules
    set last_done_at = current_date,
        next_due_at  = current_date + make_interval(days => s.frequency_days)
  where id = p_schedule_id;

  return v_ticket;
end $$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function public.create_ticket_from_schedule(uuid) to authenticated;
  end if;
end $$;
