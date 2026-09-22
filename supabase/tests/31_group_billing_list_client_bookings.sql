-- =====================================================================
-- Vista de reservas institucionales: list_client_bookings_brief() (change:
-- group-billing, stage 6, Slice 11, branch feat/booking-24-ui-group-
-- bookings-view). Muestra las reservas payer_mode='client' abiertas
-- (todavía no group_closed) con su saldo pendiente (via _net_owed_bs,
-- NUNCA el wrapper público net_owed_bs -- esta función ya hace su propia
-- autorización) y las habitaciones confirmadas con fecha vencida
-- (check-in/check-out en el pasado, sin haberse presentado).
--
-- Guard de rol: root/reception/reception_admin/accountant, SIN owner --
-- owner no tiene acceso de lectura a booking_balances/receivables bajo
-- ninguna política de esta etapa (ver T24.0, sdd/group-billing/design-
-- part-4 patch 2026-09-13), así que incluirlo acá sería el mismo bug
-- encontrado en Slice 1 (sdd/group-billing/review-booking-8, #352).
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

-- ---------------------------------------------------------------------
-- Fixture: cuenta por cobrar compartida.
-- ---------------------------------------------------------------------
do $$
declare
  v_account uuid;
begin
  insert into public.receivable_accounts (name, kind)
  values ('Fixture List Client Bookings', 'empresa')
  returning id into v_account;

  create temp table fixture_account as select v_account as account_id;
end $$;

select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true); -- reception_admin

-- ---------------------------------------------------------------------
-- (a) Booking client abierto, con adelanto -> aparece en la lista con
--     el net_owed_bs correcto, sin habitaciones vencidas.
-- ---------------------------------------------------------------------
do $$
declare
  v_room uuid; v_type uuid; v_res uuid; v_booking uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 350
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_res := public.create_reservation(
    v_room, v_type, 'Instituto', 'Abierto A', '70300001', 'list.a@fixture.test',
    '2027-08-01', '2027-08-03', 1, 'phone', null, null, true,
    'client', 'room', null, (select account_id from fixture_account),
    null, null, null, null, false, null
  );
  select booking_id into v_booking from public.reservations where id = v_res;

  create temp table fixture_a as select v_res as res1, v_booking as booking_id;
end $$;

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

select public.record_booking_advance(
  (select booking_id from fixture_a), 200, 'EFECTIVO', null, null, null, null, null, 'Adelanto grupo A'
);
-- contrato: 350 x 2 noches = 700 - 200 = 500.

select is(
  (select net_owed_bs from public.list_client_bookings_brief()
    where booking_id = (select booking_id from fixture_a)),
  500::numeric,
  '(a1) el booking abierto aparece en la lista con net_owed_bs = 500 (700 - 200)'
);
select is(
  (select overdue_rooms from public.list_client_bookings_brief()
    where booking_id = (select booking_id from fixture_a)),
  '{}'::text[],
  '(a2) sin habitaciones vencidas: overdue_rooms vacío'
);

-- ---------------------------------------------------------------------
-- (b) Booking client YA group_closed (pagado en su totalidad, check-out
--     completo) -> excluido de la lista.
-- ---------------------------------------------------------------------
do $$
declare
  v_room uuid; v_type uuid; v_res uuid; v_booking uuid;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true); -- reception_admin

  select o.room_id, o.room_type_id into v_room, v_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 350
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_res := public.create_reservation(
    v_room, v_type, 'Instituto', 'Cerrado B', '70300002', 'list.b@fixture.test',
    '2027-08-05', '2027-08-07', 1, 'phone', null, null, true,
    'client', 'room', null, (select account_id from fixture_account),
    null, null, null, null, false, null
  );
  select booking_id into v_booking from public.reservations where id = v_res;

  create temp table fixture_b as select v_res as res1, v_booking as booking_id;
end $$;

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

