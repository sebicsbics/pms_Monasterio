-- =====================================================================
-- arrivals(): sumar la cuenta por cobrar de la reserva institucional
-- (change: fix/institutional-ui-coherence). El check-in de una
-- habitación enlazada a una reserva bulk (payer_mode='client') ya
-- conoce la agencia/empresa/persona responsable -- vive en
-- bookings.receivable_account_id -- pero el frontend obligaba a
-- retipearla a mano en cada check-in.
--
-- Reescritura de SOLO EL CUERPO (misma firma de 2 parámetros, sin
-- DROP): agrega account_name y account_kind, NULL cuando la reserva es
-- each_stay o cuando siendo 'client' no tiene cuenta asociada todavía
-- (no debería pasar -- create_bulk_reservation exige cuenta para
-- payer_mode='client' -- pero se deja nullable por robustez, igual que
-- holder_first_name/last_name en este mismo RPC).
-- =====================================================================
drop function if exists public.arrivals(date, date);

create or replace function public.arrivals(p_from date, p_to date)
returns table (
  reservation_id    uuid,
  room_id           uuid,
  room_number       text,
  room_type         text,
  first_name        text,
  last_name         text,
  phone             text,
  email             text,
  check_in_date     date,
  check_out_date    date,
  num_guests        int,
  max_occupancy     int,
  method            text,
  anticipo_total_bs numeric,
  holder_first_name text,
  holder_last_name  text,
  account_name      text,
  account_kind      text
)
language sql
stable
security invoker
set search_path = public
as $$
  select
    r.id, rm.id, rm.room_number::text, rt.name::text,
    p.first_name::text, p.last_name::text, p.phone::text, p.email::text,
    r.check_in_date, r.check_out_date, r.num_guests, rt.max_occupancy,
    r.reservation_method::text,
    coalesce((
      select sum(a.amount_bs) from public.anticipos a
      where a.reservation_id = r.id and a.status = 'active'
    ), 0),
    hp.first_name::text, hp.last_name::text,
    ra.name::text, ra.kind::text
  from public.reservations r
  join public.rooms      rm on rm.id = r.room_id
  join public.room_types rt on rt.id = r.room_type_id
  join public.bookings   b  on b.id = r.booking_id
  join public.people     p  on p.id = b.contact_person_id
  left join public.people hp on hp.id = r.guest_id
  left join public.receivable_accounts ra on ra.id = b.receivable_account_id
  where r.status = 'confirmed'
    and r.check_in_date <= p_to
    and (p_from is null or r.check_in_date >= p_from)
  order by r.check_in_date, rm.room_number::int;
$$;

-- El drop se lleva los grants: re-otorgar exactamente como quedaron en
-- 20260911010000_guest_id_nullable_create_paths.sql (expone PII, sólo
-- authenticated).
revoke execute on function public.arrivals(date, date) from public, anon;
grant execute on function public.arrivals(date, date) to authenticated;
