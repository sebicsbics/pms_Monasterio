-- =====================================================================
-- CRÍTICO: datos personales y del negocio legibles SIN sesión.
-- (change: close-public-reads)
--
-- LO QUE ESTABA PASANDO
-- El rol `anon` —el que tiene cualquiera con la clave pública que viaja
-- en el bundle del navegador, sin loguearse— podía leer:
--
--     148 personas          nombre, correo, teléfono, fecha de nacimiento
--     146 huéspedes         pasaporte, país, ciudad, perfil de viaje
--   7.782 estadías          diez años de historia del hotel
--      12 vistas analíticas ingresos por año, ocupación, mezcla de pagos
--
-- Reservas, caja, folios y anticipos SÍ estaban protegidos: tienen
-- políticas por rol. El agujero eran las tablas que quedaron con
-- `using (true)` para SELECT.
--
-- MI ERROR, para que quede escrito
-- En 20260809010000 cerré la ESCRITURA de estas 16 tablas y dejé la
-- lectura abierta razonando que "el riesgo siempre fue la escritura".
-- Eso es cierto para un catálogo de tipos de habitación y falso para una
-- tabla con números de pasaporte. La clasificación correcta no es
-- lectura/escritura: es qué contiene la tabla.
--
-- POR QUÉ EL AVISO DEL LINTER NO ALCANZABA
-- Supabase marca las 12 vistas `v_*` como SECURITY DEFINER y sugiere
-- `security_invoker = on`. Se probó: con el invoker activado, `anon`
-- SEGUÍA leyendo los ingresos, porque las vistas leen de
-- `historical_stays`, que estaba abierta. Aplicar sólo esa receta habría
-- silenciado la advertencia dejando los datos expuestos — peor que no
-- tocar nada, porque el tablero se pone en verde.
--
-- El arreglo es en las dos capas: las vistas respetan al que consulta, y
-- las tablas de abajo dejan de ser públicas.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Un solo predicado para "es personal del hotel con rol asignado".
--    `pending` queda afuera: es una cuenta recién registrada.
-- ---------------------------------------------------------------------
create or replace function public.is_staff()
returns boolean
language sql
stable
set search_path = public
as $$
  select public.current_user_role() in
    ('root', 'accountant', 'reception', 'reception_admin', 'owner');
$$;

grant execute on function public.is_staff() to authenticated;

comment on function public.is_staff() is
  'Usuario con rol operativo asignado. Se usa en las políticas de lectura '
  'para que anon (sin sesión) y pending (sin rol) no lean nada.';

-- ---------------------------------------------------------------------
-- 2) Tablas con datos personales o del negocio: sólo personal.
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'people',          -- nombre, correo, teléfono, nacimiento
    'guests',          -- pasaporte, país, perfil de viaje
    'historical_stays',-- diez años de operación
    'products',        -- costos y precios de venta
    'stock_entries',
    'stock_entry_items'
  ] loop
    execute format('drop policy if exists %I on public.%I', t || '_read', t);
    execute format(
      'create policy %I on public.%I for select using (public.is_staff())',
      t || '_read', t
    );
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 3) Catálogos: tampoco hace falta que sean públicos.
--
-- La aplicación exige login para todo; antes de autenticarse sólo se
-- llama a `username_to_email`, que es una función SECURITY DEFINER y no
-- depende de estas políticas. Nada se rompe al cerrarlos, y se deja de
-- publicar el mapa del hotel y su lista de precios.
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'rooms', 'room_types', 'room_type_options', 'room_bed_assignments',
    'bed_types', 'payment_methods', 'reservation_channels',
    'channel_aliases', 'maintenance_categories', 'product_categories'
  ] loop
    execute format('drop policy if exists %I on public.%I', t || '_read', t);
    execute format(
      'create policy %I on public.%I for select using (public.is_staff())',
      t || '_read', t
    );
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 4) Las 12 vistas analíticas pasan a respetar al que consulta.
--
-- Con los pasos 2 y 3 la fuga ya está cerrada, pero una vista SECURITY
-- DEFINER seguiría saltándose la RLS de sus tablas: hoy no filtra nada
-- de más, y mañana —cuando alguien agregue una política por rol sobre
-- `historical_stays`— la vista la ignoraría en silencio. Con invoker, la
-- vista hereda siempre lo que puede ver quien pregunta.
-- ---------------------------------------------------------------------
do $$
declare v record;
begin
  for v in
    select c.relname
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'v'
      and coalesce((select option_value from pg_options_to_table(c.reloptions)
                     where option_name = 'security_invoker'), 'off') = 'off'
  loop
    execute format('alter view public.%I set (security_invoker = on)', v.relname);
    raise notice 'security_invoker activado en %', v.relname;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 5) Y que anon no conserve permisos de tabla que ya no necesita.
--    La RLS alcanza para bloquearlo, pero un rol sin sesión no tiene por
--    qué figurar con permisos sobre el esquema del negocio.
-- ---------------------------------------------------------------------
revoke all on all tables in schema public from anon;
alter default privileges in schema public revoke all on tables from anon;

-- Excepción: el login necesita traducir usuario → correo antes de existir
-- una sesión, y eso pasa por una función, no por una tabla.
grant execute on function public.username_to_email(text) to anon;
