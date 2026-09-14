-- =====================================================================
-- Contrato institucional: create_bulk_reservation es TODO O NADA para
-- payer_mode='client' (change: group-billing, stage 6, Slice 2b --
-- atomicidad, branch feat/booking-12-contract-bulk-atomicity).
--
-- feat/booking-11-contract-bulk (archivo 19_group_billing_contract_
-- bulk.sql) dejó el camino 'client' como best-effort por habitación,
-- igual que each_stay: si una habitación fallaba, la booking y las
-- habitaciones ya creadas en vueltas anteriores del loop quedaban
-- persistidas igual, con un contract_agreed PARCIAL (fixture_d1 de ese
-- archivo documenta el gap explícitamente). Esta migración agrega
-- `raise;` dentro del bloque exception por-habitación para
-- payer_mode='client' -- relanza la excepción ORIGINAL (mismo SQLSTATE,
-- mismo mensaje), lo que aborta la sentencia completa que invocó a la
-- función y revierte TODO: la booking, la cuenta por cobrar recién
-- creada (si la hubo), las habitaciones ya creadas en vueltas
-- anteriores del mismo loop, sus people/reservation_guests/
-- stay_segments, y cualquier rate_overrides/rate_discount_requests/
-- booking_balances generados en este intento. El camino each_stay NO
-- cambia (sigue siendo best-effort, ver escenario (f) más abajo). El
-- `raise;` cubre CUALQUIER disparador dentro del bloque exception, sea
-- una regla de negocio (RAISE EXCEPTION) o un error de casteo no
-- capturado -- (a) y (d) prueban el camino RAISE EXCEPTION, (b) prueba
-- el camino de error de casteo no capturado (22P02), igual que el
-- review-fix de feat/booking-11 pero ahora con rollback total en vez de
-- quedar contenido en failed[].
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(15);

select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true); -- root

-- ---------------------------------------------------------------------
-- Fixtures compartidos.
-- ---------------------------------------------------------------------

do $$
declare v_account uuid;
begin
  insert into public.receivable_accounts (name, kind)
  values ('Fixture Atomicidad Bulk', 'empresa')
  returning id into v_account;
  create temp table fixture_account as select v_account as account_id;
end $$;

-- 3 habitaciones físicas de un tipo sin uso en 19_group_billing_
-- contract_bulk.sql (Triple Estándar, max_occ=3, base_price=600), para
-- no depender de qué haya dejado cualquier otro archivo de test (cada
-- archivo corre en su propia transacción con rollback, pero esto evita
-- CUALQUIER ambigüedad).
create temp table fixture_rooms as
  select o.room_id, o.room_type_id, row_number() over (order by o.room_id) as rn
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 3 and rt.base_price_bs = 600
    and o.room_id not in (select room_id from public.reservations)
  order by o.room_id limit 3;

-- Habitación adicional de OTRO tipo (Suite Master Simple, max_occ=1,
-- base_price=650), reservada exclusivamente para el escenario (f)
-- each_stay -- así no compite por habitaciones con los escenarios
-- client (a)-(e), que reutilizan fixture_rooms.rn=1/2/3 sabiendo que
-- cada throws_matching revierte TODO lo que esa llamada haya intentado
-- crear.
create temp table fixture_room_f as
  select o.room_id, o.room_type_id
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 650
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

-- fixture_rooms.rn=2 queda OCUPADA de antemano (reserva confirmada real,
-- no vía la RPC) para forzar "La habitación ya no está disponible para
-- esas fechas" en (a) y (f), y para servir de "habitación con dato
-- inválido" en (b)/(c)/(d) -- en esos tres casos el bloque exception
-- lanza por el cast/validación ANTES de llegar al chequeo de
-- disponibilidad, así que da igual que esté ocupada.
do $$
declare v_person uuid; v_booking uuid; v_room uuid; v_type uuid;
begin
  insert into public.people (first_name, last_name) values ('Ocupante', 'Previo')
    returning id into v_person;
  insert into public.guests (person_id) values (v_person);
  insert into public.bookings (contact_person_id, payer_mode, rate_mode)
    values (v_person, 'each_stay', 'room') returning id into v_booking;
  select room_id, room_type_id into v_room, v_type from fixture_rooms where rn = 2;
  insert into public.reservations (
    guest_id, room_id, room_type_id, check_in_date, check_out_date,
    reservation_method, payment_status, total_amount_bs, status, num_guests, booking_id
  ) values (
    v_person, v_room, v_type, '2027-08-01', '2027-08-03', 'phone', 'pending', 600, 'confirmed', 1, v_booking
  );
