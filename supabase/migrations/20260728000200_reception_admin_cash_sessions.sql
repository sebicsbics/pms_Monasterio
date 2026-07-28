-- =====================================================================
-- reception_admin puede abrir y cerrar caja, en paridad con reception.
-- Omisión de 20260722010000_reception_admin_role.sql: ese cambio sí agregó
-- el rol a add_cash_movement y a las policies de lectura, pero no a los
-- RPC de apertura/cierre, dejando al rol sin poder abrir la caja en la
-- que sí puede registrar movimientos.
-- =====================================================================

create or replace function public.open_cash_session(p_opening numeric)
returns public.cash_sessions
language plpgsql
security definer
set search_path = public
as $function$
declare row public.cash_sessions;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado';
  end if;
  if exists (select 1 from public.cash_sessions where status = 'open') then
    raise exception 'Ya hay una caja abierta. Cerrala primero.';
  end if;
  insert into public.cash_sessions (opened_by, opening_balance_bs)
    values (auth.uid(), p_opening) returning * into row;
  return row;
end $function$;

create or replace function public.close_cash_session(p_counted numeric, p_notes text)
returns public.cash_sessions
language plpgsql
security definer
set search_path = public
as $function$
declare row public.cash_sessions;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
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
end $function$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function public.open_cash_session(numeric) to authenticated;
    grant execute on function public.close_cash_session(numeric, text) to authenticated;
  end if;
end $$;
