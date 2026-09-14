-- =====================================================================
-- Contrato institucional: create_bulk_reservation soporta payer_mode,
-- rate_mode y cortesía por habitación al crear (change: group-billing,
-- stage 6, Slice 2b -- core, branch feat/booking-11-contract-bulk).
--
-- Cambia la aridad de create_bulk_reservation (10 -> 18 parámetros, 8
-- nuevos al final, todos con default = comportamiento actual). Este
-- archivo prueba TANTO la regresión each_stay (nada cambia) como el
-- camino nuevo 'client' (room/person, cortesía por habitación, cuenta
-- por cobrar, gate de rol, tarifa custom, contrato congelado al final)
-- -- SIN atomicidad all-or-nothing todavía (eso es
-- feat/booking-12-contract-bulk-atomicity, archivo 19a).
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(58);

-- ---------------------------------------------------------------------
-- Fixtures compartidos (como postgres/superusuario).
-- ---------------------------------------------------------------------

do $$
declare
  v_account uuid;
begin
  insert into public.receivable_accounts (name, kind)
  values ('Fixture Contract Bulk Activa', 'empresa')
  returning id into v_account;

  create temp table fixture_account as select v_account as account_id;
end $$;

do $$
declare
  v_account uuid;
begin
  insert into public.receivable_accounts (name, kind, is_active)
  values ('Fixture Contract Bulk Inactiva', 'empresa', false)
  returning id into v_account;

  create temp table fixture_inactive_account as select v_account as account_id;
end $$;

create or replace function pg_temp.snap() returns text language sql as $$
  select row(
    (select count(*) from public.people),
    (select count(*) from public.bookings),
    (select count(*) from public.reservations),
    (select count(*) from public.receivable_accounts),
    (select count(*) from public.booking_balances)
  )::text
$$;

select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true); -- root

-- ---------------------------------------------------------------------
-- (a) REGRESIÓN: each_stay sin parámetros nuevos, 2 habitaciones,
--     resultado idéntico al de antes de este slice. Ningún evento en
--     booking_balances.
-- ---------------------------------------------------------------------
do $$
declare
  v_room1 uuid; v_type1 uuid; v_room2 uuid; v_type2 uuid;
  v_result jsonb; v_res1 uuid; v_res2 uuid; v_booking uuid;
begin
  select o.room_id, o.room_type_id into v_room1, v_type1
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 350
    and o.room_id not in (select room_id from public.reservations)
  limit 1;
  select o.room_id, o.room_type_id into v_room2, v_type2
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 2 and rt.base_price_bs = 480
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_result := public.create_bulk_reservation(
    jsonb_build_array(
      jsonb_build_object('room_id', v_room1, 'room_type_id', v_type1, 'num_guests', 1),
      jsonb_build_object('room_id', v_room2, 'room_type_id', v_type2, 'num_guests', 2)
    ),
    'Cada', 'Habitación', '70100001', 'eachstay.bulk@fixture.test',
    '2027-06-01', '2027-06-03', 'phone'
  );
  v_res1 := ((v_result->'created')->>0)::uuid;
  v_res2 := ((v_result->'created')->>1)::uuid;
  select booking_id into v_booking from public.reservations where id = v_res1;

  create temp table fixture_a as
    select v_res1 as reservation_id_1, v_res2 as reservation_id_2, v_booking as booking_id;
end $$;

select is(
  (select total_amount_bs from public.reservations where id = (select reservation_id_1 from fixture_a)),
  700.00, 'each_stay bulk sin campos nuevos: habitación 1 = 350x2 = 700'
);
select is(
  (select total_amount_bs from public.reservations where id = (select reservation_id_2 from fixture_a)),
  960.00, 'each_stay bulk sin campos nuevos: habitación 2 = 480x2 = 960'
);
select is(
  (select payer_mode from public.bookings where id = (select booking_id from fixture_a)),
  'each_stay', 'each_stay bulk sin campos nuevos: payer_mode default sigue siendo each_stay'
);
select is(
  (select count(*)::int from public.booking_balances where booking_id = (select booking_id from fixture_a)),
  0, 'each_stay bulk no genera ningún evento en booking_balances'
);

-- ---------------------------------------------------------------------
-- (b) client + rate_mode='room', reception_admin, 3 habitaciones, una
--     cortesía -> contract_agreed = suma de las 2 NO cortesía.
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true); -- reception_admin

do $$
declare
  v_room1 uuid; v_type1 uuid; v_room2 uuid; v_type2 uuid; v_room3 uuid; v_type3 uuid;
  v_result jsonb; v_res_courtesy uuid; v_booking uuid;