end $$;

create or replace function pg_temp.snap() returns text language sql as $$
  select row(
    (select count(*) from public.people),
    (select count(*) from public.bookings),
    (select count(*) from public.reservations),
    (select count(*) from public.receivable_accounts),
    (select count(*) from public.booking_balances),
    (select count(*) from public.reservation_guests),
    (select count(*) from public.stay_segments),
    (select count(*) from public.rate_overrides),
    (select count(*) from public.rate_discount_requests)
  )::text
$$;

-- ---------------------------------------------------------------------
-- (a, R2.5 -- brief scenario 1) client bulk, 3 habitaciones, cuenta
--     NUEVA (p_new_account_name), habitación 2 ya ocupada (overlap) ->
--     TODA la llamada relanza el mismo mensaje que produce el chequeo
--     de disponibilidad, y NINGUNA tabla cambia: ni la booking, ni la
--     cuenta nueva (que se resuelve/inserta ANTES del loop), ni la
--     habitación 1 (que se procesa PRIMERO en el loop y habría tenido
--     éxito bajo el comportamiento de feat/booking-11, incluido su
--     ocupante precargado -> people/reservation_guests), ni la 3.
-- ---------------------------------------------------------------------
create temp table snap_a as select pg_temp.snap() as s;

select throws_matching(
  $$ select public.create_bulk_reservation(
       jsonb_build_array(
         jsonb_build_object('room_id', (select room_id from fixture_rooms where rn=1),
           'room_type_id', (select room_type_id from fixture_rooms where rn=1), 'num_guests', 2,
           'occupants', jsonb_build_array(jsonb_build_object('first_name','Titular','last_name','UnoA'))),
         jsonb_build_object('room_id', (select room_id from fixture_rooms where rn=2),
           'room_type_id', (select room_type_id from fixture_rooms where rn=2), 'num_guests', 2),
         jsonb_build_object('room_id', (select room_id from fixture_rooms where rn=3),
           'room_type_id', (select room_type_id from fixture_rooms where rn=3), 'num_guests', 2)
       ),
       'Cliente', 'AtomicoA', '70200001', 'atomico.a@fixture.test',
       '2027-08-01', '2027-08-03', 'phone',
       null, null, 'client', 'room', null, null,
       'Cuenta Nueva Atomico A', 'empresa'
     ) $$,
  'La habitación ya no está disponible para esas fechas',
  '(a) client bulk, habitación 2 ocupada, cuenta NUEVA: TODA la llamada relanza el mismo mensaje (all-or-nothing)'
);

select is(pg_temp.snap(), (select s from snap_a),
  '(a) ninguna tabla cambia -- ni la cuenta nueva ni la habitación 1, que hubiera tenido éxito bajo feat/booking-11 (people/reservation_guests incluidos)');

-- ---------------------------------------------------------------------
-- (b, brief scenario 2) client bulk, 2 habitaciones, cuenta EXISTENTE,
--     habitación 2 con is_courtesy='not-a-bool' (JSON mal formado) ->
--     el cast (elem->>'is_courtesy')::boolean lanza 22P02 DENTRO del
--     bloque exception; para 'client' eso también relanza y aborta
--     TODA la llamada (a diferencia del review-fix de feat/booking-11,
--     que lo dejaba contenido en failed[] para SEGUIR siendo
--     best-effort -- acá el punto es que 'client' nunca es
--     best-effort). Cero cambios en ninguna tabla.
-- ---------------------------------------------------------------------
create temp table snap_b as select pg_temp.snap() as s;

