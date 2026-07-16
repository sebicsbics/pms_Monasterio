-- =====================================================================
-- Tarifa editable en check-in / carga de reserva (root y reception).
-- Rompe el supuesto de que la tarifa deriva siempre del tipo de
-- habitación (descuentos, ventas de emergencia, etc.). La justificación
-- es OBLIGATORIA -- se cierra el agujero de fraude de "tarifa editable
-- sin rastro" exigiendo el motivo a nivel de RPC (no solo en la UI) y
-- registrando quién/cuándo/por qué en una tabla de auditoría separada
-- (no columnas sobre reservations, para no perder el historial si la
-- tarifa se corrige más de una vez).
--
-- RIESGO DOCUMENTADO Y NO RESUELTO EN ESTE CAMBIO: `reservations` y
-- `folios` todavía tienen políticas `dev_all` (`using (true)`) heredadas
-- de migraciones tempranas. Esto significa que un cliente autenticado
-- puede llamar `supabase.from('reservations').update({ total_amount_bs: ... })`
-- directamente, evitando por completo esta función y dejando CERO rastro
-- de auditoría. La función de abajo protege el flujo de la app (nadie en
-- el código React llama a un update crudo sobre la tarifa), pero NO es
-- suficiente contra un bypass deliberado (devtools, o un futuro update
-- descuidado en otro archivo). Requiere una SDD de seguimiento para
-- reemplazar `dev_all` por políticas por rol en reservations/folios.
-- =====================================================================

create table if not exists public.rate_overrides (
  id               uuid primary key default gen_random_uuid(),
  reservation_id   uuid not null references public.reservations(id),
  previous_rate_bs numeric(10,2) not null,
  new_rate_bs      numeric(10,2) not null,
  reason           text not null check (char_length(trim(reason)) > 0),
  changed_by       uuid not null references public.profiles(id),
  changed_at       timestamptz not null default now()
);

alter table public.rate_overrides enable row level security;

drop policy if exists "rate_overrides_read" on public.rate_overrides;
create policy "rate_overrides_read" on public.rate_overrides
  for select using (public.current_user_role() in ('root', 'reception', 'accountant'));

-- Sin política de insert/update/delete: la tabla solo se escribe desde
-- la función SECURITY DEFINER de abajo.

drop function if exists public.override_reservation_rate(uuid, numeric, text);

create or replace function public.override_reservation_rate(
  p_reservation_id uuid,
  p_new_rate       numeric,
  p_reason         text
)
returns public.reservations
language plpgsql
security definer
set search_path = public
as $$
declare
  v_prev    numeric(10,2);
  v_nights  int;
  v_row     public.reservations;
begin
  if public.current_user_role() not in ('root', 'reception') then
    raise exception 'No autorizado para cambiar la tarifa';
  end if;

  if p_reason is null or char_length(trim(p_reason)) = 0 then
    raise exception 'La justificación es obligatoria';
  end if;

  if p_new_rate is null or p_new_rate <= 0 then
    raise exception 'La tarifa debe ser un monto positivo';
  end if;

  select total_amount_bs, greatest(check_out_date - check_in_date, 1)
    into v_prev, v_nights
  from public.reservations
  where id = p_reservation_id;

  if not found then
    raise exception 'Reserva no encontrada';
  end if;

  update public.reservations
    set total_amount_bs = p_new_rate * v_nights
    where id = p_reservation_id
    returning * into v_row;

  insert into public.rate_overrides (reservation_id, previous_rate_bs, new_rate_bs, reason, changed_by)
    values (p_reservation_id, coalesce(v_prev, 0), p_new_rate, p_reason, auth.uid());

  return v_row;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function public.override_reservation_rate(uuid, numeric, text) to authenticated;
  end if;
end$$;
