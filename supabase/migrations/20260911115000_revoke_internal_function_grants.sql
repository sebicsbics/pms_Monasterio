-- =====================================================================
-- Revocar de authenticated las funciones internas que el grant masivo
-- volvió a abrir sin querer (change: group-billing, stage 6,
-- branch fix/revoke-internal-function-grants).
--
-- LA CAUSA RAÍZ
-- 20260811000000_explicit_table_grants.sql hace
-- `grant all on all functions in schema public to anon, authenticated,
-- service_role` y después revoca a mano una lista corta de 5 "excepciones"
-- (setup_employee, record_mixed_income, add_reservation_companions,
-- recalc_reservation_total, sync_single_stay_segment). Esa lista es un
-- checklist manual, y un checklist manual se puede olvidar.
--
-- Se olvidó `apply_rate_change`: `20260722020000_discount_approval_workflow.sql`
-- ya la había revocado de authenticated, pero el grant en bloque la
-- reabrió sin que la lista de excepciones la volviera a cerrar. Como
-- `p_base_price_bs` lo manda el que llama, cualquier `authenticated`
-- podía cambiarle la tarifa a cualquier reserva pasando base = precio
-- nuevo (0% de descuento calculado), sin pasar por la aprobación del
-- rol. Confirmado explotable en la base local (ver
-- sdd/group-billing/review-booking-13 en engram).
--
-- LA AUDITORÍA
-- Se revisaron las 76 funciones de public (excluidas las de extensión).
-- Además de apply_rate_change, otras 11 quedaban ejecutables por
-- authenticated sin necesitarlo:
--   - 6 helpers internos, cada uno con UN solo llamador SQL propio,
--     siempre otra función SECURITY DEFINER: assert_payment_proof,
--     check_in_reservation, discount_pct, payment_records_income,
--     room_is_free_between, walk_in_check_in.
--   - 5 funciones de trigger (RETURNS trigger), que se disparan solas y
--     no necesitan ser invocables a mano:
--     enforce_folio_charge_consumer_is_occupant, handle_new_user,
--     log_maintenance_event, touch_maintenance_ticket, trigger_set_timestamp.
--
-- Ninguna de las 12 tiene un llamador en src/ (verificado con
-- `supabase.rpc(` sobre todo src/, sin contar tests). Todas las que
-- sirven de ayudante interno son llamadas ÚNICAMENTE por otra función
-- SECURITY DEFINER, que sigue funcionando igual: adentro de una función
-- SECURITY DEFINER el chequeo de privilegios corre con los del dueño
-- (postgres), no con los del rol que inició la sesión. Por eso revocar
-- estas 12 de authenticated no rompe a create_reservation,
-- create_bulk_reservation, walk_in_check_in_with_guests,
-- check_in_reservation_with_guests, change_room, modify_stay_dates,
-- check_out_room, add_cash_movement, add_event_payment,
-- settle_receivable, record_anticipo ni modify_anticipo -- todas ellas
-- SECURITY DEFINER y ya ejecutables por authenticated por su cuenta.
-- La lista blanca en supabase/tests/21_function_grants_allowlist.sql
-- prueba ambas cosas: que ninguna de las 12 quede alcanzable y que esos
-- llamadores sigan funcionando.
--
-- LO QUE NO SE TOCA
-- `net_owed_bs(uuid)` queda ejecutable por authenticated: no es un
-- descuido de este grant masivo, se otorgó a propósito en su propia
-- migración (20260911090000_group_billing_ledger_core.sql) con su
-- propio guard de rol interno, y ya pasó una revisión de seguridad
-- dedicada (ver sdd/group-billing/net-owed-guard en engram). Que hoy
-- no tenga un llamador en src/ no la vuelve una fuga: es superficie
-- pública ya preparada para un slice de UI posterior de este mismo
-- cambio.
--
-- POR QUÉ NO SE TOCAN LOS DEFAULT PRIVILEGES
-- 20260811000000 fija `alter default privileges ... grant all on
-- functions to anon, authenticated, service_role`, y
-- 20260829010000_revoke_anon_grants.sql sólo le baja ese default a
-- `public` y `anon` -- a propósito deja a `authenticated` con acceso
-- por defecto a toda función nueva, porque la enorme mayoría de las
-- funciones que se crean en este proyecto SON RPC públicas para
-- staff autenticado. Si este archivo le bajara también el default de
-- `authenticated`, cada migración futura que agregue una RPC legítima
-- tendría que acordarse de reabrirla a mano -- exactamente el mismo
-- patrón de checklist manual que causó este bug, sólo que invertido.
-- La defensa real no es un default más estricto: es
-- 21_function_grants_allowlist.sql, que afirma la lista completa y
-- avisa apenas aparezca una función de más.
-- =====================================================================

-- ---------------------------------------------------------------------
-- El bug confirmado: apply_rate_change.
-- ---------------------------------------------------------------------
revoke execute on function public.apply_rate_change(
  uuid, uuid, numeric, integer, numeric, text
) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Helpers internos: cada uno con un único llamador SQL, siempre
-- SECURITY DEFINER.
-- ---------------------------------------------------------------------
revoke execute on function public.assert_payment_proof(text, text, text)
  from public, anon, authenticated;

revoke execute on function public.check_in_reservation(
  uuid, text, date, text, text, boolean
) from public, anon, authenticated;

revoke execute on function public.discount_pct(numeric, numeric)
  from public, anon, authenticated;

revoke execute on function public.payment_records_income(text)
  from public, anon, authenticated;

revoke execute on function public.room_is_free_between(uuid, date, date, uuid)
  from public, anon, authenticated;

revoke execute on function public.walk_in_check_in(
  uuid, uuid, text, text, text, text, date, text, text, boolean, integer, numeric, text
) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Funciones de trigger: se disparan solas, no hace falta invocarlas a
-- mano. Que queden ejecutables por authenticated no las abre a nadie
-- (Postgres rechaza igual con "trigger functions can only be called as
-- triggers"), pero es una capa de más que no debería existir -- el
-- mismo principio de las dos barreras de 20260829010000_revoke_anon_grants.sql.
-- ---------------------------------------------------------------------
revoke execute on function public.enforce_folio_charge_consumer_is_occupant()
  from public, anon, authenticated;

revoke execute on function public.handle_new_user()
  from public, anon, authenticated;

revoke execute on function public.log_maintenance_event()
  from public, anon, authenticated;

revoke execute on function public.touch_maintenance_ticket()
  from public, anon, authenticated;

revoke execute on function public.trigger_set_timestamp()
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- AL AGREGAR UNA FUNCIÓN NUEVA: si es un helper interno o un trigger,
-- agregala a la lista blanca en 21_function_grants_allowlist.sql tal
-- como se demuestra acá -- no dependas de que alguien recuerde
-- revocarla a mano. Y NUNCA vuelvas a correr un
-- `grant all on all functions in schema public to ...`: fue eso lo
-- que abrió este agujero.
-- ---------------------------------------------------------------------
