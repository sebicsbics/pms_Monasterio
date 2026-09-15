-- =====================================================================
-- Cierre automático del grupo institucional: trigger
-- reservations_close_booking_group / _close_booking_group() (change:
-- group-billing, stage 6, Slice 5, branch feat/booking-15-close-trigger).
--
-- Todos los escenarios usan los caminos REALES (check_in_reservation,
-- check_out_room, cancel_reservation) como reception, con la caja del
-- seed abierta -- no se llama a _close_booking_group() directo (es una
-- función de trigger, RETURNS trigger: postgres no permite invocarla
-- por SELECT, "trigger functions can only be called as triggers"). El
-- checkout de una habitación 'client' todavía cobra el total de la
-- habitación completo (no solo extras) porque ese fix es
-- feat/booking-17 (Slice 6), que no existe en esta rama -- no se afirma
-- ningún monto de checkout acá, solo el efecto sobre booking_balances/
-- receivables.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(31);

-- ---------------------------------------------------------------------
-- Fixture: cuenta por cobrar compartida.
-- ---------------------------------------------------------------------
do $$
declare
  v_account uuid;
begin
  insert into public.receivable_accounts (name, kind)
  values ('Fixture Close Trigger', 'empresa')
  returning id into v_account;

  create temp table fixture_account as select v_account as account_id;
end $$;

select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true); -- reception_admin

-- ---------------------------------------------------------------------
-- (a) 3 habitaciones, contrato 2100 (3 x 700), adelanto 900. Cierra
--     recién al hacer check-out de la 3ra habitación, con saldo neto
--     1200 = 2100 - 900.
-- ---------------------------------------------------------------------
do $$
declare
  v_room1 uuid; v_type1 uuid; v_room2 uuid; v_type2 uuid; v_room3 uuid; v_type3 uuid;
  v_result jsonb; v_res1 uuid; v_res2 uuid; v_res3 uuid; v_booking uuid;
begin
  select o.room_id, o.room_type_id into v_room1, v_type1
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 350
    and o.room_id not in (select room_id from public.reservations)
  limit 1;
  select o.room_id, o.room_type_id into v_room2, v_type2
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 350
    and o.room_id not in (select room_id from public.reservations) and o.room_id <> v_room1
  limit 1;
  select o.room_id, o.room_type_id into v_room3, v_type3
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 350
    and o.room_id not in (select room_id from public.reservations) and o.room_id not in (v_room1, v_room2)
  limit 1;

  v_result := public.create_bulk_reservation(
    jsonb_build_array(
      jsonb_build_object('room_id', v_room1, 'room_type_id', v_type1, 'num_guests', 1),
      jsonb_build_object('room_id', v_room2, 'room_type_id', v_type2, 'num_guests', 1),
      jsonb_build_object('room_id', v_room3, 'room_type_id', v_type3, 'num_guests', 1)
    ),
    'Grupo', 'Cierre A', '70200001', 'close.a@fixture.test',
    '2027-07-01', '2027-07-03', 'phone', null, null,
    'client', 'room', null, (select account_id from fixture_account)
  );
  v_res1 := ((v_result->'created')->>0)::uuid;
  v_res2 := ((v_result->'created')->>1)::uuid;
  v_res3 := ((v_result->'created')->>2)::uuid;
  select booking_id into v_booking from public.reservations where id = v_res1;

  create temp table fixture_a as
    select v_res1 as res1, v_res2 as res2, v_res3 as res3, v_booking as booking_id;
end $$;

select is(
  public._net_owed_bs((select booking_id from fixture_a)), 2100::numeric,
  '(a0) contrato inicial: 3 x 700 = 2100'
);

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

select public.record_booking_advance(
  (select booking_id from fixture_a), 900, 'EFECTIVO', null, null, null, null, null, 'Adelanto grupo A'
);
select is(
  public._net_owed_bs((select booking_id from fixture_a)), 1200::numeric,
  '(a1) tras el adelanto de 900: saldo 1200'
);

select public.check_in_reservation((select res1 from fixture_a), '11100001', '1990-01-01', 'BO', 'La Paz', false);
select public.check_in_reservation((select res2 from fixture_a), '11100002', '1990-01-01', 'BO', 'La Paz', false);
select public.check_in_reservation((select res3 from fixture_a), '11100003', '1990-01-01', 'BO', 'La Paz', false);

