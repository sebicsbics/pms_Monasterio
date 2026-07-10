-- =====================================================================
-- MÓDULO MANTENIMIENTO — Fase 2: repuestos y gasto por ticket.
--
-- Líneas de texto libre (descripción + cantidad + costo). Enlazar al inventario
-- queda para más adelante. El total de línea lo calcula la DB (columna generada),
-- no el front: una sola fuente de verdad para el gasto.
-- =====================================================================

create table if not exists public.maintenance_ticket_parts (
  id           uuid primary key default gen_random_uuid(),
  ticket_id    uuid not null references public.maintenance_tickets(id) on delete cascade,
  description  text not null,
  quantity     numeric(12,2) not null check (quantity > 0),
  unit_cost_bs numeric(12,2) not null check (unit_cost_bs >= 0),
  line_total_bs numeric(12,2) generated always as (quantity * unit_cost_bs) stored,
  created_at   timestamptz not null default now()
);
create index if not exists idx_mtp_ticket on public.maintenance_ticket_parts (ticket_id);

alter table public.maintenance_ticket_parts enable row level security;

-- Mismos permisos que los tickets: recepción/root gestionan, gerencia lee.
create policy "mtp_operations" on public.maintenance_ticket_parts
  for all
  using (public.current_user_role() in ('root', 'reception'))
  with check (public.current_user_role() in ('root', 'reception'));
create policy "mtp_read_finance" on public.maintenance_ticket_parts
  for select
  using (public.current_user_role() = 'accountant');
