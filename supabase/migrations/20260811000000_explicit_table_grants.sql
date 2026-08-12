-- =====================================================================
-- Permisos de tabla explícitos, para que el esquema sea autocontenido.
-- (change: explicit-table-grants)
--
-- EL PROBLEMA, descubierto al montar el entorno local
-- Los GRANT de tabla que tiene el proyecto de la nube NO los crean estas
-- migraciones: los puso la plataforma de Supabase al crear el proyecto,
-- vía `alter default privileges` sobre el rol `postgres`. En el stack
-- local esa configuración por defecto sólo otorga `Dxtm` (truncate,
-- references, trigger, maintain) — sin SELECT ni INSERT.
--
-- Resultado: producción tenía permisos en 62 objetos y una base
-- reconstruida desde las migraciones, en 16. Las tablas, las vistas, las
-- funciones y las 95 políticas coincidían; los permisos, no. Un esquema
-- que depende de configuración invisible del proveedor no es reproducible.
--
-- Esta migración es un NO-OP en producción (los permisos ya están) y hace
-- que cualquier entorno nuevo —local, staging o un proyecto de
-- recuperación— quede idéntico.
--
-- POR QUÉ ESTO NO AFLOJA LA SEGURIDAD
-- El GRANT es la capa gruesa: dice "este rol puede intentar". Quien
-- decide de verdad es la RLS, y todas las tablas la tienen activa. `anon`
-- recibe los mismos permisos que en producción y sigue sin pasar ninguna
-- política: `current_user_role()` devuelve null cuando no hay sesión.
-- Se replica el estado real, no se amplía.
-- =====================================================================

grant usage on schema public to anon, authenticated, service_role;

grant all on all tables    in schema public to anon, authenticated, service_role;
grant all on all sequences in schema public to anon, authenticated, service_role;
grant all on all functions in schema public to anon, authenticated, service_role;

-- Y que lo hereden los objetos que se creen de acá en adelante, para no
-- tener que acordarse en cada migración nueva.
alter default privileges in schema public
  grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public
  grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public
  grant all on functions to anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- Excepción: las funciones que se revocaron a propósito deben SEGUIR
-- revocadas. El `grant all on all functions` de arriba las habría
-- reabierto — incluida la que permitía escalar a root.
-- ---------------------------------------------------------------------
revoke execute on function public.setup_employee(text, text, text)
  from public, anon, authenticated;

revoke execute on function public.record_mixed_income(
  numeric, numeric, numeric, text, text, text, text, text
) from public, anon, authenticated;

revoke execute on function public.add_reservation_companions(uuid, jsonb)
  from public, anon, authenticated;

revoke execute on function public.recalc_reservation_total(uuid)
  from public, anon, authenticated;

revoke execute on function public.sync_single_stay_segment()
  from public, anon, authenticated;

-- (refund_anticipo se eliminó en 20260727000100: el hotel no reembolsa.)
