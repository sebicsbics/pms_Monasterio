-- =====================================================================
-- MÓDULO ACCESOS — registro de ingresos/salidas al sistema.
--
-- Se usa como marcador aproximado de entrada/salida del personal. El ingreso
-- (login con usuario+contraseña) es confiable; la salida (logout) es best-effort
-- porque el usuario puede cerrar el navegador sin desloguearse.
--
-- Solo root y accountant pueden LEER (ven a los demás). Cada usuario solo puede
-- INSERTAR eventos propios.
-- =====================================================================

create table if not exists public.login_events (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id),
  event_type  text not null default 'login' check (event_type in ('login', 'logout')),
  occurred_at timestamptz not null default now()
);
create index if not exists idx_login_events_time on public.login_events (occurred_at desc);
create index if not exists idx_login_events_user on public.login_events (user_id, occurred_at desc);

alter table public.login_events enable row level security;

-- Cada usuario registra SOLO sus propios eventos (al loguear/desloguear).
create policy "le_insert_own" on public.login_events
  for insert with check (user_id = auth.uid());

-- Lectura de gerencia: root y contaduría ven los accesos de todos.
create policy "le_read_mgmt" on public.login_events
  for select using (public.current_user_role() in ('root', 'accountant'));
