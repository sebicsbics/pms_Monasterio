-- =====================================================================
-- Blindar net_owed_bs con control de rol (fix sobre Slice 1, change:
-- group-billing, stage 6).
--
-- net_owed_bs(uuid), agregado en 20260911090000, es SECURITY DEFINER y
-- por lo tanto corre con los privilegios de su dueño -- eso hace que
-- IGNORE la política de RLS de booking_balances (booking_balances_read:
-- root/reception/reception_admin/accountant). Sin un guard de rol propio
-- (como sí tienen list_anticipos, 20260807010000, y check_out_room,
-- 20260729000200), cualquier rol autenticado -- incluido 'owner', que NO
-- está en booking_balances_read -- podía leer el saldo pendiente de
-- cualquier booking llamando la función directo. Confirmado en vivo: como
-- 'owner', `select * from booking_balances` = 0 filas, pero
-- `select net_owed_bs(...)` devolvía el monto real.
--
-- Se separa en dos funciones, mismo patrón que list_anticipos:
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

create or replace function public._net_owed_bs(p_booking_id uuid)
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

create or replace function public.net_owed_bs(p_booking_id uuid)
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
