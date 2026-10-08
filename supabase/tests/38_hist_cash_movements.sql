-- =====================================================================
-- hist_cash_movements: caja histórica del archivo Hotel/.
--
-- Nace cerrada: anon no la lee ni la escribe, una cuenta sin rol no ve
-- filas, el personal la lee y nadie la escribe desde la API (la carga corre
-- como dueño de la tabla desde el SQL del ETL).
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

select plan(7);

-- Una fila como dueño de la tabla (así la carga el ETL).
insert into public.hist_cash_movements
  (movement_date, kind, currency, amount, concept, source_file)
values ('2014-07-01', 'income', 'BOB', 200, 'HAB 5', 'test.xlsx');

select throws_ok(
  $$ insert into public.hist_cash_movements (movement_date, kind, currency, amount, source_file)
     values ('2014-07-01', 'refund', 'BOB', 1, 'x') $$,
  '23514', null, 'kind solo admite income/expense');

set local role anon;
select throws_ok($$ select count(*) from public.hist_cash_movements $$, '42501', null,
                 'anon no lee la caja histórica');
reset role;

-- Cuenta registrada sin rol: el permiso de tabla existe, la RLS filtra.
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true);
set local role authenticated;
select is((select count(*) from public.hist_cash_movements), 0::bigint,
          'una cuenta pending no lee la caja histórica');
reset role;

-- Recepción (sembrada en seed.sql) sí la lee...
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
set local role authenticated;
select is((select count(*) from public.hist_cash_movements), 1::bigint,
          'recepción lee la caja histórica');

-- ...pero no la escribe: sin permiso de tabla, ni insert ni update ni delete.
select throws_ok(
  $$ insert into public.hist_cash_movements (movement_date, kind, currency, amount, source_file)
     values ('2014-07-02', 'income', 'BOB', 1, 'x') $$,
  '42501', null, 'recepción no inserta en la caja histórica');
select throws_ok($$ update public.hist_cash_movements set amount = 0 $$, '42501', null,
                 'recepción no edita la caja histórica');
select throws_ok($$ delete from public.hist_cash_movements $$, '42501', null,
                 'recepción no borra la caja histórica');
reset role;

select * from finish();
rollback;
