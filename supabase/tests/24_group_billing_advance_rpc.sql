-- =====================================================================
-- Adelanto institucional: record_booking_advance (change: group-billing,
-- stage 6, Slice 4, branch feat/booking-14-advance-rpc).
--
-- Toda la plata que entra contra un booking 'client' (payer_mode)
-- ANTES del cierre del grupo pasa por acá, como evento
-- 'advance_received' en booking_balances -- nunca toca anticipos (eso
-- es solo para each_stay, spec R1.3/Global Facts). El despacho de caja
-- (efectivo/QR/tarjeta/depósito/mixto) es un calco del de
-- record_anticipo, verificado contra su cuerpo VIVO (pg_get_functiondef)
-- antes de escribir esta migración -- no se inventó ninguna validación
-- nueva de "forma de pago activa": add_cash_movement ya la hace vía
-- payment_records_income().
--
-- CORRECCIÓN a la asunción inicial de la tarea: el assert_payment_proof
-- VIVO (leído antes de escribir el RPC) sólo exige comprobante para QR
-- (foto) y TARJETA (referencia) -- DEPOSITO NO exige nada, ni acá ni en
-- record_anticipo ni en record_mixed_income (ver el comentario de esa
-- función: "DEPOSITO no pide nada; QR pide foto; TARJETA pide
-- referencia"). El escenario (c3) de abajo prueba DEPOSITO como éxito
-- sin comprobante, no como rechazo.
--
-- Orden de guards (todos NULL-safe, ver postgres/check-constraint-
-- null-trap): rol -> monto -> forma de pago (no nula, no
-- CTAS_POR_COBRAR) -> booking existe (con FOR UPDATE, para serializar
-- con el futuro trigger de cierre de feat/booking-15) -> payer_mode
-- 'client' -> el booking tiene contrato (contract_agreed) -> el booking
-- no está cerrado (group_closed). Recién ahí se despacha la caja.
--
-- El RPC devuelve el id del MOVIMIENTO DE CAJA (v_mov_id): en EFECTIVO/
-- QR/TARJETA/DEPOSITO es el movimiento único; en MIXTO es el de la pata
-- efectivo (record_mixed_income así lo define -- "es el que afecta el
-- cajón y el que hay que poder rastrear desde el arqueo"). NO devuelve
-- el id de la fila de booking_balances.
--
-- El sobrepago (adelanto mayor al saldo pendiente) está permitido por
-- diseño (net_owed_bs puede quedar negativo, registrado para
-- auditoría) -- no se bloquea, se documenta en (h). Pregunta de negocio
-- para el orquestador: ¿alguna vez se debería avisar/bloquear un
-- sobrepago en la UI (Slice 11)? Este RPC no lo hace.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(36);

-- ---------------------------------------------------------------------
-- Fixtures (como postgres/superusuario).
-- ---------------------------------------------------------------------
do $$
declare
  v_account uuid;
begin
  insert into public.receivable_accounts (name, kind)
  values ('Fixture Advance RPC', 'empresa')
  returning id into v_account;

  create temp table fixture_account as select v_account as account_id;
end $$;

-- fixture_client: booking 'client'/'room', creado por reception_admin,
-- 2 noches x 350 = 700 -> contract_agreed=700 automático (Slice 2).
select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true); -- reception_admin

do $$
declare
  v_room uuid; v_room_type uuid; v_reservation uuid; v_booking uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_room_type
  from public.room_type_options o
  join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 350
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_reservation := public.create_reservation(
    v_room, v_room_type, 'Cliente', 'Advance Uno', '70000101', 'advance.uno@fixture.test',
    '2027-06-01', '2027-06-03', 1, 'phone', null, null, true,
    'client', 'room', null, (select account_id from fixture_account),
    null, null, null, null, false, null
  );
  select booking_id into v_booking from public.reservations where id = v_reservation;

  create temp table fixture_client as select v_booking as booking_id;
end $$;

-- fixture_client2: segundo booking 'client', para el escenario MIXTO
-- (no compartir booking con el resto: el contrato se calcularía distinto).
do $$
declare
  v_room uuid; v_room_type uuid; v_reservation uuid; v_booking uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_room_type
  from public.room_type_options o
  join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 350
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_reservation := public.create_reservation(
    v_room, v_room_type, 'Cliente', 'Advance Dos', '70000102', 'advance.dos@fixture.test',
    '2027-06-04', '2027-06-06', 1, 'phone', null, null, true,
    'client', 'room', null, (select account_id from fixture_account),
    null, null, null, null, false, null
  );
  select booking_id into v_booking from public.reservations where id = v_reservation;

  create temp table fixture_client2 as select v_booking as booking_id;
end $$;

-- fixture_client3: tercer booking 'client', para el escenario de
-- comprobante (QR/TARJETA/DEPOSITO) y para amount/CTAS_POR_COBRAR.
do $$
declare
  v_room uuid; v_room_type uuid; v_reservation uuid; v_booking uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_room_type
  from public.room_type_options o
  join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 350
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_reservation := public.create_reservation(
    v_room, v_room_type, 'Cliente', 'Advance Tres', '70000103', 'advance.tres@fixture.test',
    '2027-06-07', '2027-06-09', 1, 'phone', null, null, true,
    'client', 'room', null, (select account_id from fixture_account),
    null, null, null, null, false, null
  );
  select booking_id into v_booking from public.reservations where id = v_reservation;

  create temp table fixture_client3 as select v_booking as booking_id;
end $$;

-- fixture_each_stay: booking normal, para el negativo de payer_mode.
do $$
declare
  v_room uuid; v_room_type uuid; v_reservation uuid; v_booking uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_room_type
  from public.room_type_options o
  join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 350
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_reservation := public.create_reservation(
    v_room, v_room_type, 'Cliente', 'Each Stay', '70000104', 'advance.eachstay@fixture.test',
    '2027-06-10', '2027-06-12', 1, 'phone', null, null, true
  );
  select booking_id into v_booking from public.reservations where id = v_reservation;

  create temp table fixture_each_stay as select v_booking as booking_id;
end $$;

-- fixture_closed: booking 'client' ya cerrado (group_closed insertado a
-- mano -- el trigger automático es feat/booking-15, todavía no existe).
do $$
declare
  v_room uuid; v_room_type uuid; v_reservation uuid; v_booking uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_room_type
  from public.room_type_options o
  join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 350
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_reservation := public.create_reservation(
    v_room, v_room_type, 'Cliente', 'Closed', '70000105', 'advance.closed@fixture.test',
    '2027-06-13', '2027-06-15', 1, 'phone', null, null, true,
    'client', 'room', null, (select account_id from fixture_account),
    null, null, null, null, false, null
  );
  select booking_id into v_booking from public.reservations where id = v_reservation;

  insert into public.booking_balances (booking_id, event_type, amount_bs, notes)
  values (v_booking, 'group_closed', 0, 'Fixture: cierre manual (Slice 5 aún no existe)');

  create temp table fixture_closed as select v_booking as booking_id;
end $$;

-- fixture_no_contract: booking 'client' insertado A MANO (sin pasar por
-- create_reservation), sin ninguna fila en booking_balances -- simula
-- la invariante rota "client sin contrato" que el guard debe atrapar.
do $$
declare
  v_person uuid; v_booking uuid;
begin
  insert into public.people (first_name, last_name)
  values ('Sin', 'Contrato') returning id into v_person;

  insert into public.bookings (contact_person_id, payer_mode, receivable_account_id)
  values (v_person, 'client', (select account_id from fixture_account))
  returning id into v_booking;

  create temp table fixture_no_contract as select v_booking as booking_id;
end $$;

-- ---------------------------------------------------------------------
-- Rol para el resto del archivo: reception (rol principal de cobro).
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

-- ---------------------------------------------------------------------
-- (a) Caja abierta (estado del seed) + booking client + EFECTIVO 500 ->
--     una fila advance_received, cash_movement creado, net_owed_bs baja.
-- ---------------------------------------------------------------------
select is(
  public._net_owed_bs((select booking_id from fixture_client)),
  700::numeric,
  '(a) antes del adelanto: net_owed_bs = 700 (solo el contrato)'
);

create temp table snap_a_mov as select id as mov_id from public.record_booking_advance(
  (select booking_id from fixture_client), 500, 'EFECTIVO', null, null, null, null, null, 'Adelanto de prueba'
) as id;

select is(
  (select count(*)::int from public.booking_balances
    where booking_id = (select booking_id from fixture_client) and event_type = 'advance_received'),
  1,
  '(a) se insertó exactamente una fila advance_received'
);
select is(
  (select amount_bs from public.booking_balances
    where booking_id = (select booking_id from fixture_client) and event_type = 'advance_received'),
  500.00,
  '(a) el monto registrado es 500'
);
select ok(
  (select count(*)::int from public.cash_movements
    where id = (select mov_id from snap_a_mov) and payment_method = 'EFECTIVO' and amount_bs = 500) = 1,
  '(a) se creó el movimiento de caja EFECTIVO por 500, y es el id devuelto por el RPC'
);
select is(
  public._net_owed_bs((select booking_id from fixture_client)),
  200::numeric,
  '(a) net_owed_bs baja a 200 (700 - 500)'
);

-- ---------------------------------------------------------------------
-- (b) MIXTO 300 efectivo + 200 DEPOSITO -> una fila de 500 en el
--     ledger, vinculada al movimiento de la pata EFECTIVO.
-- ---------------------------------------------------------------------
create temp table snap_b_mov as select id as mov_id from public.record_booking_advance(
  (select booking_id from fixture_client2), 500, 'MIXTO', null, 'DEP-001', 300, 200, 'DEPOSITO', null
) as id;

select is(
  (select count(*)::int from public.booking_balances
    where booking_id = (select booking_id from fixture_client2) and event_type = 'advance_received'),
  1,
  '(b) MIXTO: una sola fila advance_received (no dos, una por pata)'
);
select is(
  (select amount_bs from public.booking_balances
    where booking_id = (select booking_id from fixture_client2) and event_type = 'advance_received'),
  500.00,
  '(b) MIXTO: el monto total registrado es 500'
);
select ok(
  (select count(*)::int from public.cash_movements
    where id = (select mov_id from snap_b_mov) and payment_method = 'EFECTIVO' and amount_bs = 300) = 1,
  '(b) MIXTO: el id devuelto es el movimiento de la pata EFECTIVO (300), no el de DEPOSITO'
);
select ok(
  exists (select 1 from public.cash_movements
    where payment_method = 'DEPOSITO' and amount_bs = 200
      and payment_reference = 'DEP-001'
      and concept ilike '%mixto: deposito%'),
  '(b) MIXTO: también existe el movimiento de la pata DEPOSITO (200, con referencia)'
);

-- ---------------------------------------------------------------------
-- (c) Comprobante: QR sin foto y TARJETA sin referencia se rechazan
--     igual que record_anticipo; DEPOSITO sin nada SÍ funciona
--     (corrección documentada arriba del archivo).
-- ---------------------------------------------------------------------
create temp table snap_c_bb as select count(*)::int as n from public.booking_balances;
create temp table snap_c_cm as select count(*)::int as n from public.cash_movements;

select throws_ok(
  format(
    $$ select public.record_booking_advance(%L, 100, 'QR', null, null, null, null, null, null) $$,
    (select booking_id from fixture_client3)
  ),
  'P0001', 'La foto del comprobante es obligatoria para pagos por QR',
  '(c1) QR sin foto de comprobante se rechaza (igual que record_anticipo)'
);
select is((select count(*)::int from public.booking_balances), (select n from snap_c_bb),
  '(c1) ... y no queda ninguna fila nueva en booking_balances');
select is((select count(*)::int from public.cash_movements), (select n from snap_c_cm),
  '(c1) ... ni ningún movimiento de caja nuevo');

select throws_ok(
  format(
    $$ select public.record_booking_advance(%L, 100, 'TARJETA', null, null, null, null, null, null) $$,
    (select booking_id from fixture_client3)
  ),
  'P0001', 'El código de referencia es obligatorio para pagos con tarjeta',
  '(c2) TARJETA sin referencia se rechaza (igual que record_anticipo)'
);
select is((select count(*)::int from public.booking_balances), (select n from snap_c_bb),
  '(c2) ... y no queda ninguna fila nueva en booking_balances');
select is((select count(*)::int from public.cash_movements), (select n from snap_c_cm),
  '(c2) ... ni ningún movimiento de caja nuevo');

select lives_ok(
  format(
    $$ select public.record_booking_advance(%L, 100, 'DEPOSITO', null, null, null, null, null, null) $$,
    (select booking_id from fixture_client3)
  ),
  '(c3) DEPOSITO sin foto ni referencia SÍ funciona -- assert_payment_proof vivo no lo exige '
  || '(corrección a la asunción inicial de la tarea, documentada arriba)'
);
select is(
  (select count(*)::int from public.booking_balances
    where booking_id = (select booking_id from fixture_client3) and event_type = 'advance_received'),
  1,
  '(c3) ... y sí quedó registrado el adelanto'
);

-- ---------------------------------------------------------------------
-- (d) CTAS_POR_COBRAR se rechaza: un adelanto es plata ya recibida.
-- ---------------------------------------------------------------------
select throws_ok(
  format(
    $$ select public.record_booking_advance(%L, 100, 'CTAS_POR_COBRAR', null, null, null, null, null, null) $$,
    (select booking_id from fixture_client3)
  ),
  'P0001', 'Un adelanto es plata ya recibida; no puede quedar como cuenta por cobrar',
  '(d) CTAS_POR_COBRAR se rechaza'
);
select is((select count(*)::int from public.booking_balances), (select n from snap_c_bb) + 1,
  '(d) ... sin efecto (solo se sumó la fila válida de c3 desde el snapshot)');

-- ---------------------------------------------------------------------
-- (e) Monto 0 / negativo / NULL se rechazan.
-- ---------------------------------------------------------------------
select throws_ok(
  format(
    $$ select public.record_booking_advance(%L, 0, 'EFECTIVO', null, null, null, null, null, null) $$,
    (select booking_id from fixture_client3)
  ),
  'P0001', 'El monto debe ser positivo', '(e1) monto 0 se rechaza'
);
select throws_ok(
  format(
    $$ select public.record_booking_advance(%L, -50, 'EFECTIVO', null, null, null, null, null, null) $$,
    (select booking_id from fixture_client3)
  ),
  'P0001', 'El monto debe ser positivo', '(e2) monto negativo se rechaza'
);
select throws_ok(
  format(
    $$ select public.record_booking_advance(%L, null, 'EFECTIVO', null, null, null, null, null, null) $$,
    (select booking_id from fixture_client3)
  ),
  'P0001', 'El monto debe ser positivo', '(e3) monto NULL se rechaza (trampa NULL de postgres/check-constraint-null-trap)'
);

-- ---------------------------------------------------------------------
-- (f) each_stay / cerrado / inexistente / sin contrato se rechazan.
-- ---------------------------------------------------------------------
select throws_ok(
  format(
    $$ select public.record_booking_advance(%L, 100, 'EFECTIVO', null, null, null, null, null, null) $$,
    (select booking_id from fixture_each_stay)
  ),
  'P0001', 'Solo las reservas institucionales reciben adelantos de grupo',
  '(f1) booking each_stay se rechaza'
);
select throws_ok(
  format(
    $$ select public.record_booking_advance(%L, 100, 'EFECTIVO', null, null, null, null, null, null) $$,
    (select booking_id from fixture_closed)
  ),
  'P0001', 'Esta reserva de grupo ya está cerrada',
  '(f2) booking ya cerrado (group_closed) se rechaza'
);
select throws_ok(
  $$ select public.record_booking_advance('00000000-0000-0000-0000-000000000000', 100, 'EFECTIVO', null, null, null, null, null, null) $$,
  'P0001', 'Reserva de grupo no encontrada',
  '(f3) booking inexistente se rechaza'
);
select throws_ok(
  format(
    $$ select public.record_booking_advance(%L, 100, 'EFECTIVO', null, null, null, null, null, null) $$,
    (select booking_id from fixture_no_contract)
  ),
  'P0001', 'La reserva de grupo todavía no tiene un contrato registrado',
  '(f4) booking client sin contract_agreed se rechaza (invariante rota, defensa en profundidad)'
);
select is(
  (select count(*)::int from public.cash_movements), (select n from snap_c_cm) + 1,
  '(f) ninguno de los 4 negativos anteriores generó movimiento de caja (solo c3 lo hizo)'
);

-- ---------------------------------------------------------------------
-- (g) Roles no autorizados se rechazan: pending y accountant (igual que
--     record_anticipo, que solo permite root/reception/reception_admin).
--     El fixture pending se inserta vía auth.users (no directo en
--     profiles: profiles.id es FK a auth.users) para que
--     handle_new_user() le asigne el rol 'pending' de verdad, mismo
--     patrón que 22_guard_public_security_definer_rpcs.sql.
-- ---------------------------------------------------------------------
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  created_at, updated_at, raw_app_meta_data, raw_user_meta_data,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
) values (
  '88888888-8888-8888-8888-888888888888', '00000000-0000-0000-0000-000000000000',
  'authenticated', 'authenticated', 'advance.pending@fixture.test',
  crypt('local1234', gen_salt('bf')), now(), now(), now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', 'Adelanto Pendiente'),
  '', '', '', '', '', '', '', ''
);