select throws_matching(
  $$ select public.create_bulk_reservation(
       jsonb_build_array(
         jsonb_build_object('room_id', (select room_id from fixture_rooms where rn=1),
           'room_type_id', (select room_type_id from fixture_rooms where rn=1), 'num_guests', 2),
         jsonb_build_object('room_id', (select room_id from fixture_rooms where rn=2),
           'room_type_id', (select room_type_id from fixture_rooms where rn=2), 'num_guests', 2,
           'is_courtesy', 'not-a-bool')
       ),
       'Cliente', 'AtomicoB', '70200002', 'atomico.b@fixture.test',
       '2027-08-05', '2027-08-07', 'phone',
       null, null, 'client', 'room', null, (select account_id from fixture_account)
     ) $$,
  'invalid input syntax for type boolean',
  '(b) client bulk, is_courtesy mal formado en la habitación 2: TODA la llamada relanza el error de casteo (22P02), no queda en failed[]'
);

select is(pg_temp.snap(), (select s from snap_b),
  '(b) ninguna tabla cambia tras el error de casteo no capturado');

-- ---------------------------------------------------------------------
-- (c, brief scenario 3) client + rate_mode='person', cuenta EXISTENTE,
--     habitación 2 sin la clave num_guests -> relanza el mensaje de
--     cabecera obligatoria en español. Cero cambios en ninguna tabla.
-- ---------------------------------------------------------------------
create temp table snap_c as select pg_temp.snap() as s;

select throws_matching(
  $$ select public.create_bulk_reservation(
       jsonb_build_array(
         jsonb_build_object('room_id', (select room_id from fixture_rooms where rn=1),
           'room_type_id', (select room_type_id from fixture_rooms where rn=1), 'num_guests', 2),
         jsonb_build_object('room_id', (select room_id from fixture_rooms where rn=2),
           'room_type_id', (select room_type_id from fixture_rooms where rn=2))
       ),
       'Cliente', 'AtomicoC', '70200003', 'atomico.c@fixture.test',
       '2027-08-08', '2027-08-09', 'phone',
       null, null, 'client', 'person', 300, (select account_id from fixture_account)
     ) $$,
  'Indicá la cantidad de huéspedes',
  '(c) client+person, num_guests ausente en la habitación 2: TODA la llamada relanza el mensaje en español'
);

select is(pg_temp.snap(), (select s from snap_c),
  '(c) ninguna tabla cambia tras el headcount faltante en modo persona');

-- ---------------------------------------------------------------------
-- (d, brief scenario 4) client bulk, cuenta EXISTENTE, habitación 2 con
--     is_courtesy=true sin courtesy_reason -> relanza. La cuenta
--     EXISTENTE queda intacta (mismo nombre, ninguna fila nueva) y
--     ninguna otra tabla cambia.
-- ---------------------------------------------------------------------
create temp table snap_d as select pg_temp.snap() as s;

select throws_matching(
  $$ select public.create_bulk_reservation(
       jsonb_build_array(
         jsonb_build_object('room_id', (select room_id from fixture_rooms where rn=1),
           'room_type_id', (select room_type_id from fixture_rooms where rn=1), 'num_guests', 2),
         jsonb_build_object('room_id', (select room_id from fixture_rooms where rn=2),
           'room_type_id', (select room_type_id from fixture_rooms where rn=2), 'num_guests', 2,
           'is_courtesy', true)
       ),
       'Cliente', 'AtomicoD', '70200004', 'atomico.d@fixture.test',
       '2027-08-13', '2027-08-14', 'phone',
       null, null, 'client', 'room', null, (select account_id from fixture_account)
     ) $$,
  'La cortesía requiere un motivo',
  '(d) client bulk, cortesía sin motivo en la habitación 2, cuenta EXISTENTE: TODA la llamada relanza'
);

select is(pg_temp.snap(), (select s from snap_d),
  '(d) ninguna tabla cambia -- la cuenta existente y todo lo demás quedan intactos');