select public.check_out_room((select room_id from public.reservations where id = (select res1 from fixture_a)));
select is(
  (select count(*)::int from public.booking_balances
    where booking_id = (select booking_id from fixture_a) and event_type = 'group_closed'),
  0, '(a2) tras check-out de la 1ra habitación: todavía no cierra (quedan 2 activas)'
);

select public.check_out_room((select room_id from public.reservations where id = (select res2 from fixture_a)));
select is(
  (select count(*)::int from public.booking_balances
    where booking_id = (select booking_id from fixture_a) and event_type = 'group_closed'),
  0, '(a3) tras check-out de la 2da habitación: todavía no cierra (queda 1 activa)'
);
select is(
  (select count(*)::int from public.receivables where booking_id = (select booking_id from fixture_a)),
  0, '(a3) ... y tampoco hay cuenta por cobrar todavía'
);

select public.check_out_room((select room_id from public.reservations where id = (select res3 from fixture_a)));
select is(
  (select count(*)::int from public.booking_balances
    where booking_id = (select booking_id from fixture_a) and event_type = 'group_closed'),
  1, '(a4) tras check-out de la 3ra (última) habitación: cierra, exactamente 1 group_closed'
);
select is(
  (select amount_bs from public.booking_balances
    where booking_id = (select booking_id from fixture_a) and event_type = 'group_closed'),
  1200.00, '(a4) ... con el saldo neto correcto (2100 - 900 = 1200)'
);
select is(
  (select count(*)::int from public.receivables where booking_id = (select booking_id from fixture_a)),
  1, '(a4) ... y exactamente 1 cuenta por cobrar'
);
select is(
  (select row(amount_bs, reservation_id, account_id, status)
     from public.receivables where booking_id = (select booking_id from fixture_a)),
  (select row(1200.00, null::uuid, (select account_id from fixture_account), 'pending'::text)),
  '(a4) ... por 1200, reservation_id NULL, cuenta del booking, estado pending'
);