select is(
  (select role from public.profiles where id = '88888888-8888-8888-8888-888888888888'),
  'pending',
  '(g0) fixture: la cuenta recién creada queda en pending (handle_new_user)'
);

select set_config('request.jwt.claims',
  '{"sub":"88888888-8888-8888-8888-888888888888","role":"authenticated"}', true); -- pending

select throws_ok(
  format(
    $$ select public.record_booking_advance(%L, 100, 'EFECTIVO', null, null, null, null, null, null) $$,
    (select booking_id from fixture_client3)
  ),
  'P0001', 'No autorizado para registrar adelantos',
  '(g1) rol no reconocido (anonymous) se rechaza'
);

select set_config('request.jwt.claims',
  '{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated"}', true); -- accountant

select throws_ok(
  format(
    $$ select public.record_booking_advance(%L, 100, 'EFECTIVO', null, null, null, null, null, null) $$,
    (select booking_id from fixture_client3)
  ),
  'P0001', 'No autorizado para registrar adelantos',
  '(g2) accountant se rechaza (mismo conjunto de roles que record_anticipo, no lo incluye)'
);
select is(
  (select count(*)::int from public.booking_balances
    where booking_id = (select booking_id from fixture_client3) and event_type = 'advance_received'),
  1,
  '(g) los intentos no autorizados no agregaron ningún advance_received nuevo (sigue siendo 1, de c3)'
);

