-- =====================================================================
-- MÓDULO FICHAJE — reloj de asistencia explícito (entrada/salida).
--
-- A diferencia de login_events (acceso al sistema), esto es un fichaje
-- intencional: el empleado marca entrada y salida. Modelo: UNA fila = UNA sesión
-- de trabajo (clock_in + clock_out), lo que hace directo calcular horas y saber
-- quién está adentro (clock_out is null = sesión abierta).
--
-- Se permiten VARIAS sesiones por día (ej. corte de almuerzo), pero solo UNA
-- abierta a la vez por persona (índice único parcial).
-- =====================================================================

create table if not exists public.time_entries (
  id        uuid primary key default gen_random_uuid(),
  user_id   uuid not null references public.profiles(id),
  clock_in  timestamptz not null default now(),
  clock_out timestamptz,
  constraint chk_out_after_in check (clock_out is null or clock_out >= clock_in)
);
create index if not exists idx_time_entries_user on public.time_entries (user_id, clock_in desc);
-- Candado: como mucho una sesión abierta por persona.
create unique index if not exists uniq_open_entry
  on public.time_entries (user_id) where clock_out is null;

alter table public.time_entries enable row level security;

-- Cada quien inserta/edita lo suyo; root y contaduría ven (y corrigen) todo.
create policy "te_insert_own" on public.time_entries
  for insert with check (user_id = auth.uid());
create policy "te_update_own" on public.time_entries
  for update using (user_id = auth.uid() or public.current_user_role() in ('root', 'accountant'))
              with check (user_id = auth.uid() or public.current_user_role() in ('root', 'accountant'));
create policy "te_select" on public.time_entries
  for select using (user_id = auth.uid() or public.current_user_role() in ('root', 'accountant'));

-- ---------- Marcar ENTRADA ----------
create or replace function public.clock_in()
returns public.time_entries
language plpgsql
security invoker
set search_path = public
as $$
declare row public.time_entries;
begin
  if exists (select 1 from public.time_entries
             where user_id = auth.uid() and clock_out is null) then
    raise exception 'Ya tenés un fichaje abierto. Marcá salida primero.';
  end if;
  insert into public.time_entries (user_id) values (auth.uid())
    returning * into row;
  return row;
end $$;

-- ---------- Marcar SALIDA ----------
create or replace function public.clock_out()
returns public.time_entries
language plpgsql
security invoker
set search_path = public
as $$
declare row public.time_entries;
begin
  update public.time_entries set clock_out = now()
    where user_id = auth.uid() and clock_out is null
    returning * into row;
  if not found then
    raise exception 'No tenés un fichaje abierto.';
  end if;
  return row;
end $$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function public.clock_in()  to authenticated;
    grant execute on function public.clock_out() to authenticated;
  end if;
end $$;
