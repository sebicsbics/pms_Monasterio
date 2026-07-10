-- =====================================================================
-- MÓDULO MANTENIMIENTO — Fase 1: tickets correctivos + sellos de tiempo.
--
-- Dedicado (NO se reusa public.tasks): el ciclo de vida, la prioridad y los
-- tiempos de respuesta no caben en la lista simple de housekeeping.
-- El esquema ya contempla fases futuras (kind preventivo, repuestos, agenda).
--
-- Roles: recepción abre/gestiona; gerencia (accountant) lee para métricas;
-- el equipo de mantenimiento son employees asignables (como las mucamas).
-- =====================================================================

create table if not exists public.maintenance_tickets (
  id           uuid primary key default gen_random_uuid(),
  ticket_no    bigint generated always as identity,  -- referencia humana (MT-42)
  kind         text not null default 'corrective'
               check (kind in ('corrective', 'preventive')),
  category     text not null default 'other'
               check (category in ('ac', 'plumbing', 'electrical', 'appliance',
                                    'furniture', 'structural', 'other')),
  title        text not null,
  description  text,
  room_id      uuid references public.rooms(id),
  area         text,                                  -- ubicación no-habitación
  priority     text not null default 'medium'
               check (priority in ('low', 'medium', 'high', 'urgent')),
  status       text not null default 'open'
               check (status in ('open', 'assigned', 'in_progress',
                                 'resolved', 'closed', 'cancelled')),
  reported_by  uuid references public.profiles(id) default auth.uid(),
  assigned_to  uuid references public.employees(person_id),
  -- Sellos que habilitan las métricas de respuesta (fase 4):
  reported_at  timestamptz not null default now(),
  started_at   timestamptz,   -- cuándo mantenimiento empezó a atenderlo
  resolved_at  timestamptz,   -- cuándo quedó resuelto
  closed_at    timestamptz,   -- cierre/validación de recepción
  updated_at   timestamptz not null default now()
);

create index if not exists idx_mt_status   on public.maintenance_tickets (status);
create index if not exists idx_mt_room      on public.maintenance_tickets (room_id);
create index if not exists idx_mt_assigned  on public.maintenance_tickets (assigned_to);
create index if not exists idx_mt_reported  on public.maintenance_tickets (reported_at);

-- updated_at automático en cada cambio.
create or replace function public.touch_maintenance_ticket()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists trg_touch_mt on public.maintenance_tickets;
create trigger trg_touch_mt before update on public.maintenance_tickets
  for each row execute function public.touch_maintenance_ticket();

-- ---------- RLS ----------
alter table public.maintenance_tickets enable row level security;

-- Operación: root y recepción gestionan tickets (crear/editar/asignar/cerrar).
create policy "mt_operations" on public.maintenance_tickets
  for all
  using (public.current_user_role() in ('root', 'reception'))
  with check (public.current_user_role() in ('root', 'reception'));

-- Gerencia (contaduría): lectura para métricas y control de gasto.
create policy "mt_read_finance" on public.maintenance_tickets
  for select
  using (public.current_user_role() = 'accountant');