begin
  select o.room_id, o.room_type_id into v_room1, v_type1
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 2 and rt.base_price_bs = 480
    and o.room_id not in (select room_id from public.reservations)
  order by o.room_id limit 1;
  select o.room_id, o.room_type_id into v_room2, v_type2
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 2 and rt.base_price_bs = 480
    and o.room_id not in (select room_id from public.reservations) and o.room_id <> v_room1
  order by o.room_id limit 1;
  select o.room_id, o.room_type_id into v_room3, v_type3
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 350
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_result := public.create_bulk_reservation(
    jsonb_build_array(
      jsonb_build_object('room_id', v_room1, 'room_type_id', v_type1, 'num_guests', 2),
      jsonb_build_object('room_id', v_room2, 'room_type_id', v_type2, 'num_guests', 2),
      jsonb_build_object('room_id', v_room3, 'room_type_id', v_type3, 'num_guests', 1,
        'is_courtesy', true, 'courtesy_reason', 'Cortesía de gerencia')
    ),
    'Hotel', 'Tres Salas', '70100002', 'contacto.treesalas@fixture.test',
    '2027-06-04', '2027-06-06', 'phone',
    null, null, 'client', 'room', null, (select account_id from fixture_account)
  );
  select id, booking_id into v_res_courtesy, v_booking
  from public.reservations where room_id = v_room3;

  create temp table fixture_b as select v_res_courtesy as courtesy_reservation_id, v_booking as booking_id;
end $$;

select is(
  (select count(*)::int from public.booking_balances
    where booking_id = (select booking_id from fixture_b) and event_type = 'contract_agreed'),
  1, 'client+room 3 habitaciones (1 cortesía): se inserta exactamente un contract_agreed'
);
select is(
  (select amount_bs from public.booking_balances where booking_id = (select booking_id from fixture_b)),
  1920.00, 'client+room 3 habitaciones: contract_agreed = suma de las 2 NO cortesía (960+960=1920)'
);
select is(
  (select total_amount_bs from public.reservations where id = (select courtesy_reservation_id from fixture_b)),
  0.00, 'client+room: la habitación cortesía queda en total_amount_bs=0'
);

-- ---------------------------------------------------------------------
-- (c) client + rate_mode='person', root, precio=300, 2 noches, 2
--     habitaciones con 4 y 2 huéspedes NO cortesía -> totales 2400 y
--     1200, contract=3600.
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true); -- root

do $$
declare
  v_room1 uuid; v_type1 uuid; v_room2 uuid; v_type2 uuid;
  v_result jsonb; v_res1 uuid; v_res2 uuid; v_booking uuid;
begin
  select o.room_id, o.room_type_id into v_room1, v_type1
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 4 and rt.base_price_bs = 780
    and o.room_id not in (select room_id from public.reservations)
  limit 1;
  select o.room_id, o.room_type_id into v_room2, v_type2
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 2 and rt.base_price_bs = 480
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_result := public.create_bulk_reservation(
    jsonb_build_array(
      jsonb_build_object('room_id', v_room1, 'room_type_id', v_type1, 'num_guests', 4),
      jsonb_build_object('room_id', v_room2, 'room_type_id', v_type2, 'num_guests', 2)
    ),
    'Grupo', 'Persona', '70100003', 'grupo.persona.bulk@fixture.test',
    '2027-06-07', '2027-06-09', 'phone',
    null, null, 'client', 'person', 300, (select account_id from fixture_account)
  );
  v_res1 := ((v_result->'created')->>0)::uuid;
  v_res2 := ((v_result->'created')->>1)::uuid;
  select booking_id into v_booking from public.reservations where id = v_res1;

  create temp table fixture_c as select v_res1 as reservation_id_1, v_res2 as reservation_id_2, v_booking as booking_id;
end $$;

select is(
  (select total_amount_bs from public.reservations where id = (select reservation_id_1 from fixture_c)),
  2400.00, 'client+person: habitación con 4 huéspedes = 300x4x2 = 2400'
);
select is(
  (select total_amount_bs from public.reservations where id = (select reservation_id_2 from fixture_c)),
  1200.00, 'client+person: habitación con 2 huéspedes = 300x2x2 = 1200'
);
select is(
  (select amount_bs from public.booking_balances where booking_id = (select booking_id from fixture_c)),
  3600.00, 'client+person: contract_agreed = 2400+1200 = 3600'
);

