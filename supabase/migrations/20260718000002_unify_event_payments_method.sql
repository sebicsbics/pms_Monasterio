-- =====================================================================
-- Unifica `event_payments.method` con el catálogo canónico
-- `public.payment_methods` (mismo patrón que
-- 20260716000000_payment_methods_lookup.sql aplicó a
-- `reservations.payment_method`).
--
-- `event_payments.method` tenía un CHECK inline en minúscula
-- ('efectivo','qr','transferencia','tarjeta'), desconectado del catálogo
-- real que usa MAYÚSCULA. Todos los registros existentes se insertaron
-- solo a través de `add_event_payment` (no hay `.insert` directo desde
-- el frontend), así que los 4 valores posibles son 1:1 con 4 de los 10
-- códigos del catálogo — la normalización a mayúscula es sin pérdida.
-- =====================================================================

update public.event_payments
  set method = upper(method)
  where method is not null
    and method <> upper(method);

alter table public.event_payments drop constraint if exists event_payments_method_check;

alter table public.event_payments
  add constraint event_payments_method_fkey
  foreign key (method) references public.payment_methods(code)
  not valid;
alter table public.event_payments validate constraint event_payments_method_fkey;

-- ---------- add_event_payment: reemplaza el CHECK inline por la validación
-- contra el catálogo real (misma firma y lógica, solo cambia la validación) ----------
create or replace function public.add_event_payment(
  p_event_id uuid, p_amount numeric, p_method text, p_is_deposit boolean
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if public.current_user_role() not in ('root', 'reception') then
    raise exception 'No autorizado';
  end if;
  if not exists (
    select 1 from public.payment_methods where code = p_method and is_active
  ) then
    raise exception 'Forma de pago inválida: %', p_method;
  end if;

  insert into public.event_payments (event_id, amount_bs, method, is_deposit, created_by)
    values (p_event_id, p_amount, p_method, coalesce(p_is_deposit, false), auth.uid());

  if p_method = 'EFECTIVO' then
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
