-- =====================================================================
-- settle_receivable: reconocer cuentas por cobrar a nivel de booking
-- (change: group-billing, stage 6, Slice 5b, branch
-- feat/booking-16-settle-receivable-booking).
--
-- El tail histórico de settle_receivable solo actualizaba
-- reservations.payment_status vía reservation_id -- para una cuenta por
-- cobrar de GRUPO (reservation_id NULL, booking_id seteado, tal como la
-- produce _close_booking_group() desde feat/booking-15) era un no-op
-- silencioso. Esta migración agrega la rama booking_id, que marca TODAS
-- las reservas del booking como 'paid'.
--
-- Nota (actualizada en feat/booking-17-checkout-enforcement): desde esa
-- rama, el check-out individual de una habitación 'client' cobra SOLO
-- sus extras y YA NO marca payment_status='paid' (decisión #391). Acá
-- A1/A2 no tienen extras cargadas, así que su check-out normal las deja
-- 'pending' -- exactamente igual que A3 (cancelada, nunca facturada
-- individualmente). Las tres (A1, A2, A3) solo pasan a 'paid' cuando se
-- salda la cuenta por cobrar del grupo (settle_receivable, esta rama).
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
  values ('Fixture Settle Receivable', 'empresa')
  returning id into v_account;

  create temp table fixture_account as select v_account as account_id;
end $$;

-- ---------------------------------------------------------------------
-- (A) Booking de 3 habitaciones (client, pool 500/1 noche x2). A1 y A2
--     hacen check-out normal SIN extras (quedan 'pending', ya que el
--     check-out solo cobra extras); A3 se cancela (última transición
--     activa) y cierra el grupo.
-- ---------------------------------------------------------------------
do $$
declare
  v_room1 uuid; v_type1 uuid; v_room2 uuid; v_type2 uuid; v_room3 uuid; v_type3 uuid;
  v_result jsonb; v_res1 uuid; v_res2 uuid; v_res3 uuid; v_booking uuid;
begin
  select o.room_id, o.room_type_id into v_room1, v_type1
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 500
    and o.room_id not in (select room_id from public.reservations)
  limit 1;
  select o.room_id, o.room_type_id into v_room2, v_type2
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 500
    and o.room_id not in (select room_id from public.reservations) and o.room_id <> v_room1
  limit 1;
  select o.room_id, o.room_type_id into v_room3, v_type3
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 500
    and o.room_id not in (select room_id from public.reservations) and o.room_id not in (v_room1, v_room2)
  limit 1;

  perform set_config('request.jwt.claims',
    '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true); -- reception_admin

  v_result := public.create_bulk_reservation(
    jsonb_build_array(
      jsonb_build_object('room_id', v_room1, 'room_type_id', v_type1, 'num_guests', 1),
      jsonb_build_object('room_id', v_room2, 'room_type_id', v_type2, 'num_guests', 1),
      jsonb_build_object('room_id', v_room3, 'room_type_id', v_type3, 'num_guests', 1)
    ),
    'Grupo', 'Saldo A', '70300001', 'settle.a@fixture.test',
    '2027-08-01', '2027-08-03', 'phone', null, null,
    'client', 'room', null, (select account_id from fixture_account)
  );
  v_res1 := ((v_result->'created')->>0)::uuid;
  v_res2 := ((v_result->'created')->>1)::uuid;
  v_res3 := ((v_result->'created')->>2)::uuid;
  select booking_id into v_booking from public.reservations where id = v_res1;

  create temp table fixture_a as
    select v_res1 as res1, v_res2 as res2, v_res3 as res3, v_booking as booking_id;
end $$;

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

select public.check_in_reservation((select res1 from fixture_a), '11200001', '1990-01-01', 'BO', 'La Paz', false);
select public.check_out_room((select room_id from public.reservations where id = (select res1 from fixture_a)));

select public.check_in_reservation((select res2 from fixture_a), '11200002', '1990-01-01', 'BO', 'La Paz', false);
select public.check_out_room((select room_id from public.reservations where id = (select res2 from fixture_a)));

select public.cancel_reservation((select res3 from fixture_a), 'No-show habitación 3');

select is(
  (select count(*)::int from public.booking_balances
    where booking_id = (select booking_id from fixture_a) and event_type = 'group_closed'),
  1, '(a1) cierra en la última transición (cancelación de la 3ra habitación): exactamente 1 group_closed'
);
select is(
  (select amount_bs from public.booking_balances
    where booking_id = (select booking_id from fixture_a) and event_type = 'group_closed'),
  3000.00, '(a2) saldo neto correcto (3 x 500 x 2 noches, sin adelantos)'
);
select is(
  (select count(*)::int from public.receivables where booking_id = (select booking_id from fixture_a)),
  1, '(a3) exactamente 1 cuenta por cobrar de grupo'
);
select is(
  (select row(amount_bs, reservation_id, account_id, status)
     from public.receivables where booking_id = (select booking_id from fixture_a)),
  (select row(3000.00, null::uuid, (select account_id from fixture_account), 'pending'::text)),
  '(a4) por 3000, reservation_id NULL, cuenta del fixture, estado pending'
);

select is(
  (select payment_status from public.reservations where id = (select res1 from fixture_a)),
  'pending', '(a5, pre-settle) A1 sigue pending tras su propio check-out (solo cobra extras, feat/booking-17)'
);
select is(
  (select payment_status from public.reservations where id = (select res2 from fixture_a)),
  'pending', '(a6, pre-settle) A2 sigue pending tras su propio check-out (idem)'
);
select is(
  (select payment_status from public.reservations where id = (select res3 from fixture_a)),
  'pending', '(a7, pre-settle) A3 (cancelada, nunca facturada individualmente) sigue pending'
);

-- ---------------------------------------------------------------------
-- (B) Booking de 1 habitación (client, pool 450/1 noche x2), cancelada
--     antes del check-in -> cierra de inmediato. Se usa para probar que
--     saldar la cuenta de A NO toca las filas de B, y luego para las
--     pruebas de rol no autorizado y cancel_receivable.
-- ---------------------------------------------------------------------
do $$
declare
  v_room uuid; v_type uuid; v_res uuid; v_booking uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 450
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  perform set_config('request.jwt.claims',
    '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true); -- reception_admin

  v_res := public.create_reservation(
    v_room, v_type, 'Grupo', 'Saldo B', '70300002', 'settle.b@fixture.test',
    '2027-08-04', '2027-08-06', 1, 'phone', null, null, true,
    'client', 'room', null, (select account_id from fixture_account),
    null, null, null, null, false, null
  );
  select booking_id into v_booking from public.reservations where id = v_res;

  create temp table fixture_b as select v_res as res1, v_booking as booking_id;
end $$;

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

select public.cancel_reservation((select res1 from fixture_b), 'No-show habitación única');

select is(
  (select count(*)::int from public.booking_balances
    where booking_id = (select booking_id from fixture_b) and event_type = 'group_closed'),
  1, '(b1) única habitación cancelada: cierra de inmediato'
);
select is(
  (select count(*)::int from public.receivables where booking_id = (select booking_id from fixture_b)),
  1, '(b2) genera su propia cuenta por cobrar (900 = 450 x 2 noches)'
);
select is(
  (select payment_status from public.reservations where id = (select res1 from fixture_b)),
  'pending', '(b3, pre-settle) B1 (cancelada, nunca en check-in) sigue pending'
);

-- ---------------------------------------------------------------------
-- Checkpoint inmediatamente antes de saldar la cuenta de A: las tres
-- reservas siguen pending de forma NATURAL (feat/booking-17 ya no marca
-- paid en el check-out individual de una habitación institucional) --
-- sin esto, (s4)/(s5) más abajo no probarían nada de settle_receivable.
-- ---------------------------------------------------------------------
select is(
  (select payment_status from public.reservations where id = (select res1 from fixture_a)),
  'pending', '(a8) A1 sigue pending justo antes de saldar la cuenta'
);
select is(
  (select payment_status from public.reservations where id = (select res2 from fixture_a)),
  'pending', '(a9) A2 sigue pending justo antes de saldar la cuenta'
);
select is(
  (select payment_status from public.reservations where id = (select res3 from fixture_a)),
  'pending', '(a10) A3 sigue pending (no se tocó, ya lo estaba: cancelada, nunca facturada)'
);

-- ---------------------------------------------------------------------
-- Saldar la cuenta de A: rol autorizado (reception), caja abierta
-- del seed.
-- ---------------------------------------------------------------------
select public.settle_receivable(
  (select id from public.receivables where booking_id = (select booking_id from fixture_a)),
  'EFECTIVO'
);

select is(
  (select status from public.receivables where booking_id = (select booking_id from fixture_a)),
  'paid', '(s1) la cuenta por cobrar de A queda paid'
);
select is(
  (select settle_method from public.receivables where booking_id = (select booking_id from fixture_a)),
  'EFECTIVO', '(s2) settle_method registrado'
);
select is(
  (select count(*)::int from public.cash_movements
    where category = 'cobro_cuenta' and amount_bs = 3000.00
      and id = (select cash_movement_id from public.receivables
                  where booking_id = (select booking_id from fixture_a))),
  1, '(s3) se generó exactamente 1 movimiento de caja de ingreso por 3000, enlazado a la cuenta'
);

select is(
  (select payment_status from public.reservations where id = (select res1 from fixture_a)),
  'paid', '(s4, NUEVO) A1 pasa de pending a paid SOLO por saldar la cuenta del grupo (reseteada arriba, sin'
  || ' otro camino posible hacia paid)'
);
select is(
  (select payment_status from public.reservations where id = (select res2 from fixture_a)),
  'paid', '(s5, NUEVO) A2 pasa de pending a paid SOLO por saldar la cuenta del grupo (idem)'
);
select is(
  (select payment_status from public.reservations where id = (select res3 from fixture_a)),
  'paid', '(s6, NUEVO) A3 (cancelada) pasa a paid SOLO por saldar la cuenta del grupo -- esta es la fila que'
  || ' antes del fix quedaba huérfana en pending para siempre'
);

-- ---------------------------------------------------------------------
-- Otros bookings no se tocan: la fila de B sigue intacta tras saldar A.
-- ---------------------------------------------------------------------
select is(
  (select status from public.receivables where booking_id = (select booking_id from fixture_b)),
  'pending', '(o1) la cuenta por cobrar de B sigue pending (no la tocó el settle de A)'
);
select is(
  (select payment_status from public.reservations where id = (select res1 from fixture_b)),
  'pending', '(o2) B1 sigue pending (no la tocó el settle de A)'
);

-- ---------------------------------------------------------------------
-- Rol no autorizado (accountant) se rechaza -- regresión, sin efecto
-- secundario sobre la cuenta de B.
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated"}', true); -- accountant

select throws_ok(
  format(
    $$ select public.settle_receivable(%L, 'EFECTIVO') $$,
    (select id from public.receivables where booking_id = (select booking_id from fixture_b))
  ),
  'P0001', 'No autorizado',
  '(u1) accountant no puede saldar cuentas por cobrar (regresión, mismo guard que hoy)'
);
select is(
  (select status from public.receivables where booking_id = (select booking_id from fixture_b)),
  'pending', '(u2) la cuenta de B sigue pending tras el intento rechazado'
);

-- ---------------------------------------------------------------------
-- cancel_receivable sobre una cuenta de grupo: NO debe tocar
-- reservations (no es settle_receivable).
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

select public.cancel_receivable(
  (select id from public.receivables where booking_id = (select booking_id from fixture_b)),
  'Se decidió no cobrar, cortesía institucional'
);
select is(
  (select status from public.receivables where booking_id = (select booking_id from fixture_b)),
  'cancelled', '(c1) cancel_receivable marca la cuenta de B como cancelled'
);
select is(
  (select payment_status from public.reservations where id = (select res1 from fixture_b)),
  'pending', '(c2) cancel_receivable NO toca reservations -- B1 sigue pending'
);

-- ---------------------------------------------------------------------
-- (C) Regresión each_stay: cuenta por cobrar A NIVEL DE RESERVA
-- (reservation_id seteado, booking_id NULL) sigue actualizando SOLO esa
-- reserva, no el resto del booking.
-- ---------------------------------------------------------------------
do $$
declare
  v_room1 uuid; v_type1 uuid; v_room2 uuid; v_type2 uuid;
  v_result jsonb; v_res1 uuid; v_res2 uuid; v_booking uuid;
begin
  select o.room_id, o.room_type_id into v_room1, v_type1
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 650
    and o.room_id not in (select room_id from public.reservations)
  limit 1;
  select o.room_id, o.room_type_id into v_room2, v_type2
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 650
    and o.room_id not in (select room_id from public.reservations) and o.room_id <> v_room1
  limit 1;

  perform set_config('request.jwt.claims',
    '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true); -- reception_admin

  -- payer_mode por default: 'each_stay'.
  v_result := public.create_bulk_reservation(
    jsonb_build_array(
      jsonb_build_object('room_id', v_room1, 'room_type_id', v_type1, 'num_guests', 1),
      jsonb_build_object('room_id', v_room2, 'room_type_id', v_type2, 'num_guests', 1)
    ),
    'Cada', 'Saldo C', '70300003', 'settle.c@fixture.test',
    '2027-08-07', '2027-08-09', 'phone', null, null
  );
  v_res1 := ((v_result->'created')->>0)::uuid;
  v_res2 := ((v_result->'created')->>1)::uuid;
  select booking_id into v_booking from public.reservations where id = v_res1;

  create temp table fixture_c as select v_res1 as res1, v_res2 as res2, v_booking as booking_id;
end $$;

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

select public.check_in_reservation((select res1 from fixture_c), '11200003', '1990-01-01', 'BO', 'La Paz', false);
select public.check_out_room(
  (select room_id from public.reservations where id = (select res1 from fixture_c)),
  'CTAS_POR_COBRAR', null, null, (select account_id from fixture_account)
);

select is(
  (select row(amount_bs, reservation_id, booking_id, status)
     from public.receivables where reservation_id = (select res1 from fixture_c)),
  (select row(1300.00, (select res1 from fixture_c), null::uuid, 'pending'::text)),
  '(e1) cuenta por cobrar de la reserva C1: reservation_id seteado, booking_id NULL, 1300 (650 x 2 noches)'
);
select is(
  (select payment_status from public.reservations where id = (select res2 from fixture_c)),
  'pending', '(e2, pre-settle) C2 (hermana en el mismo booking, nunca en check-in) sigue pending'
);

select public.settle_receivable(
  (select id from public.receivables where reservation_id = (select res1 from fixture_c)),
  'EFECTIVO'
);

select is(
  (select status from public.receivables where reservation_id = (select res1 from fixture_c)),
  'paid', '(e3) la cuenta por cobrar de C1 queda paid'
);
select is(
  (select count(*)::int from public.cash_movements
    where category = 'cobro_cuenta' and amount_bs = 1300.00
      and id = (select cash_movement_id from public.receivables
                  where reservation_id = (select res1 from fixture_c))),
  1, '(e4) movimiento de caja de 1300 enlazado a la cuenta de C1'
);
select is(
  (select payment_status from public.reservations where id = (select res1 from fixture_c)),
  'paid', '(e5) C1 pasa a paid (camino de siempre, reservation_id)'
);
select is(
  (select payment_status from public.reservations where id = (select res2 from fixture_c)),
  'pending', '(e6, REGRESIÓN) C2 sigue pending -- el settle de una cuenta a nivel de reserva NO se '
  || 'propaga al resto del booking (booking_id de esa cuenta es NULL)'
);

select * from finish();
rollback;