-- ---------------------------------------------------------------------
-- (d, neg) rate_mode='person', una sola habitación, num_guests
--          ausente/NULL/0. IMPORTANTE: esta validación vive DENTRO del
--          bloque exception por-habitación (best-effort, sin cambios
--          respecto al body actual -- el all-or-nothing es
--          feat/booking-12), así que la llamada NO lanza una excepción
--          al caller: devuelve {created:[], failed:[{room_id,error}]}.
--          "Sin creación parcial" se prueba en (d1) chequeando 0
--          reservations y 0 contract_agreed para esa booking -- la fila
--          de `bookings` en sí SÍ queda persistida (huérfana), gap
--          documentado para feat/booking-12-contract-bulk-atomicity.
-- ---------------------------------------------------------------------
do $$
declare v_room uuid; v_type uuid; v_result jsonb; v_booking uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 2 and rt.base_price_bs = 480
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_result := public.create_bulk_reservation(
    jsonb_build_array(jsonb_build_object('room_id', v_room, 'room_type_id', v_type)),
    'Sin', 'Huespedes', '70100004', 'sin.huespedes.bulk@fixture.test',
    '2027-06-10', '2027-06-12', 'phone',
    null, null, 'client', 'person', 300, (select account_id from fixture_account)
  );
  select id into v_booking from public.bookings where contact_person_id =
    (select id from public.people where email = 'sin.huespedes.bulk@fixture.test');

  create temp table fixture_d1 as select v_result as result, v_booking as booking_id;
end $$;

select is(
  jsonb_array_length((select result from fixture_d1)->'created'), 0,
  'person mode, num_guests ausente en el JSON: ninguna reserva creada (queda en failed)'
);
select ok(
  ((select result from fixture_d1)->'failed'->0->>'error') ~ 'Indicá la cantidad de huéspedes',
  'person mode, num_guests ausente: el mensaje en español queda en failed[0].error'
);
select is(
  (select count(*)::int from public.reservations where booking_id = (select booking_id from fixture_d1)),
  0, 'person mode, num_guests ausente: sin creación parcial -- 0 reservations para esa booking'
);
select is(
  (select count(*)::int from public.booking_balances where booking_id = (select booking_id from fixture_d1)),
  0, 'person mode, num_guests ausente: sin contract_agreed (0 habitaciones creadas)'
);

do $$
declare v_room uuid; v_type uuid; v_result jsonb;
begin
  select o.room_id, o.room_type_id into v_room, v_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 2 and rt.base_price_bs = 480
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_result := public.create_bulk_reservation(
    jsonb_build_array(jsonb_build_object('room_id', v_room, 'room_type_id', v_type, 'num_guests', null)),
    'Null', 'Huespedes', '70100005', 'null.huespedes.bulk@fixture.test',
    '2027-06-10', '2027-06-12', 'phone',
    null, null, 'client', 'person', 300, (select account_id from fixture_account)
  );
  create temp table fixture_d2 as select v_result as result;
end $$;

select is(
  jsonb_array_length((select result from fixture_d2)->'created'), 0,
  'person mode, num_guests=NULL explícito: ninguna reserva creada'
);
select ok(
  ((select result from fixture_d2)->'failed'->0->>'error') ~ 'Indicá la cantidad de huéspedes',
  'person mode, num_guests=NULL explícito: el mensaje en español queda en failed[0].error'
);

do $$
declare v_room uuid; v_type uuid; v_result jsonb;
begin
  select o.room_id, o.room_type_id into v_room, v_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 2 and rt.base_price_bs = 480
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_result := public.create_bulk_reservation(
    jsonb_build_array(jsonb_build_object('room_id', v_room, 'room_type_id', v_type, 'num_guests', 0)),
    'Cero', 'Huespedes', '70100006', 'cero.huespedes.bulk@fixture.test',
    '2027-06-10', '2027-06-12', 'phone',
    null, null, 'client', 'person', 300, (select account_id from fixture_account)
  );
  create temp table fixture_d3 as select v_result as result;
end $$;

select is(
  jsonb_array_length((select result from fixture_d3)->'created'), 0,
  'person mode, num_guests=0 explícito: ninguna reserva creada'
);
select ok(
  ((select result from fixture_d3)->'failed'->0->>'error') ~ 'Cada habitación necesita al menos 1 persona',
  'person mode, num_guests=0 explícito: el mensaje en español queda en failed[0].error'
);

-- ---------------------------------------------------------------------
-- (e, neg) cortesía en una booking each_stay. Misma nota que (d): la
--          validación vive dentro del bloque exception por-habitación
--          -- no lanza, queda en failed.
-- ---------------------------------------------------------------------
do $$
declare v_room uuid; v_type uuid; v_result jsonb;
begin
  select o.room_id, o.room_type_id into v_room, v_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 350
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_result := public.create_bulk_reservation(
    jsonb_build_array(jsonb_build_object(
      'room_id', v_room, 'room_type_id', v_type, 'num_guests', 1,
      'is_courtesy', true, 'courtesy_reason', 'Intento de cortesía'
    )),
    'Cortesía', 'EachStay', '70100007', 'cortesia.eachstay.bulk@fixture.test',
    '2027-06-13', '2027-06-15', 'phone'
  );
  create temp table fixture_e as select v_result as result;