-- ---------------------------------------------------------------------
-- (b) última habitación activa CANCELADA (la otra ya hizo check-out) ->
--     igual cierra, con cuenta por cobrar por el saldo.
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
  where rt.max_occupancy = 1 and rt.base_price_bs = 350
    and o.room_id not in (select room_id from public.reservations) and o.room_id <> v_room1
  limit 1;

  perform set_config('request.jwt.claims',
    '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true); -- reception_admin

  v_result := public.create_bulk_reservation(
    jsonb_build_array(
      jsonb_build_object('room_id', v_room1, 'room_type_id', v_type1, 'num_guests', 1),
      jsonb_build_object('room_id', v_room2, 'room_type_id', v_type2, 'num_guests', 1)
    ),
    'Grupo', 'Cierre B', '70200002', 'close.b@fixture.test',
    '2027-07-04', '2027-07-06', 'phone', null, null,
    'client', 'room', null, (select account_id from fixture_account)
  );
  v_res1 := ((v_result->'created')->>0)::uuid;
  v_res2 := ((v_result->'created')->>1)::uuid;
  select booking_id into v_booking from public.reservations where id = v_res1;

  create temp table fixture_b as select v_res1 as res1, v_res2 as res2, v_booking as booking_id;
end $$;

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

select public.check_in_reservation((select res1 from fixture_b), '11100004', '1990-01-01', 'BO', 'La Paz', false);
select public.check_out_room((select room_id from public.reservations where id = (select res1 from fixture_b)));
select is(
  (select count(*)::int from public.booking_balances
    where booking_id = (select booking_id from fixture_b) and event_type = 'group_closed'),
  0, '(b1) tras check-out de la 1ra habitación: no cierra (la 2da sigue confirmed)'
);

select public.cancel_reservation((select res2 from fixture_b), 'No-show, cancelación manual');
select is(
  (select count(*)::int from public.booking_balances
    where booking_id = (select booking_id from fixture_b) and event_type = 'group_closed'),
  1, '(b2) al cancelar la ÚLTIMA habitación activa: cierra igual (la transición fue cancel, no checkout)'
);
select is(
  (select amount_bs from public.booking_balances
    where booking_id = (select booking_id from fixture_b) and event_type = 'group_closed'),
  1400.00, '(b2) saldo neto = 1400 (2 x 700, sin adelantos)'
);
select is(
  (select count(*)::int from public.receivables where booking_id = (select booking_id from fixture_b)),
  1, '(b2) ... y se generó la cuenta por cobrar'
);

-- ---------------------------------------------------------------------
-- (c) TODAS las habitaciones canceladas -> cierra en la última
--     cancelación; la deuda es el contrato completo menos adelantos
--     (las canceladas siguen debiendo, spec R5.2).
-- ---------------------------------------------------------------------
do $$
declare
  v_room1 uuid; v_type1 uuid; v_room2 uuid; v_type2 uuid;
  v_result jsonb; v_res1 uuid; v_res2 uuid; v_booking uuid;
begin
  -- Pool distinto (480) -- el pool de 350 ya quedó exactamente agotado
  -- entre (a) (3 habitaciones) y (b) (2 habitaciones): 9 en total, 4 ya
  -- usadas por el seed, 5 libres, las 5 consumidas por (a)+(b).
  select o.room_id, o.room_type_id into v_room1, v_type1
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 2 and rt.base_price_bs = 480
    and o.room_id not in (select room_id from public.reservations)
  limit 1;
  select o.room_id, o.room_type_id into v_room2, v_type2
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 2 and rt.base_price_bs = 480
    and o.room_id not in (select room_id from public.reservations) and o.room_id <> v_room1
  limit 1;

  perform set_config('request.jwt.claims',
    '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true); -- reception_admin

  v_result := public.create_bulk_reservation(
    jsonb_build_array(
      jsonb_build_object('room_id', v_room1, 'room_type_id', v_type1, 'num_guests', 1),
      jsonb_build_object('room_id', v_room2, 'room_type_id', v_type2, 'num_guests', 1)
    ),
    'Grupo', 'Cierre C', '70200003', 'close.c@fixture.test',
    '2027-07-07', '2027-07-09', 'phone', null, null,
    'client', 'room', null, (select account_id from fixture_account)
  );
  v_res1 := ((v_result->'created')->>0)::uuid;
  v_res2 := ((v_result->'created')->>1)::uuid;
  select booking_id into v_booking from public.reservations where id = v_res1;

  create temp table fixture_c as select v_res1 as res1, v_res2 as res2, v_booking as booking_id;
end $$;

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

select public.record_booking_advance(
  (select booking_id from fixture_c), 200, 'EFECTIVO', null, null, null, null, null, 'Adelanto grupo C'
);

select public.cancel_reservation((select res1 from fixture_c), 'No-show habitación 1');
select is(
  (select count(*)::int from public.booking_balances
    where booking_id = (select booking_id from fixture_c) and event_type = 'group_closed'),
  0, '(c1) cancelada la 1ra de 2: no cierra todavía (queda 1 confirmed)'
);

select public.cancel_reservation((select res2 from fixture_c), 'No-show habitación 2');
select is(
  (select count(*)::int from public.booking_balances
    where booking_id = (select booking_id from fixture_c) and event_type = 'group_closed'),
  1, '(c2) canceladas TODAS: cierra en la última cancelación'
);
select is(
  (select amount_bs from public.booking_balances
    where booking_id = (select booking_id from fixture_c) and event_type = 'group_closed'),
  1720.00, '(c2) saldo = 1920 (2 x 480 x 2 noches) - 200 de adelanto = 1720 (canceladas siguen debiendo, R5.2)'
);
select is(
  (select count(*)::int from public.receivables where booking_id = (select booking_id from fixture_c)),
  1, '(c2) ... con su cuenta por cobrar'
);

-- ---------------------------------------------------------------------
-- (d) pagado en su totalidad (adelanto = contrato) -> group_closed con
--     amount_bs = 0, SIN cuenta por cobrar.
-- ---------------------------------------------------------------------
do $$
declare
  v_room uuid; v_type uuid; v_result jsonb; v_res uuid; v_booking uuid;
begin
  -- Pool distinto (max_occupancy=2, 480) para no agotar el pool de 350
  -- (solo 9 habitaciones en el seed, ya usadas 7 entre (a)/(b)/(c)).
  select o.room_id, o.room_type_id into v_room, v_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 2 and rt.base_price_bs = 480
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  perform set_config('request.jwt.claims',
    '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true); -- reception_admin

  v_res := public.create_reservation(
    v_room, v_type, 'Grupo', 'Cierre D', '70200004', 'close.d@fixture.test',
    '2027-07-10', '2027-07-12', 1, 'phone', null, null, true,
    'client', 'room', null, (select account_id from fixture_account),
    null, null, null, null, false, null
  );
  select booking_id into v_booking from public.reservations where id = v_res;

  create temp table fixture_d as select v_res as res1, v_booking as booking_id;
end $$;

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

-- Contrato: 480 x 2 noches = 960. Adelanto exacto.
select public.record_booking_advance(
  (select booking_id from fixture_d), 960, 'EFECTIVO', null, null, null, null, null, 'Adelanto exacto D'
);

select public.check_in_reservation((select res1 from fixture_d), '11100005', '1990-01-01', 'BO', 'La Paz', false);
select public.check_out_room((select room_id from public.reservations where id = (select res1 from fixture_d)));

select is(
  (select count(*)::int from public.booking_balances
    where booking_id = (select booking_id from fixture_d) and event_type = 'group_closed'),
  1, '(d1) cierra igual con saldo 0: exactamente 1 group_closed'
);
select is(
  (select amount_bs from public.booking_balances
    where booking_id = (select booking_id from fixture_d) and event_type = 'group_closed'),
  0.00, '(d1) ... con amount_bs = 0 (auditoría, spec R5.3)'
);
select is(
  (select count(*)::int from public.receivables where booking_id = (select booking_id from fixture_d)),
  0, '(d1) ... y SIN cuenta por cobrar (nada pendiente)'
);

-- ---------------------------------------------------------------------
-- (e) Idempotencia: reabrir y volver a cerrar (como postgres, directo
--     sobre la fila) no duplica el evento ni la cuenta. Un segundo
--     insert manual en receivables con el mismo booking_id viola el
--     unique index de Slice 1.
-- ---------------------------------------------------------------------
reset role;
update public.reservations set status = 'confirmed' where id = (select res1 from fixture_d);
update public.reservations set status = 'checked_out' where id = (select res1 from fixture_d);

select is(
  (select count(*)::int from public.booking_balances
    where booking_id = (select booking_id from fixture_d) and event_type = 'group_closed'),
  1, '(e1) re-disparar el trigger sobre un booking ya cerrado: sigue habiendo exactamente 1 group_closed'
);
select is(
  (select count(*)::int from public.receivables where booking_id = (select booking_id from fixture_d)),
  0, '(e1) ... y sigue sin cuenta por cobrar (idempotencia, no se re-evalúa el saldo)'
);

select throws_matching(
  format(
    $$ insert into public.receivables (account_id, booking_id, amount_bs, concept)
       values (%L, %L, 999, 'Segundo intento manual') $$,
    (select account_id from fixture_account),
    (select booking_id from fixture_a)
  ),
  'duplicate key value violates unique constraint "uniq_receivable_per_booking"',
  '(e2) un segundo receivables manual con el mismo booking_id (ya tiene uno, fixture a) '
  || 'viola el unique index de Slice 1'
);
select is(
  (select count(*)::int from public.receivables where booking_id = (select booking_id from fixture_a)),
  1, '(e2) ... sigue habiendo exactamente 1 receivable para ese booking'
);

-- ---------------------------------------------------------------------
-- (f) each_stay: check-out y cancelación NO generan ninguna fila de
--     booking_balances (payer_mode <> 'client', return temprano).
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

do $$
declare
  v_room uuid; v_type uuid; v_res uuid; v_booking uuid;
begin
  -- Pool distinto (480) para no agotar el pool de 350 (ya casi al límite
  -- entre (a)/(b)/(c)/(d)).
  select o.room_id, o.room_type_id into v_room, v_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 2 and rt.base_price_bs = 480
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_res := public.create_reservation(
    v_room, v_type, 'Cada', 'Habitación E', '70200005', 'close.eachstay1@fixture.test',
    '2027-07-13', '2027-07-15', 1, 'phone', null, null, true
  );
  select booking_id into v_booking from public.reservations where id = v_res;

  create temp table fixture_f1 as select v_res as res1, v_booking as booking_id;
end $$;

select public.check_in_reservation((select res1 from fixture_f1), '11100006', '1990-01-01', 'BO', 'La Paz', false);
select public.check_out_room((select room_id from public.reservations where id = (select res1 from fixture_f1)));
select is(
  (select count(*)::int from public.booking_balances where booking_id = (select booking_id from fixture_f1)),
  0, '(f1) each_stay: check-out no genera ninguna fila en booking_balances'
);

do $$
declare
  v_room uuid; v_type uuid; v_res uuid; v_booking uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 2 and rt.base_price_bs = 480
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_res := public.create_reservation(
    v_room, v_type, 'Cada', 'Habitación F', '70200006', 'close.eachstay2@fixture.test',
    '2027-07-16', '2027-07-18', 1, 'phone', null, null, true
  );
  select booking_id into v_booking from public.reservations where id = v_res;

  create temp table fixture_f2 as select v_res as res1, v_booking as booking_id;
end $$;

select public.cancel_reservation((select res1 from fixture_f2), 'No-show each_stay');
select is(
  (select count(*)::int from public.booking_balances where booking_id = (select booking_id from fixture_f2)),
  0, '(f2) each_stay: cancelación no genera ninguna fila en booking_balances'
);

-- ---------------------------------------------------------------------
-- (g) Regresión: un adelanto sobre un booking ya cerrado (por el
--     trigger real, no por fixture manual) sigue siendo rechazado.
-- ---------------------------------------------------------------------
select throws_ok(
  format(
    $$ select public.record_booking_advance(%L, 1, 'EFECTIVO', null, null, null, null, null, null) $$,
    (select booking_id from fixture_d)
  ),
  'P0001', 'Esta reserva de grupo ya está cerrada',
  '(g) adelanto sobre un booking cerrado por el trigger real se rechaza (regresión feat/booking-14)'
);

-- ---------------------------------------------------------------------
-- (h) check-in (confirmed -> checked_in) no dispara el cierre.
-- ---------------------------------------------------------------------
do $$
declare
  v_room uuid; v_type uuid; v_res uuid; v_booking uuid;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true); -- reception_admin

  select o.room_id, o.room_type_id into v_room, v_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 2 and rt.base_price_bs = 480
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_res := public.create_reservation(
    v_room, v_type, 'Grupo', 'Cierre H', '70200007', 'close.h@fixture.test',
    '2027-07-19', '2027-07-21', 1, 'phone', null, null, true,
    'client', 'room', null, (select account_id from fixture_account),
    null, null, null, null, false, null
  );
  select booking_id into v_booking from public.reservations where id = v_res;

  create temp table fixture_h as select v_res as res1, v_booking as booking_id;
end $$;

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

select public.check_in_reservation((select res1 from fixture_h), '11100007', '1990-01-01', 'BO', 'La Paz', false);
select is(
  (select count(*)::int from public.booking_balances
    where booking_id = (select booking_id from fixture_h) and event_type = 'group_closed'),
  0, '(h) check-in (confirmed -> checked_in) no dispara ningún cierre'
);

-- ---------------------------------------------------------------------
-- (i) Seguridad: _close_booking_group no es ejecutable por anon ni por
--     authenticated (es interna, solo dispara como trigger), y el
--     trigger está activo.
-- ---------------------------------------------------------------------
select ok(
  not has_function_privilege('anon', 'public._close_booking_group()', 'execute'),
  '(i1) anon no puede ejecutar _close_booking_group directo'
);
select ok(
  not has_function_privilege('authenticated', 'public._close_booking_group()', 'execute'),
  '(i2) authenticated tampoco puede ejecutar _close_booking_group directo'
);
select is(
  (select tgenabled from pg_trigger
    where tgrelid = 'public.reservations'::regclass and tgname = 'reservations_close_booking_group'),
  'O', '(i3) el trigger reservations_close_booking_group está activo (enabled)'
);

select * from finish();
rollback;