-- contrato: 350 x 2 = 700; adelanto exacto -> cierra en saldo 0 al checkout.
select public.record_booking_advance(
  (select booking_id from fixture_b), 700, 'EFECTIVO', null, null, null, null, null, 'Adelanto exacto B'
);
select public.check_in_reservation((select res1 from fixture_b), '11300002', '1990-01-01', 'BO', 'La Paz', false);
select public.check_out_room((select room_id from public.reservations where id = (select res1 from fixture_b)));

select is(
  (select count(*)::int from public.list_client_bookings_brief()
    where booking_id = (select booking_id from fixture_b)),
  0,
  '(b) un booking ya group_closed no aparece en la lista'
);

-- ---------------------------------------------------------------------
-- (c) Booking client abierto con una habitación confirmed cuya
--     check_in_date ya pasó (no se presentó) -> aparece en overdue_rooms.
-- ---------------------------------------------------------------------
do $$
declare
  v_room uuid; v_type uuid; v_res uuid; v_booking uuid; v_room_number text;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true); -- reception_admin

  select o.room_id, o.room_type_id into v_room, v_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 350
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  select room_number into v_room_number from public.rooms where id = v_room;

  v_res := public.create_reservation(
    v_room, v_type, 'Instituto', 'Vencido C', '70300003', 'list.c@fixture.test',
    '2027-08-09', '2027-08-11', 1, 'phone', null, null, true,
    'client', 'room', null, (select account_id from fixture_account),
    null, null, null, null, false, null
  );
  select booking_id into v_booking from public.reservations where id = v_res;

  -- El check-in date se manda al pasado directo en la fila (postgres, sin
  -- RLS) para simular una habitación vencida sin depender de la fecha del
  -- sistema -- ninguna RPC del stage permite crear con check_in_date en
  -- el pasado, así que este ajuste post-creación es la única forma de
  -- fijar el escenario de manera determinística.
  reset role;
  update public.reservations set check_in_date = current_date - 5, check_out_date = current_date - 3
    where id = v_res;

  create temp table fixture_c as select v_res as res1, v_booking as booking_id, v_room_number as room_number;
end $$;

select is(
  (select overdue_rooms from public.list_client_bookings_brief()
    where booking_id = (select booking_id from fixture_c)),
  array[(select room_number from fixture_c)],
  '(c) la habitación confirmed con check_in_date vencido aparece en overdue_rooms'
);

-- ---------------------------------------------------------------------
-- (d) El fixture (a) sigue sin vencidas (regresión, no se contamina con
--     el ajuste de fecha de (c)).
-- ---------------------------------------------------------------------
select is(
  (select overdue_rooms from public.list_client_bookings_brief()
    where booking_id = (select booking_id from fixture_a)),
  '{}'::text[],
  '(d) el fixture (a), sin fechas vencidas, sigue sin overdue_rooms tras (c)'
);

-- ---------------------------------------------------------------------
-- (e) Seguridad: como role 'owner', list_client_bookings_brief() rechaza
--     con "No autorizado" (owner no tiene acceso a booking_balances/
--     receivables bajo ninguna política de esta etapa).
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"55555555-5555-5555-5555-555555555555","role":"authenticated"}', true); -- owner
set local role authenticated;
select is(current_user_role(), 'owner', 'fixture: sesión autenticada con rol owner');
select throws_matching(
  $$ select * from public.list_client_bookings_brief() $$,
  'No autorizado',
  '(e) owner no puede leer list_client_bookings_brief (mismo guard que net_owed_bs/booking_balances_read)'
);
reset role;

-- ---------------------------------------------------------------------
-- (f) reception SÍ puede llamarla (está en el guard).
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception
select lives_ok(
  $$ select * from public.list_client_bookings_brief() $$,
  '(f) reception sí puede ejecutar list_client_bookings_brief'
);

-- ---------------------------------------------------------------------
-- (g) Grants: revocada de public/anon, otorgada a authenticated.
-- ---------------------------------------------------------------------
select ok(
  not has_function_privilege('anon', 'public.list_client_bookings_brief()', 'execute'),
  '(g) anon no puede ejecutar list_client_bookings_brief'
);

select * from finish();
rollback;