end $$;

select is(
  jsonb_array_length((select result from fixture_e)->'created'), 0,
  'cortesía en una booking each_stay: ninguna reserva creada'
);
select ok(
  ((select result from fixture_e)->'failed'->0->>'error') ~ 'La cortesía al crear sólo aplica a reservas institucionales',
  'cortesía en una booking each_stay: el mensaje en español queda en failed[0].error'
);

-- ---------------------------------------------------------------------
-- (f, neg) cortesía sin motivo válido: ausente / '' / '   ' -> los tres
--          quedan en failed con el mismo mensaje (misma nota que d/e).
-- ---------------------------------------------------------------------
do $$
declare v_room uuid; v_type uuid; v_result jsonb;
begin
  select o.room_id, o.room_type_id into v_room, v_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 450
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_result := public.create_bulk_reservation(
    jsonb_build_array(jsonb_build_object(
      'room_id', v_room, 'room_type_id', v_type, 'num_guests', 1, 'is_courtesy', true
    )),
    'Cortesía', 'SinMotivo1', '70100008', 'cortesia.sinmotivo1.bulk@fixture.test',
    '2027-06-16', '2027-06-18', 'phone',
    null, null, 'client', 'room', null, (select account_id from fixture_account)
  );
  create temp table fixture_f1 as select v_result as result;
end $$;

select ok(
  ((select result from fixture_f1)->'failed'->0->>'error') ~ 'La cortesía requiere un motivo',
  'cortesía sin la clave courtesy_reason: el mensaje en español queda en failed[0].error'
);

do $$
declare v_room uuid; v_type uuid; v_result jsonb;
begin
  select o.room_id, o.room_type_id into v_room, v_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 450
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_result := public.create_bulk_reservation(
    jsonb_build_array(jsonb_build_object(
      'room_id', v_room, 'room_type_id', v_type, 'num_guests', 1,
      'is_courtesy', true, 'courtesy_reason', ''
    )),
    'Cortesía', 'SinMotivo2', '70100009', 'cortesia.sinmotivo2.bulk@fixture.test',
    '2027-06-16', '2027-06-18', 'phone',
    null, null, 'client', 'room', null, (select account_id from fixture_account)
  );
  create temp table fixture_f2 as select v_result as result;
end $$;

select ok(
  ((select result from fixture_f2)->'failed'->0->>'error') ~ 'La cortesía requiere un motivo',
  'cortesía con courtesy_reason vacío (empty string): el mensaje en español queda en failed[0].error'
);

do $$
declare v_room uuid; v_type uuid; v_result jsonb;
begin
  select o.room_id, o.room_type_id into v_room, v_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 450
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_result := public.create_bulk_reservation(
    jsonb_build_array(jsonb_build_object(
      'room_id', v_room, 'room_type_id', v_type, 'num_guests', 1,
      'is_courtesy', true, 'courtesy_reason', '   '
    )),
    'Cortesía', 'SinMotivo3', '70100010', 'cortesia.sinmotivo3.bulk@fixture.test',
    '2027-06-16', '2027-06-18', 'phone',
    null, null, 'client', 'room', null, (select account_id from fixture_account)
  );
  create temp table fixture_f3 as select v_result as result;
end $$;

select ok(
  ((select result from fixture_f3)->'failed'->0->>'error') ~ 'La cortesía requiere un motivo',
  'cortesía con courtesy_reason de sólo espacios: el mensaje en español queda en failed[0].error'
);

-- ---------------------------------------------------------------------
-- (g, neg) reception intenta payer_mode='client' -> rechazado (decisión
--          #339: sólo root/reception_admin), cero efectos secundarios.
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

create temp table snap_g as select pg_temp.snap() as s;

select throws_matching(
  $$ select public.create_bulk_reservation(
       jsonb_build_array(jsonb_build_object(
         'room_id', (select o.room_id from public.room_type_options o
           join public.room_types rt on rt.id=o.room_type_id
           where rt.max_occupancy=2 and rt.base_price_bs=480
             and o.room_id not in (select room_id from public.reservations) limit 1),
         'room_type_id', (select o.room_type_id from public.room_type_options o
           join public.room_types rt on rt.id=o.room_type_id
           where rt.max_occupancy=2 and rt.base_price_bs=480
             and o.room_id not in (select room_id from public.reservations) limit 1),
         'num_guests', 2
       )),
       'Reception', 'Intenta', '70100011', 'reception.intenta.bulk@fixture.test',
       '2027-06-19', '2027-06-21', 'phone',
       null, null, 'client', 'room', null, (select account_id from fixture_account)
     ) $$,
  'Solo un administrador de recepción puede crear una reserva institucional',
  'reception intentando payer_mode=client en bulk: rechazado'
);
select is(pg_temp.snap(), (select s from snap_g),
  'la llamada rechazada (g, reception) no dejó gente/bookings/reservations/cuentas/ledger nuevos');

-- ---------------------------------------------------------------------
-- (h, neg) combos de cuenta inválidos: ninguna / ambas / inactiva ->
--          rechazado, cero efectos secundarios en los 3 casos.
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true); -- root

