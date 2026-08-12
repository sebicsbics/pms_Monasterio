-- =====================================================================
-- REGRESIÓN: nada del negocio se lee sin sesión.
--
-- Hubo un momento en que `anon` —cualquiera con la clave pública del
-- bundle— leía 148 personas con su correo y teléfono, 146 huéspedes con
-- número de pasaporte, 7.782 estadías y las 12 vistas analíticas.
--
-- El linter de Supabase sólo marcaba las vistas como SECURITY DEFINER.
-- Aplicar sólo esa receta NO cerraba nada: las vistas leen de
-- `historical_stays`, que estaba abierta. Por eso este archivo prueba la
-- fuga de punta a punta y no la configuración de las vistas.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

set local role anon;

select throws_ok($$ select count(*) from public.people $$,            '42501', null,
  'anon NO lee personas (nombre, correo, teléfono)');
select throws_ok($$ select count(*) from public.guests $$,            '42501', null,
  'anon NO lee huéspedes (pasaporte, procedencia)');
select throws_ok($$ select count(*) from public.historical_stays $$,  '42501', null,
  'anon NO lee la historia del hotel');
select throws_ok($$ select count(*) from public.v_revenue_by_year $$, '42501', null,
  'anon NO lee los ingresos por año');
select throws_ok($$ select count(*) from public.v_payment_mix $$,     '42501', null,
  'anon NO lee la mezcla de medios de pago');
select throws_ok($$ select count(*) from public.rooms $$,             '42501', null,
  'anon NO lee el mapa de habitaciones');
select throws_ok($$ select count(*) from public.room_types $$,        '42501', null,
  'anon NO lee la lista de precios');

reset role;

-- Una cuenta registrada pero sin rol asignado tampoco ve nada. Acá el
-- permiso de tabla SÍ existe (es authenticated), así que no hay error:
-- lo que filtra es la RLS, y devuelve cero filas.
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true);
set local role authenticated;
select is((select count(*) from public.people), 0::bigint,
          'una cuenta pending no lee personas');
select is((select count(*) from public.historical_stays), 0::bigint,
          'una cuenta pending no lee la historia');
reset role;

-- El personal sí trabaja: si esto falla, el arreglo se pasó de rosca.
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
set local role authenticated;
select isnt((select count(*) from public.rooms), 0::bigint,
            'recepción sí ve las habitaciones');
reset role;

select set_config('request.jwt.claims',
  '{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated"}', true);
set local role authenticated;
select isnt((select count(*) from public.v_revenue_by_year), 0::bigint,
            'contaduría sí ve la analítica');
reset role;

select * from finish();
rollback;
