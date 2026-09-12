-- =====================================================================
-- Agencia/empresa en check-in: columnas nuevas en reservations y las dos
-- RPC de check-in extendidas con parámetros finales opcionales.
--
-- Trampa de sobrecarga: agregar parámetros con CREATE OR REPLACE cambia
-- la aridad; si no se hace DROP primero queda una segunda versión de la
-- función y cualquier llamado con la aridad vieja se vuelve ambiguo. Este
-- archivo prueba las DOS cosas: que el llamado viejo (sin los parámetros
-- nuevos) sigue funcionando, y que exista una sola función por nombre.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(22);

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);

-- ---------- Esquema ----------
select has_column('public', 'reservations', 'agency_name',
  'reservations tiene agency_name');
select col_is_null('public', 'reservations', 'agency_name',
  'agency_name es nullable, sin default forzado');
select has_column('public', 'reservations', 'channel_code',
  'reservations tiene channel_code');
select col_is_null('public', 'reservations', 'channel_code',
  'channel_code es nullable');

-- ---------- Reservas del seed para los tres escenarios ----------
create temp table casos on commit drop as
select r.id as res_id, r.room_id, r.guest_id, row_number() over (order by r.id) as n
from public.reservations r
where r.status = 'confirmed'
order by r.id
limit 3;

-- ========== check_in_reservation_with_guests ==========

-- 1) Llamado a la vieja usanza (sin los parámetros nuevos): sigue
--    funcionando y las columnas nuevas quedan NULL.
select lives_ok(
  format(
    $$ select public.check_in_reservation_with_guests(%L, '11111111', '1990-01-01', 'BO', 'La Paz', true) $$,
    (select res_id from casos where n = 1)
  ),
  'check_in_reservation_with_guests sin los parámetros nuevos sigue funcionando'
);
select is(
  (select agency_name from public.reservations where id = (select res_id from casos where n = 1)),
  null,
  'sin pasar agencia, agency_name queda NULL'
);
select is(
  (select channel_code from public.reservations where id = (select res_id from casos where n = 1)),
  null,
  'sin pasar canal, channel_code queda NULL'
);

-- 2) Llamado con los parámetros nuevos: persisten, texto libre incluido.
select lives_ok(
  format(
    $$ select public.check_in_reservation_with_guests(%L, '22222222', '1990-01-01', 'BO', 'La Paz', true,
         null, null, null, null, '[]'::jsonb, 'Agencia Andina & Cía. 123', 'AGENCIA') $$,
    (select res_id from casos where n = 2)
  ),
  'check_in_reservation_with_guests con agencia y canal no explota'
);
select is(
  (select agency_name from public.reservations where id = (select res_id from casos where n = 2)),
  'Agencia Andina & Cía. 123',
  'agency_name persiste tal cual el texto libre, sin restricción de formato'
);
select is(
  (select channel_code from public.reservations where id = (select res_id from casos where n = 2)),
  'AGENCIA',
  'channel_code persiste el código elegido'
);

-- 3) channel_code inválido: viola la FK.
select throws_ok(
  format(
    $$ select public.check_in_reservation_with_guests(%L, '33333333', '1990-01-01', 'BO', 'La Paz', true,
         null, null, null, null, '[]'::jsonb, null, 'NO_EXISTE') $$,
    (select res_id from casos where n = 3)
  ),
  '23503',
  null,
  'un channel_code que no está en reservation_channels rompe la FK'
);

-- ========== walk_in_check_in_with_guests ==========

create temp table rooms_libres on commit drop as
select room_id, room_type_id, n from (
  select r.id as room_id, r.room_type_id, row_number() over (order by r.id) as n
  from public.rooms r
  where r.operational_status = 'available'
  limit 4
) x;

-- 1) Llamado viejo: sigue funcionando, columnas nuevas NULL.
select lives_ok(
  format(
    $$ select public.walk_in_check_in_with_guests(%L, %L, 'Juana', 'Perez', '44444444',
         'juana@test.com', '1990-01-01', 'BO', 'La Paz', true, 1) $$,
    (select room_id from rooms_libres where n = 1),
    (select room_type_id from rooms_libres where n = 1)
  ),
  'walk_in_check_in_with_guests sin los parámetros nuevos sigue funcionando'
);
select is(
  (select agency_name from public.reservations where room_id = (select room_id from rooms_libres where n = 1)
     order by created_at desc limit 1),
  null,
  'walk-in sin agencia: agency_name queda NULL'
);
select is(
  (select channel_code from public.reservations where room_id = (select room_id from rooms_libres where n = 1)
     order by created_at desc limit 1),
  null,
  'walk-in sin canal: channel_code queda NULL'
);

-- 2) Llamado con agencia y canal: persisten.
select lives_ok(
  format(
    $$ select public.walk_in_check_in_with_guests(%L, %L, 'Marco', 'Rios', '55555555',
         'marco@test.com', '1990-01-01', 'BO', 'La Paz', true, 1,
         null, null, null, null, null, null, '[]'::jsonb, 'Empresa Delta SRL', 'EMPRESA') $$,
    (select room_id from rooms_libres where n = 2),
    (select room_type_id from rooms_libres where n = 2)
  ),
  'walk_in_check_in_with_guests con agencia y canal no explota'
);
select is(
  (select agency_name from public.reservations where room_id = (select room_id from rooms_libres where n = 2)
     order by created_at desc limit 1),
  'Empresa Delta SRL',
  'walk-in persiste agency_name'
);
select is(
  (select channel_code from public.reservations where room_id = (select room_id from rooms_libres where n = 2)
     order by created_at desc limit 1),
  'EMPRESA',
  'walk-in persiste channel_code'
);

-- 3) channel_code inválido: FK.
select throws_ok(
  format(
    $$ select public.walk_in_check_in_with_guests(%L, %L, 'Nadie', 'Nadie', '66666666',
         'nadie@test.com', '1990-01-01', 'BO', 'La Paz', true, 1,
         null, null, null, null, null, null, '[]'::jsonb, null, 'NO_EXISTE') $$,
    (select room_id from rooms_libres where n = 3),
    (select room_type_id from rooms_libres where n = 3)
  ),
  '23503',
  null,
  'walk-in con channel_code inexistente rompe la FK'
);

-- ---------- Trampa de sobrecarga: una sola función por nombre ----------
select is(
  (select count(*)::int from pg_proc where proname = 'check_in_reservation_with_guests'),
  1,
  'check_in_reservation_with_guests tiene una única versión (no quedó la vieja sobrecarga)'
);
select is(
  (select count(*)::int from pg_proc where proname = 'walk_in_check_in_with_guests'),
  1,
  'walk_in_check_in_with_guests tiene una única versión'
);
select ok(
  has_function_privilege('authenticated',
    'public.check_in_reservation_with_guests(uuid,text,date,text,text,boolean,text,text,text,text,jsonb,text,text,text,text,uuid,text,text)',
    'execute'),
  'authenticated conserva EXECUTE sobre check_in_reservation_with_guests tras el drop+create'
);
select ok(
  has_function_privilege('authenticated',
    'public.walk_in_check_in_with_guests(uuid,uuid,text,text,text,text,date,text,text,boolean,integer,numeric,text,text,text,text,text,jsonb,text,text,text)',
    'execute'),
  'authenticated conserva EXECUTE sobre walk_in_check_in_with_guests tras el drop+create'
);

select * from finish();
rollback;
