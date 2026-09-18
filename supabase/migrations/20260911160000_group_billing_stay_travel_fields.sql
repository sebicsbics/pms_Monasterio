-- =====================================================================
-- Travel fields (origin_city, travel_purpose, transport_means) move to
-- reservation_guests (change: group-billing, stage 6, Slice 8a, branch
-- feat/booking-19-travel-fields-ddl). Spec R8.1, R8.2.
--
-- `occupation` stays on `guests` (person-level) -- not asked to move,
-- no reason invented.
--
-- V-E verified at apply time (2026-09-18, freshly reset local DB):
-- `select count(*) from reservation_guests where created_at is null`
-- returned 0, so the backfill query below does NOT need a
-- coalesce(rg.created_at, '-infinity') guard.
-- =====================================================================

alter table public.reservation_guests
  add column origin_city text,
  add column travel_purpose text,
  add column transport_means text;

with latest_stay as (
  select distinct on (rg.person_id) rg.id as rg_id
  from public.reservation_guests rg join public.reservations r on r.id = rg.reservation_id
  order by rg.person_id, r.check_in_date desc, rg.created_at desc
)
update public.reservation_guests rg
set origin_city = g.origin_city, travel_purpose = g.travel_purpose, transport_means = g.transport_means
from public.guests g, latest_stay ls
where g.person_id = rg.person_id and rg.id = ls.rg_id
  and (g.origin_city is not null or g.travel_purpose is not null or g.transport_means is not null);
