-- =====================================================================
-- MÓDULO EVENTOS — alquiler de salones/áreas para bodas, sesiones, etc.
--
-- Un evento usa una o más áreas (los 2 salones, patio…), tiene un precio y se
-- cobra con adelantos y/o pago final. Los pagos en efectivo alimentan la caja
-- (mismo criterio que el check-out): 1 solo lugar donde entra el dinero.
-- Tipos y áreas son tablas de referencia (agregables sin migración).
-- =====================================================================

-- ---------- Referencia: tipos de evento ----------
create table if not exists public.event_types (
  id     uuid primary key default gen_random_uuid(),
  name   text not null unique,
  active boolean not null default true
);
insert into public.event_types (name) values
  ('Boda'), ('Noche de bodas'), ('Sesión fotográfica'),
  ('Evento corporativo'), ('Cumpleaños'), ('Otro')
on conflict (name) do nothing;

-- ---------- Referencia: áreas alquilables ----------
create table if not exists public.event_areas (
  id     uuid primary key default gen_random_uuid(),
  name   text not null unique,
  active boolean not null default true
);
insert into public.event_areas (name) values
  ('Salón 1'), ('Salón 2'), ('Patio colonial'), ('Terraza')
on conflict (name) do nothing;

-- ---------- Eventos ----------
create table if not exists public.events (
  id         uuid primary key default gen_random_uuid(),
  title      text not null,                 -- nombre del evento / cliente
  type_id    uuid references public.event_types(id),
  event_date date not null,
  start_time time,
  end_time   time,
  price_bs   numeric(12,2) not null default 0 check (price_bs >= 0),
  status     text not null default 'scheduled'
             check (status in ('scheduled', 'done', 'cancelled')),
  notes      text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);
create index if not exists idx_events_date on public.events (event_date);

-- ---------- Áreas usadas por cada evento (N a N) ----------
create table if not exists public.event_area_use (
  event_id uuid not null references public.events(id) on delete cascade,
  area_id  uuid not null references public.event_areas(id) on delete restrict,
  primary key (event_id, area_id)
);

-- ---------- Pagos del evento (adelantos y/o final) ----------
create table if not exists public.event_payments (
  id         uuid primary key default gen_random_uuid(),
  event_id   uuid not null references public.events(id) on delete cascade,
  amount_bs  numeric(12,2) not null check (amount_bs > 0),
  method     text not null check (method in ('efectivo', 'qr', 'transferencia', 'tarjeta')),
  is_deposit boolean not null default false,
  paid_at    timestamptz not null default now(),
  created_by uuid references public.profiles(id)
);
create index if not exists idx_event_payments_event on public.event_payments (event_id);

-- ---------- RLS ----------
alter table public.event_types    enable row level security;
alter table public.event_areas    enable row level security;
alter table public.events         enable row level security;
alter table public.event_area_use enable row level security;
alter table public.event_payments enable row level security;

-- Referencia + eventos: lectura para staff; escritura para root/recepción.
create policy "event_types_read"  on public.event_types  for select using (public.current_user_role() in ('root','reception','accountant'));
create policy "event_types_write" on public.event_types  for all
  using (public.current_user_role() in ('root','reception')) with check (public.current_user_role() in ('root','reception'));
create policy "event_areas_read"  on public.event_areas  for select using (public.current_user_role() in ('root','reception','accountant'));
create policy "event_areas_write" on public.event_areas  for all
  using (public.current_user_role() in ('root','reception')) with check (public.current_user_role() in ('root','reception'));
create policy "events_read"  on public.events  for select using (public.current_user_role() in ('root','reception','accountant'));
create policy "events_write" on public.events  for all
  using (public.current_user_role() in ('root','reception')) with check (public.current_user_role() in ('root','reception'));
create policy "event_area_use_read"  on public.event_area_use for select using (public.current_user_role() in ('root','reception','accountant'));
create policy "event_area_use_write" on public.event_area_use for all
  using (public.current_user_role() in ('root','reception')) with check (public.current_user_role() in ('root','reception'));

-- Pagos: solo lectura directa; se insertan por función (integración con caja).
create policy "event_payments_read" on public.event_payments
  for select using (public.current_user_role() in ('root','reception','accountant'));

-- ---------- Registrar un pago (adelanto o final) ----------
-- Inserta el pago y, si es efectivo, lo mete en la caja abierta (revierte si no
-- hay caja, igual que el check-out).
create or replace function public.add_event_payment(
  p_event_id uuid, p_amount numeric, p_method text, p_is_deposit boolean
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if public.current_user_role() not in ('root', 'reception') then
    raise exception 'No autorizado';
  end if;
  if p_method not in ('efectivo', 'qr', 'transferencia', 'tarjeta') then
    raise exception 'Forma de pago inválida';
  end if;

  insert into public.event_payments (event_id, amount_bs, method, is_deposit, created_by)
    values (p_event_id, p_amount, p_method, coalesce(p_is_deposit, false), auth.uid());

  if p_method = 'efectivo' then
    perform public.add_cash_movement(
      'income', 'evento', p_amount,
      case when p_is_deposit then 'Adelanto evento' else 'Pago evento' end,
      null
    );
  end if;
end $$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function public.add_event_payment(uuid, numeric, text, boolean) to authenticated;
  end if;
end $$;
