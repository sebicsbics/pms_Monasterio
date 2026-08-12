-- =====================================================================
-- CRÍTICO: `anon` pasaba TODOS los guards de rol.
-- (change: fix-null-role-bypass)
--
-- EL BUG, en una línea de SQL
-- `current_user_role()` devuelve el rol del perfil de `auth.uid()`. Para
-- un usuario sin sesión no hay fila, así que devolvía NULL. Y en SQL:
--
--     null not in ('root', 'reception')  →  NULL   (no FALSE, no TRUE)
--     if NULL then raise exception       →  NO dispara
--
-- Los 33 guards escritos como `if current_user_role() not in (...) then
-- raise` DEJABAN PASAR a `anon`. Como son funciones SECURITY DEFINER,
-- además se saltean la RLS.
--
-- VERIFICADO EN PRODUCCIÓN (transacción revertida), sin ninguna sesión:
--   · cargó un consumo al folio de un huésped — una escritura que cobra
--   · listó los anticipos
--   · leyó el historial completo de arqueos de caja
--   · pasó el guard de open_cash_session; sólo falló por la regla de
--     negocio de que ya había una caja abierta
--
-- No es un caso teórico: la clave `anon` viaja en el bundle del navegador.
--
-- EL ARREGLO DE RAÍZ
-- Una sola función. Si no hay sesión, el rol es 'anonymous' en vez de
-- NULL, y entonces:
--     'anonymous' not in ('root', …)  →  TRUE   → el guard dispara
--     'anonymous' in ('root', …)      →  FALSE  → los guards positivos
--                                                 y las políticas también
-- Corregir los 33 guards uno por uno habría sido la forma segura de
-- olvidarse de alguno, y de que el próximo naciera con el mismo defecto.
--
-- Se agrega además la barrera de permisos: `anon` deja de poder ejecutar
-- las funciones del negocio. Con el guard arreglado ya no le servirían,
-- pero un rol sin sesión no tiene por qué siquiera alcanzarlas.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) La raíz: sin sesión, rol conocido y sin privilegios.
-- ---------------------------------------------------------------------
create or replace function public.current_user_role()
returns text
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(
    (select role from public.profiles where id = auth.uid()),
    'anonymous'   -- NUNCA null: null rompe los guards escritos con `not in`
  );
$$;

comment on function public.current_user_role() is
  'Rol del usuario actual. Devuelve ''anonymous'' cuando no hay sesión — '
  'NUNCA null: `null not in (...)` evalúa a NULL y un IF con NULL no '
  'dispara, así que los guards dejaban pasar a anon.';

-- ---------------------------------------------------------------------
-- 2) Barrera de permisos: anon no ejecuta funciones del negocio.
--    Sólo conserva la traducción usuario → correo, que el login necesita
--    antes de que exista una sesión.
-- ---------------------------------------------------------------------
-- OJO: PostgreSQL otorga EXECUTE a PUBLIC por defecto, y `anon` hereda de
-- ahí. Revocar sólo `from anon` no hace nada: hay que quitar también el
-- permiso de PUBLIC. `authenticated` conserva el suyo, que es explícito
-- (20260811000000).
revoke execute on all functions in schema public from public, anon;
alter default privileges in schema public revoke execute on functions from public, anon;

grant execute on function public.username_to_email(text) to anon;

-- Y los predicados que usan las POLÍTICAS. Una política se evalúa con los
-- privilegios de quien consulta: si `anon` no pudiera ejecutarlos, una
-- consulta suya daría error en vez de devolver cero filas. No revelan
-- nada — para anon responden 'anonymous' y false.
grant execute on function public.current_user_role() to anon;
grant execute on function public.is_staff() to anon;

-- ---------------------------------------------------------------------
-- 3) search_path fijo en las 7 funciones que lo tenían mutable.
--
-- Las 7 son SECURITY INVOKER, así que no había escalada posible: corren
-- con los permisos de quien llama. Es endurecimiento, no un agujero —
-- evita que un search_path manipulado cambie a qué tabla o función
-- resuelven los nombres.
-- ---------------------------------------------------------------------
alter function public.available_rooms(date, date, integer)      set search_path = public;
alter function public.discount_pct(numeric, numeric)            set search_path = public;
alter function public.create_employee(text, text, text, text, date, numeric)
                                                                set search_path = public;
alter function public.register_stock_entry(date, boolean, text, text, text, jsonb)
                                                                set search_path = public;
alter function public.touch_maintenance_ticket()                set search_path = public;
alter function public.trigger_set_timestamp()                   set search_path = public;

-- La séptima es una sobrecarga muerta: `arrivals(p_date)` quedó de antes
-- del rango de fechas (20260727000000) y no la llama nadie — el frontend
-- usa arrivals(p_from, p_to). Se elimina en vez de endurecerla.
drop function if exists public.arrivals(date);
