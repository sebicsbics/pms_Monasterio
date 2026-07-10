-- =====================================================================
-- MANTENIMIENTO — historial de estados + borrado root-only.
--
-- 1) Tabla de eventos: cada cambio de estado se registra automáticamente por
--    trigger (no depende de que el front lo recuerde). Habilita ver por dónde
--    pasó el ticket: abierto -> asignado -> en progreso -> resuelto -> cerrado.
-- 2) RLS de tickets: hoy 'for all' deja BORRAR a recepción. Se separa por comando
--    para que solo root pueda eliminar.
-- =====================================================================

-- ---------- 1) Historial de estados ----------
create table if not exists public.maintenance_ticket_events (
  id         uuid primary key default gen_random_uuid(),
  ticket_id  uuid not null references public.maintenance_tickets(id) on delete cascade,
  status     text not null,
  changed_by uuid references public.profiles(id),
  changed_at timestamptz not null default now()
);
create index if not exists idx_mte_ticket on public.maintenance_ticket_events (ticket_id, changed_at);

-- Trigger: registra el estado al crear y en cada cambio. SECURITY DEFINER para
-- que la inserción en el log no choque con la RLS del que dispara el cambio.
create or replace function public.log_maintenance_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.maintenance_ticket_events (ticket_id, status, changed_by)
      values (new.id, new.status, auth.uid());
  elsif tg_op = 'UPDATE' and new.status is distinct from old.status then
    insert into public.maintenance_ticket_events (ticket_id, status, changed_by)
      values (new.id, new.status, auth.uid());
  end if;
  return new;
end $$;

drop trigger if exists trg_log_mt_event on public.maintenance_tickets;
create trigger trg_log_mt_event
  after insert or update on public.maintenance_tickets
  for each row execute function public.log_maintenance_event();

alter table public.maintenance_ticket_events enable row level security;
-- Lectura para quien ve tickets; la inserción va por el trigger (definer).
create policy "mte_read" on public.maintenance_ticket_events
  for select
  using (public.current_user_role() in ('root', 'reception', 'accountant'));

-- ---------- 2) RLS de tickets separada por comando (borrado solo root) ----------
drop policy if exists "mt_operations"   on public.maintenance_tickets;
drop policy if exists "mt_read_finance" on public.maintenance_tickets;

create policy "mt_select" on public.maintenance_tickets
  for select using (public.current_user_role() in ('root', 'reception', 'accountant'));
create policy "mt_insert" on public.maintenance_tickets
  for insert with check (public.current_user_role() in ('root', 'reception'));
create policy "mt_update" on public.maintenance_tickets
  for update using (public.current_user_role() in ('root', 'reception'))
              with check (public.current_user_role() in ('root', 'reception'));
create policy "mt_delete" on public.maintenance_tickets
  for delete using (public.current_user_role() = 'root');