select is(
  (select name from public.receivable_accounts where id = (select account_id from fixture_account)),
  'Fixture Atomicidad Bulk',
  '(d) la cuenta EXISTENTE reutilizada no fue tocada (mismo nombre, no se le agregó/quitó nada)'
);

-- ---------------------------------------------------------------------
-- (e, brief scenario 6) client bulk, 2 habitaciones, TODAS válidas,
--     cuenta EXISTENTE -> sigue funcionando de punta a punta: 2
--     reservas creadas, exactamente un contract_agreed = suma de
--     ambas. Usa fixture_rooms rn=1 y rn=3 (rn=2 sigue ocupada
--     permanentemente por el fixture de arriba).
-- ---------------------------------------------------------------------
do $$
declare v_result jsonb; v_booking uuid;
begin
  v_result := public.create_bulk_reservation(
    jsonb_build_array(
      jsonb_build_object('room_id', (select room_id from fixture_rooms where rn=1),
        'room_type_id', (select room_type_id from fixture_rooms where rn=1), 'num_guests', 2),
      jsonb_build_object('room_id', (select room_id from fixture_rooms where rn=3),
        'room_type_id', (select room_type_id from fixture_rooms where rn=3), 'num_guests', 2)
    ),
    'Cliente', 'AtomicoE', '70200005', 'atomico.e@fixture.test',
    '2027-08-16', '2027-08-18', 'phone',
    null, null, 'client', 'room', null, (select account_id from fixture_account)
  );
  select booking_id into v_booking from public.reservations
    where id = ((v_result->'created')->>0)::uuid;
  create temp table fixture_e as select v_result as result, v_booking as booking_id;
end $$;

select is(
  jsonb_array_length((select result from fixture_e)->'created'), 2,
  '(e) client bulk, ambas habitaciones válidas: las 2 reservas se crean (regresión, sigue funcionando)'
);
select is(
  (select count(*)::int from public.booking_balances
    where booking_id = (select booking_id from fixture_e) and event_type = 'contract_agreed'),
  1, '(e) client bulk todo válido: se inserta exactamente un contract_agreed'
);
select is(
  (select amount_bs from public.booking_balances where booking_id = (select booking_id from fixture_e)),
  2400.00, '(e) client bulk todo válido: contract_agreed = 600x2 noches x 2 habitaciones = 2400'
);

-- ---------------------------------------------------------------------
-- (f, brief scenario 5, REGRESIÓN) each_stay bulk, 2 habitaciones, la
--     habitación 2 (fixture_rooms rn=2) sigue ocupada -> el camino
--     each_stay NO cambia: sigue siendo best-effort, {created:[1],
--     failed:[1]}, exactamente como antes de este slice.
-- ---------------------------------------------------------------------
do $$
declare v_result jsonb;
begin
  v_result := public.create_bulk_reservation(
    jsonb_build_array(
      jsonb_build_object('room_id', (select room_id from fixture_room_f),
        'room_type_id', (select room_type_id from fixture_room_f), 'num_guests', 1),
      jsonb_build_object('room_id', (select room_id from fixture_rooms where rn=2),
        'room_type_id', (select room_type_id from fixture_rooms where rn=2), 'num_guests', 2)
    ),
    'EachStay', 'AtomicoF', '70200006', 'atomico.f@fixture.test',
    '2027-08-01', '2027-08-03', 'phone'
  );
  create temp table fixture_f as select v_result as result;
end $$;

select is(
  jsonb_array_length((select result from fixture_f)->'created'), 1,
  '(f) each_stay bulk, habitación 2 ocupada: la llamada NO lanza, 1 habitación creada (regresión)'
);
select is(
  jsonb_array_length((select result from fixture_f)->'failed'), 1,
  '(f) each_stay bulk, habitación 2 ocupada: exactamente 1 habitación queda en failed (regresión)'
);
select is(
  (select count(*)::int from public.reservations where room_id = (select room_id from fixture_room_f)),
  1, '(f) each_stay bulk: la habitación válida SÍ se creó pese a que la otra falló (best-effort intacto)'
);

select * from finish();
rollback;