create temp table snap_h1 as select pg_temp.snap() as s;
select throws_matching(
  $$ select public.create_bulk_reservation(
       jsonb_build_array(jsonb_build_object(
         'room_id', (select o.room_id from public.room_type_options o
           join public.room_types rt on rt.id=o.room_type_id
           where rt.max_occupancy=2 and rt.base_price_bs=480
             and o.room_id not in (select room_id from public.reservations) limit 1),
         'room_type_id', (select o.room_type_id from public.room_type_options o
           join public.room_types rt on rt.id=o.room_type_id
           where rt.max_occupancy=2 and rt.base_price_bs=480
             and o.room_id not in (select room_id from public.reservations) limit 1),
         'num_guests', 2
       )),
       'Sin', 'Cuenta', '70100012', 'sin.cuenta.bulk@fixture.test',
       '2027-06-22', '2027-06-24', 'phone',
       null, null, 'client', 'room', null, null
     ) $$,
  'Elegí una cuenta existente o indicá los datos de la nueva cuenta',
  'client sin id existente ni datos de cuenta nueva: rechazado'
);
select is(pg_temp.snap(), (select s from snap_h1),
  'la llamada rechazada (h1, sin cuenta) no dejó gente/bookings/reservations/cuentas/ledger nuevos');

create temp table snap_h2 as select pg_temp.snap() as s;
select throws_matching(
  $$ select public.create_bulk_reservation(
       jsonb_build_array(jsonb_build_object(
         'room_id', (select o.room_id from public.room_type_options o
           join public.room_types rt on rt.id=o.room_type_id
           where rt.max_occupancy=2 and rt.base_price_bs=480
             and o.room_id not in (select room_id from public.reservations) limit 1),
         'room_type_id', (select o.room_type_id from public.room_type_options o
           join public.room_types rt on rt.id=o.room_type_id
           where rt.max_occupancy=2 and rt.base_price_bs=480
             and o.room_id not in (select room_id from public.reservations) limit 1),
         'num_guests', 2
       )),
       'Ambas', 'Cuentas', '70100013', 'ambas.cuentas.bulk@fixture.test',
       '2027-06-22', '2027-06-24', 'phone',
       null, null, 'client', 'room', null, (select account_id from fixture_account),
       'Otra cuenta bulk'
     ) $$,
  'Elegí una cuenta existente O creá una nueva',
  'client con id existente Y datos de cuenta nueva a la vez: rechazado'
);
select is(pg_temp.snap(), (select s from snap_h2),
  'la llamada rechazada (h2, ambas cuentas) no dejó gente/bookings/reservations/cuentas/ledger nuevos');

create temp table snap_h3 as select pg_temp.snap() as s;
select throws_matching(
  $$ select public.create_bulk_reservation(
       jsonb_build_array(jsonb_build_object(
         'room_id', (select o.room_id from public.room_type_options o
           join public.room_types rt on rt.id=o.room_type_id
           where rt.max_occupancy=2 and rt.base_price_bs=480
             and o.room_id not in (select room_id from public.reservations) limit 1),
         'room_type_id', (select o.room_type_id from public.room_type_options o
           join public.room_types rt on rt.id=o.room_type_id
           where rt.max_occupancy=2 and rt.base_price_bs=480
             and o.room_id not in (select room_id from public.reservations) limit 1),
         'num_guests', 2
       )),
       'Cuenta', 'Inactiva', '70100014', 'cuenta.inactiva.bulk@fixture.test',
       '2027-06-22', '2027-06-24', 'phone',
       null, null, 'client', 'room', null, (select account_id from fixture_inactive_account)
     ) $$,
  'Cuenta por cobrar inválida o inactiva',
  'client con una cuenta existente pero inactiva: rechazado'
);
select is(pg_temp.snap(), (select s from snap_h3),
  'la llamada rechazada (h3, cuenta inactiva) no dejó gente/bookings/reservations/cuentas/ledger nuevos');

