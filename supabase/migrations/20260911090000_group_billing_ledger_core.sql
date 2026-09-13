-- =====================================================================
-- Ledger institucional (change: group-billing, stage 6, Slice 1).
--
-- Las reservas institucionales ("payer_mode='client'") necesitan un
-- registro de plata separado del de "cada quien paga su estadía": un
-- contrato pactado al crear, adelantos recibidos a cuenta del paquete, y
-- el cierre del grupo cuando ya no queda ninguna habitación activa. Todo
-- eso se modela como eventos en booking_balances, un libro APPEND-ONLY:
-- nunca se edita ni se borra una fila ya escrita, sólo se agregan nuevas.
-- Por eso `event_type` tiene sólo 3 valores posibles y no existe
-- 'room_settled' ni ningún tipo de reversa -- las correcciones, si hacen
-- falta, se resuelven a nivel de negocio (cancelar y rehacer), nunca
-- editando el ledger.
--
-- net_owed_bs(booking_id) es la ÚNICA fórmula de saldo pendiente: suma de
-- contract_agreed menos suma de advance_received. Todo el resto del stage
-- 6 (Slices 2 a 11) debe usar esta función, nunca recalcular el saldo a
-- mano.
--
-- receivables gana `booking_id` (con índice único parcial: a lo sumo un
-- receivable por booking) para que el cierre del grupo (Slice 5) pueda
-- dejar la deuda pendiente contra el booking completo, no contra una
-- reserva individual como hace hoy check_out_room con CTAS_POR_COBRAR.
--
-- net_owed_bs es SECURITY DEFINER y por lo tanto corre con los privilegios
-- de su dueño -- eso hace que IGNORE la política de RLS de booking_balances
-- (booking_balances_read: root/reception/reception_admin/accountant) si no
-- tiene guard de rol propio. Por eso se separa en dos funciones desde el
-- principio, mismo patrón que list_anticipos (20260807010000) y
-- check_out_room (20260729000200):
--   - _net_owed_bs: el cálculo puro, SIN guard de rol. La usan
--     triggers/RPCs internos (Slices 4, 5, 5b -- record_booking_advance,
--     _close_booking_group, settle_receivable) que corren en el contexto
--     de una acción ya autorizada (check-out, cancelación, adelanto) y
--     NUNCA deben fallar con "No autorizado" por el rol de quien la
--     disparó. Revocada de public, anon Y authenticated: nadie la llama
--     directo, sólo otras funciones SECURITY DEFINER.
--   - net_owed_bs: wrapper público, con el mismo guard de rol que
--     booking_balances_read. Es la única forma en que un cliente
--     (frontend/API) puede consultar el saldo.
--
-- IMPORTANTE para branches futuros de este stage: cualquier trigger/RPC
-- nuevo que necesite el saldo de un booking DEBE llamar `_net_owed_bs`,
-- nunca `net_owed_bs` (el guard de rol rompería un trigger disparado por
-- un rol que no esté en booking_balances_read, aunque la acción original
-- sí estuviera autorizada por su propio guard).
-- =====================================================================

create table public.booking_balances (
  id               uuid primary key default gen_random_uuid(),
  booking_id       uuid not null references public.bookings(id),
  event_type       text not null check (event_type in ('contract_agreed', 'advance_received', 'group_closed')),
  amount_bs        numeric(10,2) not null,
  reservation_id   uuid references public.reservations(id),
  payment_method   text references public.payment_methods(code),
  cash_movement_id uuid references public.cash_movements(id),
  notes            text,
  created_by       uuid references public.profiles(id) default auth.uid(),
  created_at       timestamptz not null default now()
);
create index idx_booking_balances_booking on public.booking_balances(booking_id);
create index idx_booking_balances_event on public.booking_balances(booking_id, event_type);

alter table public.booking_balances enable row level security;
create policy "booking_balances_read" on public.booking_balances
  for select using (public.current_user_role() in ('root', 'reception', 'reception_admin', 'accountant'));
-- Sin política de insert/update/delete a propósito: este ledger sólo se
-- escribe desde RPCs/triggers SECURITY DEFINER (Slices 2, 4, 5) que
-- corren como el dueño de la función, no como el rol autenticado. Ningún
-- rol de la app puede insertar, editar ni borrar filas directamente.

create function public._net_owed_bs(p_booking_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(amount_bs) filter (where event_type = 'contract_agreed'), 0)
       - coalesce(sum(amount_bs) filter (where event_type = 'advance_received'), 0)
  from public.booking_balances
  where booking_id = p_booking_id;
$$;
revoke execute on function public._net_owed_bs(uuid) from public, anon, authenticated;

create function public.net_owed_bs(p_booking_id uuid)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin', 'accountant') then
    raise exception 'No autorizado para ver saldos de grupo';
  end if;
  return public._net_owed_bs(p_booking_id);
end;
$$;
revoke execute on function public.net_owed_bs(uuid) from public, anon;
grant execute on function public.net_owed_bs(uuid) to authenticated;

alter table public.receivables add column booking_id uuid references public.bookings(id);
create unique index uniq_receivable_per_booking on public.receivables (booking_id) where booking_id is not null;
create index idx_receivables_booking on public.receivables (booking_id);
-- receivables.amount_bs ya tiene `check (amount_bs > 0)` desde
-- 20260729000200_receivables.sql -- verificado, sin cambios acá.
