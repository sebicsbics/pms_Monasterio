-- =====================================================================
-- MÓDULO CAJA CHICA — sesiones de caja, movimientos (ingreso/egreso), cierre.
--
-- Principios de control financiero:
--  1) Sesión de caja (turno): abrir con fondo, cerrar contando -> faltante/sobrante.
--  2) Registros inmutables: no se editan/borran; se ANULAN con motivo (auditable).
--  3) Escritura SOLO por funciones validadas (SECURITY DEFINER). Las tablas no
--     tienen políticas de insert/update/delete -> el cliente no escribe directo.
--  4) Recibos en bucket privado 'receipts' (URLs firmadas), no público.
-- =====================================================================

-- ---------- Sesiones de caja ----------
create table if not exists public.cash_sessions (
  id                 uuid primary key default gen_random_uuid(),
  opened_by          uuid not null references public.profiles(id),
  opened_at          timestamptz not null default now(),
  opening_balance_bs numeric(12,2) not null check (opening_balance_bs >= 0),
  closed_by          uuid references public.profiles(id),
  closed_at          timestamptz,
  counted_balance_bs numeric(12,2),
  status             text not null default 'open' check (status in ('open', 'closed')),
  notes              text
);
-- Candado: una sola caja abierta a la vez.
create unique index if not exists uniq_open_cash_session
  on public.cash_sessions (status) where status = 'open';

-- ---------- Movimientos ----------
create table if not exists public.cash_movements (
  id           uuid primary key default gen_random_uuid(),
  session_id   uuid not null references public.cash_sessions(id) on delete cascade,
  kind         text not null check (kind in ('income', 'expense')),
  category     text not null,
  amount_bs    numeric(12,2) not null check (amount_bs > 0),
  concept      text,
  receipt_path text,                       -- ruta en storage 'receipts' (opcional)
  created_by   uuid not null references public.profiles(id),
  created_at   timestamptz not null default now(),
  voided       boolean not null default false,
  voided_by    uuid references public.profiles(id),
  voided_at    timestamptz,
  void_reason  text
);
create index if not exists idx_cash_mov_session on public.cash_movements (session_id);

-- ---------- RLS: SOLO lectura directa; escritura por funciones ----------
alter table public.cash_sessions  enable row level security;
alter table public.cash_movements enable row level security;

create policy "cash_sessions_read" on public.cash_sessions
  for select using (public.current_user_role() in ('root', 'reception', 'accountant'));
create policy "cash_movements_read" on public.cash_movements
  for select using (public.current_user_role() in ('root', 'reception', 'accountant'));
-- (Sin políticas de insert/update/delete: la escritura va por los RPC de abajo.)

-- ---------- Funciones (validan rol, caja abierta, montos) ----------

create or replace function public.open_cash_session(p_opening numeric)
returns public.cash_sessions
language plpgsql security definer set search_path = public as $$
declare row public.cash_sessions;
begin
  if public.current_user_role() not in ('root', 'reception') then
    raise exception 'No autorizado';
  end if;
  if exists (select 1 from public.cash_sessions where status = 'open') then
    raise exception 'Ya hay una caja abierta. Cerrala primero.';
  end if;
  insert into public.cash_sessions (opened_by, opening_balance_bs)
    values (auth.uid(), p_opening) returning * into row;
  return row;
end $$;

create or replace function public.close_cash_session(p_counted numeric, p_notes text)
returns public.cash_sessions
language plpgsql security definer set search_path = public as $$
declare row public.cash_sessions;
begin
  if public.current_user_role() not in ('root', 'reception') then
    raise exception 'No autorizado';
  end if;
  update public.cash_sessions
    set status = 'closed', closed_by = auth.uid(), closed_at = now(),
        counted_balance_bs = p_counted, notes = coalesce(p_notes, notes)
    where status = 'open'
    returning * into row;
  if not found then
    raise exception 'No hay ninguna caja abierta';
  end if;
  return row;
end $$;

create or replace function public.add_cash_movement(
  p_kind text, p_category text, p_amount numeric,
  p_concept text, p_receipt_path text
) returns public.cash_movements
language plpgsql security definer set search_path = public as $$
declare v_session uuid; row public.cash_movements;
begin
  if public.current_user_role() not in ('root', 'reception') then
    raise exception 'No autorizado';
  end if;
  select id into v_session from public.cash_sessions where status = 'open';
  if v_session is null then
    raise exception 'No hay una caja abierta';
  end if;
  if p_kind not in ('income', 'expense') then
    raise exception 'Tipo inválido';
  end if;
  insert into public.cash_movements
    (session_id, kind, category, amount_bs, concept, receipt_path, created_by)
    values (v_session, p_kind, p_category, p_amount, p_concept, p_receipt_path, auth.uid())
    returning * into row;
  return row;
end $$;

-- Anular un movimiento (no se borra): deja rastro. Solo root.
create or replace function public.void_cash_movement(p_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if public.current_user_role() <> 'root' then
    raise exception 'Solo root puede anular movimientos';
  end if;
  update public.cash_movements
    set voided = true, voided_by = auth.uid(), voided_at = now(), void_reason = p_reason
    where id = p_id and not voided;
end $$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function public.open_cash_session(numeric)                to authenticated;
    grant execute on function public.close_cash_session(numeric, text)         to authenticated;
    grant execute on function public.add_cash_movement(text, text, numeric, text, text) to authenticated;
    grant execute on function public.void_cash_movement(uuid, text)            to authenticated;
  end if;
end $$;

-- ---------- Storage: recibos (bucket PRIVADO) ----------
insert into storage.buckets (id, name, public)
  values ('receipts', 'receipts', false)
  on conflict (id) do nothing;

drop policy if exists "receipts_staff" on storage.objects;
create policy "receipts_staff" on storage.objects
  for all
  using (bucket_id = 'receipts' and public.current_user_role() in ('root', 'reception', 'accountant'))
  with check (bucket_id = 'receipts' and public.current_user_role() in ('root', 'reception', 'accountant'));