-- ---------------------------------------------------------------------
-- (i) root, client+room, tarifa custom con descuento >20% -> aplicada
--     DIRECTO (nunca pending): total descontado, rate_overrides
--     auditado, una rate_discount_requests 'approved', cero 'pending',
--     contract_agreed = total descontado.
-- ---------------------------------------------------------------------
do $$
declare
  v_room uuid; v_type uuid; v_result jsonb; v_res uuid; v_booking uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 2 and rt.base_price_bs = 480
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_result := public.create_bulk_reservation(
    jsonb_build_array(jsonb_build_object('room_id', v_room, 'room_type_id', v_type, 'num_guests', 2)),
    'Root', 'Descuento Bulk', '70100015', 'root.descuento.bulk@fixture.test',
    '2027-06-25', '2027-06-27', 'phone',
    300, 'Descuento institucional negociado', 'client', 'room', null, (select account_id from fixture_account)
  );
  v_res := ((v_result->'created')->>0)::uuid;
  select booking_id into v_booking from public.reservations where id = v_res;

  create temp table fixture_i as select v_res as reservation_id, v_booking as booking_id;
end $$;

select is(
  (select total_amount_bs from public.reservations where id = (select reservation_id from fixture_i)),
  600.00, 'root + client+room bulk + tarifa 300 (vs 480 de lista) x 2 noches = 600, aplicado directo'
);
select is(
  (select count(*)::int from public.rate_overrides where reservation_id = (select reservation_id from fixture_i)),
  1, 'la tarifa custom en bulk queda auditada en rate_overrides'
);
select is(
  (select count(*)::int from public.rate_discount_requests
    where reservation_id = (select reservation_id from fixture_i) and status = 'approved'),
  1, 'el descuento >20% en bulk queda auditado como rate_discount_requests approved'
);
select is(
  (select count(*)::int from public.rate_discount_requests
    where reservation_id = (select reservation_id from fixture_i) and status = 'pending'),
  0, 'el descuento >20% de root en bulk NUNCA queda pending (decisión #339)'
);
select is(
  (select amount_bs from public.booking_balances where booking_id = (select booking_id from fixture_i)),
  600.00, 'contract_agreed en bulk usa el total YA descontado (600, no 960)'
);

-- ---------------------------------------------------------------------
-- (j) REGRESIÓN: reception crea each_stay bulk con tarifa custom con
--     descuento >20% -> sigue quedando 'pending', exactamente como
--     antes de este slice (camino each_stay 100% sin tocar).
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

do $$
declare
  v_room uuid; v_type uuid; v_result jsonb; v_res uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 2 and rt.base_price_bs = 480
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_result := public.create_bulk_reservation(
    jsonb_build_array(jsonb_build_object('room_id', v_room, 'room_type_id', v_type, 'num_guests', 2)),
    'Reception', 'Descuento Bulk', '70100016', 'reception.descuento.bulk@fixture.test',
    '2027-06-28', '2027-06-30', 'phone',
    300, 'Pide descuento grande'
  );
  v_res := ((v_result->'created')->>0)::uuid;

  create temp table fixture_j as select v_res as reservation_id;
end $$;

select is(
  (select total_amount_bs from public.reservations where id = (select reservation_id from fixture_j)),
  960.00, 'reception each_stay bulk descuento >20%: total SIGUE a precio de lista (480x2), no se aplica directo'
);
select is(
  (select count(*)::int from public.rate_discount_requests
    where reservation_id = (select reservation_id from fixture_j) and status = 'pending'),
  1, 'reception each_stay bulk descuento >20%: queda una solicitud pending, igual que siempre'
);
select is(
  (select count(*)::int from public.rate_overrides where reservation_id = (select reservation_id from fixture_j)),
  0, 'reception each_stay bulk descuento >20%: rate_overrides NO se toca hasta que se apruebe'
);

-- ---------------------------------------------------------------------
-- (k) stay_segments queda consistente con total_amount_bs/noches tanto
--     en modo persona (fixture_c) como con tarifa custom (fixture_i).
-- ---------------------------------------------------------------------
select is(
  (select rate_bs from public.stay_segments where reservation_id = (select reservation_id_1 from fixture_c)),
  1200.00, 'stay_segments.rate_bs modo persona, habitación 1: 2400/2 noches = 1200'
);
select is(
  (select rate_bs from public.stay_segments where reservation_id = (select reservation_id_2 from fixture_c)),
  600.00, 'stay_segments.rate_bs modo persona, habitación 2: 1200/2 noches = 600'
);
select is(
  (select rate_bs from public.stay_segments where reservation_id = (select reservation_id from fixture_i)),
  300.00, 'stay_segments.rate_bs con tarifa custom en bulk: 600/2 noches = 300 (igual a la tarifa pactada)'
);

