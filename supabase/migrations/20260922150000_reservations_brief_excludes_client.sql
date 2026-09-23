-- =====================================================================
-- BUG: el selector de "Registrar anticipo" ofrecía habitaciones de
-- reservas institucionales (bookings.payer_mode = 'client'), que
-- record_anticipo ya rechaza desde feat/booking-17 (spec R6.4): "Las
-- reservas institucionales no usan anticipos por habitación; usá el
-- adelanto de grupo". El anticipo institucional se registra contra el
-- contrato completo vía record_booking_advance (feat/booking-14),
-- expuesto en "Grupos/Instituciones" (feat/booking-24). El modelo ya
-- es correcto y completo -- lo único que faltaba era que el selector
-- no ofreciera lo que la base ya rechaza (change:
-- fix/anticipos-exclude-institutional).
--
-- Body-only rewrite: misma firma y mismo RETURNS TABLE que
-- 20260729000000 -- así no hace falta DROP+CREATE, que borraría los
-- grants y el modificador de seguridad. Se agrega el join a bookings
-- y el filtro payer_mode <> 'client'. Guard de rol, SECURITY DEFINER
-- y search_path quedan sin cambios.
-- =====================================================================

create or replace function public.list_reservations_brief()
returns table (
  id             uuid,
  room_number    text,
  guest_name     text,
  check_in_date  date,
  check_out_date date,
  status         text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin', 'accountant', 'owner') then
    raise exception 'No autorizado';
  end if;

  return query
    select
      r.id, rm.room_number::text,
      (p.first_name || ' ' || p.last_name)::text,
      r.check_in_date, r.check_out_date, r.status::text
    from public.reservations r
    join public.rooms    rm on rm.id = r.room_id
    join public.guests   g  on g.person_id = r.guest_id
    join public.people   p  on p.id = g.person_id
    join public.bookings b  on b.id = r.booking_id
    where r.status in ('confirmed', 'checked_in')
      and b.payer_mode <> 'client'
    order by r.check_in_date, rm.room_number::int;
end;
$$;

-- Grants sin cambios (misma firma que 20260810020000): no se re-emiten acá.
