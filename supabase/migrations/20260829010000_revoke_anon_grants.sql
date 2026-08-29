-- =====================================================================
-- anon recupera la lista corta: sólo las 3 funciones que necesita.
--
-- Sobraban dos: check_out_room y lookup_guest_by_document.
--
-- Y NO llegan por un `grant ... to anon`. El privilegio viene de PUBLIC,
-- que en Postgres tiene EXECUTE sobre toda función nueva por defecto. Se ve
-- en el proacl:
--
--   check_out_room    {=X/postgres, postgres=X/..., authenticated=X/...}
--   add_folio_charge  {postgres=X/..., authenticated=X/...}
--                      ^ sin `=X`: acá alguien sí revocó PUBLIC
--
-- El grantee vacío de `=X` ES PUBLIC, y anon lo hereda. Por eso un
-- `revoke ... from anon` a secas no hace absolutamente nada — hay que
-- revocarle a PUBLIC, que es lo que hace el resto del repo
-- (`from public, anon, authenticated`).
--
-- CÓMO SE REABRIÓ: 20260812010000 revocó en bloque y fijó default
-- privileges. Pero 20260816000100_checkout_applies_anticipos.sql:25 DROPEA
-- check_out_room y la vuelve a crear, y una función recién creada nace con
-- EXECUTE para PUBLIC. `create or replace` conserva los permisos;
-- `drop` + `create` los resetea. Ésa es la trampa, y va a volver a pasar
-- cada vez que una RPC cambie de aridad.
--
-- NO es una puerta abierta: las dos tienen guard interno de rol y anon
-- rebota con "No autorizado" (verificado contra el sandbox). Pero el guard
-- es la primera barrera y ésta es la segunda, y la segunda existe porque la
-- primera ya falló una vez: current_user_role() devolvía NULL sin sesión,
-- los 33 guards escritos con `not in` evaluaban a NULL y no disparaban, y
-- sin ninguna sesión se llegó a cargar un consumo al folio de un huésped
-- (ver supabase/tests/04_anon_sin_privilegios.sql). Confiar en una sola
-- barrera es exactamente lo que produjo aquel incidente.
--
-- Auditoría completa antes de escribir esto: anon tiene CERO privilegios de
-- tabla y vista, y de funciones sólo estas cinco. No hay más arrastres.
-- (change: revoke-anon-grants)
-- =====================================================================

revoke execute on function public.check_out_room(
  uuid, text, text, text, uuid, numeric, numeric, text
) from public, anon;

revoke execute on function public.lookup_guest_by_document(text) from public, anon;

-- ---------------------------------------------------------------------
-- Las 3 que SÍ corresponden, reafirmadas para que este archivo documente
-- la lista completa y no sólo lo que quita:
--
--   username_to_email  — el login la llama ANTES de autenticarse: sin ella
--                        nadie puede entrar.
--   current_user_role  — predicado de las políticas RLS.
--   is_staff           — idem.
--
-- Los grants son idempotentes; están acá como declaración de intención.
-- ---------------------------------------------------------------------
grant execute on function public.username_to_email(text) to anon;
grant execute on function public.current_user_role()     to anon;
grant execute on function public.is_staff()              to anon;

-- ---------------------------------------------------------------------
-- Y se reafirman los default privileges de 20260812010000, para que la
-- próxima función que nazca no traiga PUBLIC de fábrica. No alcanza por sí
-- solo (no aplica a lo ya creado, ni a otro rol creador), pero baja la
-- frecuencia con que esto se repite. El que de verdad ataja es el test.
-- ---------------------------------------------------------------------
alter default privileges in schema public revoke execute on functions from public, anon;

-- ---------------------------------------------------------------------
-- AL AGREGAR O RE-CREAR UNA RPC: no copies el `to anon, authenticated` de la
-- migración de al lado, y si la DROPEÁS para cambiarle la firma, acordate
-- de que renace abierta a PUBLIC. anon es el visitante sin sesión: casi
-- ninguna RPC del negocio le corresponde. 04_anon_sin_privilegios.sql
-- afirma la lista exacta y te va a decir cuál sobra.
-- ---------------------------------------------------------------------