-- ---------------------------------------------------------------------
-- (l, neg, mismo fix de sdd/group-billing/review-booking-10)
--          p_payer_mode=NULL / p_rate_mode=NULL -> rechazados con el
--          mensaje en español, no con un error crudo. Cero efectos
--          secundarios en ambos casos.
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true); -- root

create temp table snap_l1 as select pg_temp.snap() as s;
select throws_matching(
  $$ select public.create_bulk_reservation(
       jsonb_build_array(jsonb_build_object(
         'room_id', (select o.room_id from public.room_type_options o
           join public.room_types rt on rt.id=o.room_type_id
           where rt.max_occupancy=1 and rt.base_price_bs=350
             and o.room_id not in (select room_id from public.reservations) limit 1),
         'room_type_id', (select o.room_type_id from public.room_type_options o
           join public.room_types rt on rt.id=o.room_type_id
           where rt.max_occupancy=1 and rt.base_price_bs=350
             and o.room_id not in (select room_id from public.reservations) limit 1),
         'num_guests', 1
       )),
       'Payer', 'Nulo Bulk', '70100017', 'payer.nulo.bulk@fixture.test',
       '2027-07-01', '2027-07-03', 'phone',
       null, null, null, 'room'
     ) $$,
  'Modalidad de pago inválida',
  'p_payer_mode=NULL en bulk: rechazado con el mensaje en español, no con un error crudo'
);
select is(pg_temp.snap(), (select s from snap_l1),
  'la llamada rechazada (l1, payer_mode NULL) no dejó gente/bookings/reservations/cuentas/ledger nuevos');

create temp table snap_l2 as select pg_temp.snap() as s;
select throws_matching(
  $$ select public.create_bulk_reservation(
       jsonb_build_array(jsonb_build_object(
         'room_id', (select o.room_id from public.room_type_options o
           join public.room_types rt on rt.id=o.room_type_id
           where rt.max_occupancy=1 and rt.base_price_bs=350
             and o.room_id not in (select room_id from public.reservations) limit 1),
         'room_type_id', (select o.room_type_id from public.room_type_options o
           join public.room_types rt on rt.id=o.room_type_id
           where rt.max_occupancy=1 and rt.base_price_bs=350
             and o.room_id not in (select room_id from public.reservations) limit 1),
         'num_guests', 1
       )),
       'Rate', 'Nulo Bulk', '70100018', 'rate.nulo.bulk@fixture.test',
       '2027-07-01', '2027-07-03', 'phone',
       null, null, 'client', null, null, (select account_id from fixture_account)
     ) $$,
  'Modalidad de tarifa inválida',
  'p_rate_mode=NULL en bulk: rechazado con el mensaje en español, no con un error crudo'
);
select is(pg_temp.snap(), (select s from snap_l2),
  'la llamada rechazada (l2, rate_mode NULL) no dejó gente/bookings/reservations/cuentas/ledger nuevos');

-- ---------------------------------------------------------------------
-- (m, neg, fix sdd/group-billing/review-booking-11) each_stay bulk, 2
--          habitaciones, la habitación 2 trae is_courtesy='not-a-bool'
--          (valor JSON mal formado, no boolean). El cast NUEVO de este
--          slice ((elem->>'is_courtesy')::boolean) debe quedar DENTRO
--          del bloque exception por-habitación -- si corriera antes,
--          22P02 abortaría TODA la llamada, afectando incluso a
--          each_stay (que ni siquiera usa is_courtesy). Se espera: la
--          llamada NO lanza, habitación 1 se crea, habitación 2 queda
--          en failed CON SU PROPIO room_id (nunca stale ni NULL).
-- ---------------------------------------------------------------------
do $$
declare v_room1 uuid; v_type1 uuid; v_room2 uuid; v_type2 uuid; v_result jsonb;
begin
  select o.room_id, o.room_type_id into v_room1, v_type1
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 2 and rt.base_price_bs = 550
    and o.room_id not in (select room_id from public.reservations)
  order by o.room_id limit 1;
  select o.room_id, o.room_type_id into v_room2, v_type2
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 2 and rt.base_price_bs = 550
    and o.room_id not in (select room_id from public.reservations) and o.room_id <> v_room1
  order by o.room_id limit 1;

  v_result := public.create_bulk_reservation(
    jsonb_build_array(
      jsonb_build_object('room_id', v_room1, 'room_type_id', v_type1, 'num_guests', 2),
      jsonb_build_object('room_id', v_room2, 'room_type_id', v_type2, 'num_guests', 2, 'is_courtesy', 'not-a-bool')
    ),
    'EachStay', 'CortesiaMalformada', '70100019', 'eachstay.cortesiamalformada.bulk@fixture.test',
    '2027-07-04', '2027-07-06', 'phone'
  );

  create temp table fixture_m as select v_result as result, v_room1 as room1_id, v_room2 as room2_id;
