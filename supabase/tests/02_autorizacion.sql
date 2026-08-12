-- =====================================================================
-- Autorización: el modelo fail-closed y los agujeros ya corregidos.
--
-- Los primeros bloques son REGRESIONES de vulnerabilidades reales que
-- estuvieron abiertas en producción. Si alguien vuelve a quitar un
-- guard, esto falla acá y no en el hotel.
--
-- OJO AL ESCRIBIR TESTS DE PERMISOS: pg_prove corre como `postgres`, y un
-- superusuario IGNORA los GRANT y la RLS. Para probar esas dos capas hay
-- que `set local role authenticated`; si no, todo "pasa" por el motivo
-- equivocado. Los guards internos (current_user_role) sí se pueden
-- probar sin cambiar de rol, porque leen el claim del JWT.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(17);

-- ---------- REGRESIÓN: escalada de privilegios por setup_employee ----------
-- Abierta desde el 3/7: cualquier autenticado se ascendía a root.
-- Se cerró con DOS barreras y se prueban las dos por separado.

-- Barrera 1: el guard interno de rol.
select set_config('request.jwt.claims',
  '{"sub":"55555555-5555-5555-5555-555555555555","role":"authenticated"}', true);
select is(public.current_user_role(), 'owner', 'el dueño es owner');
select throws_ok(
  $$ select public.setup_employee('duenio@local.test', 'duenio', 'root') $$,
  'P0001', 'No autorizado',
  'REGRESIÓN: setup_employee exige root'
);

-- Barrera 2: el permiso de ejecución, revocado de authenticated.
select ok(
  not has_function_privilege('authenticated', 'public.setup_employee(text,text,text)', 'execute'),
  'REGRESIÓN: setup_employee está revocada de authenticated'
);

-- ---------- REGRESIÓN: check-in sin guard de rol ----------
-- El único current_user_role() vivía dentro de la rama de tarifa, así que
-- un walk-in a precio de lista no validaba nada.
select throws_ok(
  format($$ select public.walk_in_check_in(%L, %L, 'X','Y','D','e@e.com',null,'BOL','LP',false,1,null,null) $$,
         (select id from public.rooms where operational_status='available' limit 1),
         (select o.room_type_id from public.room_type_options o
           join public.rooms rm on rm.id = o.room_id
          where rm.operational_status='available' limit 1)),
  'P0001', 'No autorizado para hacer check-in',
  'REGRESIÓN: el walk-in valida el rol aunque no se toque la tarifa'
);

-- ---------- REGRESIÓN: el registro elegía su propio rol ----------
select is(
  (select column_default from information_schema.columns
    where table_schema='public' and table_name='profiles' and column_name='role'),
  '''pending''::text',
  'REGRESIÓN: un perfil nuevo nace sin permisos, no como reception'
);
select ok(
  (select p.prosrc not like '%raw_user_meta_data->>''role''%'
     from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='handle_new_user'),
  'REGRESIÓN: el trigger no toma el rol del metadata del cliente'
);
select ok(
  'pending' not in (
    select unnest(regexp_matches(pg_get_expr(polqual, polrelid),
                                 'current_user_role\(\)[^)]*''(\w+)''', 'g'))
    from pg_policy
  ),
  'el rol pending no aparece en ninguna política'
);

-- ---------- owner es de SOLO LECTURA ----------
select throws_ok(
  $$ select public.open_cash_session(100) $$, 'P0001', null,
  'el dueño no abre caja'
);
select throws_ok(
  format($$ select public.add_folio_charge(%L, 'x', 1) $$,
         (select id from public.rooms limit 1)),
  'P0001', null,
  'el dueño no carga consumos'
);
select throws_ok(
  $$ select public.clock_in() $$, 'P0001', 'Tu usuario no ficha asistencia',
  'el dueño no ficha: no es empleado'
);
select isnt((select count(*) from public.list_anticipos(false, 50)), 0::bigint,
            'el dueño SÍ lee anticipos por RPC (no sólo por tabla)');

-- La RLS sólo se puede comprobar bajando de privilegios.
set local role authenticated;
select isnt((select count(*) from public.reservations), 0::bigint,
            'el dueño lee reservas con RLS activa');
select isnt((select count(*) from public.cash_movements), 0::bigint,
            'el dueño lee la caja con RLS activa');
update public.room_types set base_price_bs = 1;
select is((select count(*)::int from public.room_types where base_price_bs = 1), 0,
          'la RLS le impide cambiar precios escribiendo la tabla directo');
delete from public.people;
select isnt((select count(*) from public.people), 0::bigint,
            'la RLS le impide borrar personas');
reset role;

-- ---------- recepción sí opera ----------
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
select lives_ok(
  format($$ select public.add_folio_charge(%L, 'Restaurante', 50) $$,
         (select room_id from public.reservations where status='checked_in' limit 1)),
  'recepción sí carga consumos'
);
select lives_ok(
  $$ select public.clock_out() $$,
  'recepción sí ficha salida (tiene un turno abierto en el seed)'
);

select * from finish();
rollback;
