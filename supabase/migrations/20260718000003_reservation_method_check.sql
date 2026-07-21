-- Guardrail for the OPERATIONAL vocabulary of reservations.reservation_method.
--
-- reservation_method was a free varchar(50) with no constraint. It captures
-- how a live reservation was taken (phone/whatsapp/email/web/walk-in), and
-- is written exclusively by app code (NewReservation form, create_reservation
-- RPC, walk_in_check_in). It is UNRELATED to reservation_channels, which is a
-- separate ETL lookup table (DIRECTO/OTA/AGENCIA/EMPRESA/REFERIDO/EVENTO)
-- used only for analytics over historical_stays. Do not conflate the two.
--
-- Added `not valid` first and validated separately: if any existing row
-- somehow holds a value outside the 5-value vocabulary, `validate constraint`
-- will fail loudly at push time instead of the CHECK silently rejecting new
-- rows while leaving old bad data unnoticed.
alter table public.reservations
  add constraint reservations_reservation_method_check
  check (reservation_method in ('phone', 'whatsapp', 'email', 'web', 'walk-in'))
  not valid;

alter table public.reservations
  validate constraint reservations_reservation_method_check;