end $$;

select is(
  jsonb_array_length((select result from fixture_m)->'created'), 1,
  'each_stay + is_courtesy mal formado en la habitación 2: la llamada NO lanza, 1 habitación creada'
);
select is(
  jsonb_array_length((select result from fixture_m)->'failed'), 1,
  'each_stay + is_courtesy mal formado: exactamente 1 habitación queda en failed'
);
select is(
  (select count(*)::int from public.reservations where room_id = (select room1_id from fixture_m)),
  1, 'each_stay + is_courtesy mal formado: la habitación 1 (válida) SÍ se creó'
);
select is(
  (select result from fixture_m)->'failed'->0->>'room_id', (select room2_id::text from fixture_m),
  'each_stay + is_courtesy mal formado: failed[0].room_id es el de la habitación 2 (nunca stale/NULL)'
);
select ok(
  ((select result from fixture_m)->'failed'->0->>'error') ~ 'invalid input syntax for type boolean',
  'each_stay + is_courtesy mal formado: el error de casteo queda contenido en failed[0].error'
);

-- ---------------------------------------------------------------------
-- (n, regresión) mismo patrón que (m) pero con num_guests='abc' --
--          ese cast YA vivía dentro del bloque exception antes de este
--          fix, así que debe seguir comportándose igual (guardia de no
--          regresión, no un fix nuevo).
-- ---------------------------------------------------------------------
do $$
declare v_room1 uuid; v_type1 uuid; v_room2 uuid; v_type2 uuid; v_result jsonb;
begin
  select o.room_id, o.room_type_id into v_room1, v_type1
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 500
    and o.room_id not in (select room_id from public.reservations)
  order by o.room_id limit 1;
  select o.room_id, o.room_type_id into v_room2, v_type2
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 500
    and o.room_id not in (select room_id from public.reservations) and o.room_id <> v_room1
  order by o.room_id limit 1;

  v_result := public.create_bulk_reservation(
    jsonb_build_array(
      jsonb_build_object('room_id', v_room1, 'room_type_id', v_type1, 'num_guests', 1),
      jsonb_build_object('room_id', v_room2, 'room_type_id', v_type2, 'num_guests', 'abc')
    ),
    'EachStay', 'GuestsMalformado', '70100020', 'eachstay.guestsmalformado.bulk@fixture.test',
    '2027-07-07', '2027-07-09', 'phone'
  );

  create temp table fixture_n as select v_result as result, v_room1 as room1_id, v_room2 as room2_id;
end $$;

select is(
  jsonb_array_length((select result from fixture_n)->'created'), 1,
  'each_stay + num_guests mal formado en la habitación 2: la llamada NO lanza, 1 habitación creada (regresión)'
);
select is(
  jsonb_array_length((select result from fixture_n)->'failed'), 1,
  'each_stay + num_guests mal formado: exactamente 1 habitación queda en failed (regresión)'
);
select is(
  (select result from fixture_n)->'failed'->0->>'room_id', (select room2_id::text from fixture_n),
  'each_stay + num_guests mal formado: failed[0].room_id es el de la habitación 2 (regresión)'
);
select ok(
  ((select result from fixture_n)->'failed'->0->>'error') ~ 'invalid input syntax for type integer',
  'each_stay + num_guests mal formado: el error de casteo queda contenido en failed[0].error (regresión)'
);

-- ---------------------------------------------------------------------
-- V-B: grants de la nueva firma de 18 parámetros; la vieja de 10
--      parámetros ya no existe.
-- ---------------------------------------------------------------------
select ok(
  has_function_privilege('authenticated',
    'public.create_bulk_reservation(jsonb,text,text,text,text,date,date,text,numeric,text,text,text,numeric,uuid,text,text,text,text)',
    'execute'),
  'authenticated puede ejecutar la nueva firma de 18 parámetros de create_bulk_reservation'
);
select ok(
  not has_function_privilege('anon',
    'public.create_bulk_reservation(jsonb,text,text,text,text,date,date,text,numeric,text,text,text,numeric,uuid,text,text,text,text)',
    'execute'),
  'anon NO puede ejecutar create_bulk_reservation'
);
select is(
  to_regprocedure('public.create_bulk_reservation(jsonb,text,text,text,text,date,date,text,numeric,text)'),
  null::regprocedure,
  'la firma vieja de 10 parámetros ya no existe (DROP FUNCTION de este slice)'
);

select * from finish();
rollback;