-- ---------------------------------------------------------------------
-- (h) Sobrepago: permitido por diseño, net_owed_bs puede quedar
--     negativo. Documentado, no bloqueado (ver cabecera del archivo).
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

select lives_ok(
  format(
    $$ select public.record_booking_advance(%L, 500, 'EFECTIVO', null, null, null, null, null, 'Sobrepago intencional') $$,
    (select booking_id from fixture_client)
  ),
  '(h) un adelanto mayor al saldo pendiente (200) SÍ se acepta -- sin bloqueo'
);
select is(
  public._net_owed_bs((select booking_id from fixture_client)),
  -300::numeric,
  '(h) net_owed_bs queda negativo (200 - 500 = -300), registrado para auditoría'
);

-- ---------------------------------------------------------------------
-- (i) Sin caja abierta: se rechaza, nada queda insertado. Va al final
--     porque cierra la única caja abierta del seed.
-- ---------------------------------------------------------------------
create temp table snap_i_bb as select count(*)::int as n from public.booking_balances;
create temp table snap_i_cm as select count(*)::int as n from public.cash_movements;

update public.cash_sessions set status = 'closed', closed_at = now(), counted_balance_bs = 500
where status = 'open';

select throws_ok(
  format(
    $$ select public.record_booking_advance(%L, 100, 'EFECTIVO', null, null, null, null, null, null) $$,
    (select booking_id from fixture_client3)
  ),
  'P0001', 'No hay una caja abierta',
  '(i) sin caja abierta, EFECTIVO se rechaza con el mismo mensaje de siempre'
);
select is((select count(*)::int from public.booking_balances), (select n from snap_i_bb),
  '(i) ... sin dejar ninguna fila nueva en booking_balances');
select is((select count(*)::int from public.cash_movements), (select n from snap_i_cm),
  '(i) ... ni ningún movimiento de caja nuevo');

select * from finish();
rollback;
