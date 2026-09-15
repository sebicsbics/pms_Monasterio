-- =====================================================================
-- check_out_room / record_anticipo: enforcement institucional (change:
-- group-billing, stage 6, Slice 6, branch
-- feat/booking-17-checkout-enforcement). Spec R6.1-R6.4. Aplica también
-- la extensión de alcance de la decisión #391 (orquestador, post-review
-- de feat/booking-16): payment_status de una habitación de una reserva
-- institucional refleja "la deuda del GRUPO por esta habitación está
-- saldada", no "este check-out cobró plata".
--
-- CARACTERIZACIÓN (sección 1, each_stay): ningún test existente ejercita
-- el propio check_out_room/record_anticipo con aserciones sobre el monto
-- cobrado, el movimiento de caja generado, payment_status, el cierre del
-- folio o el estado de la habitación -- 25_group_billing_close_trigger.sql
-- y 26_group_billing_settle_receivable_booking.sql los usan solo como
-- medio para disparar transiciones de reserva/cierre de grupo, sin
-- afirmar sobre sus propios efectos. 06_checkin_payment.sql SÍ cubre
-- record_anticipo each_stay (caja abierta/cerrada, CORTESIA) -- no se
-- duplica acá. Esta sección debe seguir pasando IGUAL después del fix: el
-- camino each_stay no cambia (spec R6.2).
--
-- RED (sección 2, client/institucional): el comportamiento nuevo exigido
-- por R6.1/R6.3/R6.4 y la decisión #391, que todavía NO existe en el
-- código vivo al momento de escribir esta sección.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(55);

-- ---------------------------------------------------------------------
-- Fixture: cuenta por cobrar compartida (para CTAS_POR_COBRAR y para los
-- bookings institucionales de la sección RED).
-- ---------------------------------------------------------------------
do $$
declare
  v_account uuid;
begin
  insert into public.receivable_accounts (name, kind)
  values ('Fixture Checkout Enforcement', 'empresa')
  returning id into v_account;

  create temp table fixture_account as select v_account as account_id;
end $$;

-- =======================================================================
-- SECCIÓN 1 -- CARACTERIZACIÓN (each_stay, comportamiento vivo actual)
-- =======================================================================

-- ---------------------------------------------------------------------
-- (char-a) habitación + extras, EFECTIVO: cobra total+extras, un
-- movimiento de caja, payment_status paid, folio cerrado, habitación
-- dirty.
-- ---------------------------------------------------------------------
do $$
declare
  v_room uuid; v_type uuid; v_res uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 500
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  perform set_config('request.jwt.claims',
    '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

  v_res := public.create_reservation(
    v_room, v_type, 'Cada', 'Char A', '70400001', 'char.a@fixture.test',
    '2027-09-01', '2027-09-02', 1, 'phone', null, null, true
  );

  create temp table fixture_char_a as select v_res as res1, v_room as room_id;
end $$;

select public.check_in_reservation((select res1 from fixture_char_a), '11300001', '1990-01-01', 'BO', 'La Paz', false);

reset role;
insert into public.folio_charges (folio_id, description, amount_bs)
select f.id, 'Extra fixture char A', 80.00
from public.folios f where f.reservation_id = (select res1 from fixture_char_a);

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

select is(
  public.check_out_room((select room_id from fixture_char_a)),
  580.00, '(char-a1) each_stay: 500 de habitación + 80 de extras = 580 cobrados (caracterización)'
);
select is(
  (select count(*)::int from public.cash_movements where category = 'cobro_habitacion' and amount_bs = 580.00),
  1, '(char-a2) exactamente 1 movimiento de caja de 580 por el check-out'
);
select is(
  (select payment_status from public.reservations where id = (select res1 from fixture_char_a)),
  'paid', '(char-a3) payment_status queda paid (each_stay, sin cambios)'
);
select ok(
  (select closed_at is not null from public.folios where reservation_id = (select res1 from fixture_char_a)),
  '(char-a4) el folio queda cerrado'
);
select is(
  (select operational_status from public.rooms where id = (select room_id from fixture_char_a)),
  'dirty', '(char-a5) la habitación queda dirty'
);

-- ---------------------------------------------------------------------
-- (char-b) con anticipo activo: due = total - anticipo.
-- ---------------------------------------------------------------------
do $$
declare
  v_room uuid; v_type uuid; v_res uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 500
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_res := public.create_reservation(
    v_room, v_type, 'Cada', 'Char B', '70400002', 'char.b@fixture.test',
    '2027-09-03', '2027-09-04', 1, 'phone', null, null, true
  );

  create temp table fixture_char_b as select v_res as res1, v_room as room_id;
end $$;

select public.record_anticipo((select res1 from fixture_char_b), 200, 'EFECTIVO', 'Anticipo char B');
select public.check_in_reservation((select res1 from fixture_char_b), '11300002', '1990-01-01', 'BO', 'La Paz', false);

select is(
  public.check_out_room((select room_id from fixture_char_b)),
  300.00, '(char-b1) each_stay con anticipo: 500 - 200 = 300 cobrados (caracterización)'
);
select is(
  (select count(*)::int from public.cash_movements where category = 'cobro_habitacion' and amount_bs = 300.00),
  1, '(char-b2) exactamente 1 movimiento de caja de 300'
);

-- ---------------------------------------------------------------------
-- (char-c) MIXTO: se reparte en efectivo + no-efectivo (record_mixed_income).
-- ---------------------------------------------------------------------
do $$
declare
  v_room uuid; v_type uuid; v_res uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 650
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_res := public.create_reservation(
    v_room, v_type, 'Cada', 'Char C', '70400003', 'char.c@fixture.test',
    '2027-09-05', '2027-09-06', 1, 'phone', null, null, true
  );

  create temp table fixture_char_c as select v_res as res1, v_room as room_id;
end $$;

select public.check_in_reservation((select res1 from fixture_char_c), '11300003', '1990-01-01', 'BO', 'La Paz', false);

select is(
  public.check_out_room(
    (select room_id from fixture_char_c), 'MIXTO', null, null, null, 400.00, 250.00, 'DEPOSITO'
  ),
  650.00, '(char-c1) each_stay MIXTO: due=650, split 400 efectivo + 250 depósito (caracterización)'
);
select is(
  (select count(*)::int from public.cash_movements
    where category = 'cobro_habitacion' and amount_bs = 400.00 and payment_method = 'EFECTIVO'),
  1, '(char-c2) pata efectivo del MIXTO: 1 movimiento de 400'
);
select is(
  (select count(*)::int from public.cash_movements
    where category = 'cobro_habitacion' and amount_bs = 250.00 and payment_method = 'DEPOSITO'),
  1, '(char-c3) pata depósito del MIXTO: 1 movimiento de 250'
);
select is(
  (select payment_status from public.reservations where id = (select res1 from fixture_char_c)),
  'paid', '(char-c4) payment_status queda paid'
);

-- ---------------------------------------------------------------------
-- (char-d) CTAS_POR_COBRAR: se factura el saldo a la cuenta, payment_status
-- queda pending (comportamiento vivo, se verifica explícitamente).
-- ---------------------------------------------------------------------
do $$
declare
  v_room uuid; v_type uuid; v_res uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 450
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_res := public.create_reservation(
    v_room, v_type, 'Cada', 'Char D', '70400004', 'char.d@fixture.test',
    '2027-09-07', '2027-09-08', 1, 'phone', null, null, true
  );

  create temp table fixture_char_d as select v_res as res1, v_room as room_id;
end $$;

select public.check_in_reservation((select res1 from fixture_char_d), '11300004', '1990-01-01', 'BO', 'La Paz', false);

reset role;
insert into public.folio_charges (folio_id, description, amount_bs)
select f.id, 'Extra fixture char D', 30.00
from public.folios f where f.reservation_id = (select res1 from fixture_char_d);

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

select is(
  public.check_out_room(
    (select room_id from fixture_char_d), 'CTAS_POR_COBRAR', null, null, (select account_id from fixture_account)
  ),
  480.00, '(char-d1) each_stay CTAS_POR_COBRAR: due=480 (450+30), se factura a la cuenta (caracterización)'
);
select is(
  (select row(amount_bs, reservation_id, booking_id, status)
     from public.receivables where reservation_id = (select res1 from fixture_char_d)),
  (select row(480.00, (select res1 from fixture_char_d), null::uuid, 'pending'::text)),
  '(char-d2) cuenta por cobrar a nivel de reserva por 480'
);
select is(
  (select payment_status from public.reservations where id = (select res1 from fixture_char_d)),
  'pending', '(char-d3) payment_status queda pending con CTAS_POR_COBRAR (caracterización, comportamiento vivo)'
);

-- ---------------------------------------------------------------------
-- (char-e) due=0 (anticipo exacto): sin movimiento de caja, pero
-- payment_status IGUAL pasa a paid hoy (comportamiento vivo actual,
-- each_stay -- distinto del cambio para client en la sección RED).
-- ---------------------------------------------------------------------
do $$
declare
  v_room uuid; v_type uuid; v_res uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 500
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_res := public.create_reservation(
    v_room, v_type, 'Cada', 'Char E', '70400005', 'char.e@fixture.test',
    '2027-09-09', '2027-09-10', 1, 'phone', null, null, true
  );

  create temp table fixture_char_e as select v_res as res1, v_room as room_id;
end $$;

select public.record_anticipo((select res1 from fixture_char_e), 500, 'EFECTIVO', 'Anticipo exacto char E');
select public.check_in_reservation((select res1 from fixture_char_e), '11300005', '1990-01-01', 'BO', 'La Paz', false);

select is(
  public.check_out_room((select room_id from fixture_char_e)),
  0.00, '(char-e1) each_stay con anticipo exacto: due=0 (caracterización)'
);
select is(
  (select payment_status from public.reservations where id = (select res1 from fixture_char_e)),
  'paid', '(char-e2) payment_status queda paid IGUAL aunque due=0 (comportamiento vivo, each_stay no cambia)'
);

-- =======================================================================
-- SECCIÓN 2 -- RED (client/institucional, feat/booking-17 + decisión #391)
-- =======================================================================

-- ---------------------------------------------------------------------
-- (red1) habitación de reserva institucional con 500 de contrato + 80 de
-- extras: check-out cobra SOLO los 80 (R6.1), nunca los 500, y NO marca
-- payment_status='paid' (decisión #391) -- el resto del efecto (folio
-- cerrado, habitación dirty) es igual que hoy.
-- ---------------------------------------------------------------------
do $$
declare
  v_room uuid; v_type uuid; v_res uuid; v_booking uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 500
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  perform set_config('request.jwt.claims',
    '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true); -- reception_admin

  v_res := public.create_reservation(
    v_room, v_type, 'Institución', 'RED 1', '70500001', 'red1@fixture.test',
    '2027-09-11', '2027-09-12', 1, 'phone', null, null, true,
    'client', 'room', null, (select account_id from fixture_account),
    null, null, null, null, false, null
  );
  select booking_id into v_booking from public.reservations where id = v_res;

  create temp table fixture_red1 as select v_res as res1, v_room as room_id, v_booking as booking_id;
end $$;

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

select public.check_in_reservation((select res1 from fixture_red1), '11400001', '1990-01-01', 'BO', 'La Paz', false);

reset role;
insert into public.folio_charges (folio_id, description, amount_bs)
select f.id, 'Extra fixture RED 1', 80.00
from public.folios f where f.reservation_id = (select res1 from fixture_red1);

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

select is(
  public.check_out_room((select room_id from fixture_red1)),
  80.00, '(red1-1) client: 500 de habitación + 80 de extras -> cobra SOLO 80 (R6.1)'
);
select is(
  (select count(*)::int from public.cash_movements where category = 'cobro_habitacion' and amount_bs = 80.00),
  1, '(red1-2) exactamente 1 movimiento de caja de 80'
);
select is(
  (select count(*)::int from public.cash_movements where category = 'cobro_habitacion' and amount_bs = 500.00),
  0, '(red1-3) NUNCA se genera un movimiento por los 500 de la habitación'
);
select is(
  (select payment_status from public.reservations where id = (select res1 from fixture_red1)),
  'pending', '(red1-4) payment_status NO pasa a paid en el check-out individual de una reserva institucional (#391)'
);
select ok(
  (select closed_at is not null from public.folios where reservation_id = (select res1 from fixture_red1)),
  '(red1-5) el folio queda cerrado igual'
);
select is(
  (select operational_status from public.rooms where id = (select room_id from fixture_red1)),
  'dirty', '(red1-6) la habitación queda dirty igual'
);

-- ---------------------------------------------------------------------
-- (red2) habitación institucional sin extras: due=0, el check-out se
-- completa igual (R6.3, no bloquea por extras impagas -- acá no hay
-- ninguna).
-- ---------------------------------------------------------------------
do $$
declare
  v_room uuid; v_type uuid; v_res uuid; v_booking uuid;
begin
  -- Pool 550/2: comparte físicamente las 2 habitaciones del pool 450/1 ya
  -- usado por (char-d) -- queda exactamente 1 libre a esta altura del
  -- archivo (char-d corre antes que esta sección).
  select o.room_id, o.room_type_id into v_room, v_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 2 and rt.base_price_bs = 550
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  perform set_config('request.jwt.claims',
    '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true); -- reception_admin

  v_res := public.create_reservation(
    v_room, v_type, 'Institución', 'RED 2', '70500002', 'red2@fixture.test',
    '2027-09-13', '2027-09-14', 1, 'phone', null, null, true,
    'client', 'room', null, (select account_id from fixture_account),
    null, null, null, null, false, null
  );
  select booking_id into v_booking from public.reservations where id = v_res;

  create temp table fixture_red2 as select v_res as res1, v_room as room_id, v_booking as booking_id;
end $$;

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

select public.check_in_reservation((select res1 from fixture_red2), '11400002', '1990-01-01', 'BO', 'La Paz', false);

select is(
  public.check_out_room((select room_id from fixture_red2)),
  0.00, '(red2-1) client sin extras: due=0, el check-out igual se completa (R6.3, no bloquea)'
);
select is(
  (select status from public.reservations where id = (select res1 from fixture_red2)),
  'checked_out', '(red2-2) la reserva queda checked_out'
);
select is(
  (select payment_status from public.reservations where id = (select res1 from fixture_red2)),
  'pending', '(red2-3) payment_status sigue pending (nada que cobrar y todavía no cerró el grupo)'
);

-- ---------------------------------------------------------------------
-- (red3) habitación institucional con extras impagas + CTAS_POR_COBRAR:
-- se factura una cuenta por cobrar a NIVEL DE RESERVA por los 80 de
-- extras (no por el contrato del grupo).
-- ---------------------------------------------------------------------
do $$
declare
  v_room uuid; v_type uuid; v_res uuid; v_booking uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 4 and rt.base_price_bs = 780
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  perform set_config('request.jwt.claims',
    '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true); -- reception_admin

  v_res := public.create_reservation(
    v_room, v_type, 'Institución', 'RED 3', '70500003', 'red3@fixture.test',
    '2027-09-15', '2027-09-16', 1, 'phone', null, null, true,
    'client', 'room', null, (select account_id from fixture_account),
    null, null, null, null, false, null
  );
  select booking_id into v_booking from public.reservations where id = v_res;

  create temp table fixture_red3 as select v_res as res1, v_room as room_id, v_booking as booking_id;
end $$;

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

select public.check_in_reservation((select res1 from fixture_red3), '11400003', '1990-01-01', 'BO', 'La Paz', false);

reset role;
insert into public.folio_charges (folio_id, description, amount_bs)
select f.id, 'Extra fixture RED 3', 80.00
from public.folios f where f.reservation_id = (select res1 from fixture_red3);

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

select is(
  public.check_out_room(
    (select room_id from fixture_red3), 'CTAS_POR_COBRAR', null, null, (select account_id from fixture_account)
  ),
  80.00, '(red3-1) client CTAS_POR_COBRAR: due=80 (solo extras), se factura a la cuenta'
);
select is(
  (select row(amount_bs, reservation_id, booking_id, status)
     from public.receivables where reservation_id = (select res1 from fixture_red3)),
  (select row(80.00, (select res1 from fixture_red3), null::uuid, 'pending'::text)),
  '(red3-2) cuenta por cobrar a NIVEL DE RESERVA (no de booking) por 80, los extras de esta habitación'
);
select is(
  (select payment_status from public.reservations where id = (select res1 from fixture_red3)),
  'pending', '(red3-3) payment_status pending (CTAS_POR_COBRAR, igual que hoy)'
);

-- ---------------------------------------------------------------------
-- (red4) record_anticipo sobre una reserva institucional: se rechaza,
-- sin ninguna mutación previa (R6.4).
-- ---------------------------------------------------------------------
do $$
declare
  v_room uuid; v_type uuid; v_res uuid; v_booking uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 3 and rt.base_price_bs = 600
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  perform set_config('request.jwt.claims',
    '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true); -- reception_admin

  v_res := public.create_reservation(
    v_room, v_type, 'Institución', 'RED 4', '70500004', 'red4@fixture.test',
    '2027-09-17', '2027-09-18', 1, 'phone', null, null, true,
    'client', 'room', null, (select account_id from fixture_account),
    null, null, null, null, false, null
  );
  select booking_id into v_booking from public.reservations where id = v_res;

  create temp table fixture_red4 as select v_res as res1, v_booking as booking_id;
end $$;

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

select throws_ok(
  format(
    $$ select public.record_anticipo(%L, 100, 'EFECTIVO', 'Intento anticipo institucional') $$,
    (select res1 from fixture_red4)
  ),
  'P0001', 'Las reservas institucionales no usan anticipos por habitación; usá el adelanto de grupo',
  '(red4-1) record_anticipo sobre reserva institucional se rechaza (R6.4)'
);
select is(
  (select count(*)::int from public.anticipos where reservation_id = (select res1 from fixture_red4)),
  0, '(red4-2) no se insertó ningún anticipo'
);
select is(
  (select count(*)::int from public.cash_movements
    where category = 'adelanto' and concept ilike '%' || (select res1 from fixture_red4)::text || '%'),
  0, '(red4-3) no se generó ningún movimiento de caja (el guard corre ANTES de cualquier mutación)'
);

-- ---------------------------------------------------------------------
-- (red5) booking institucional pagado en su totalidad (adelanto =
-- contrato exacto): el check-out de la última habitación activa cierra
-- el grupo con saldo 0 -> decisión #391, punto 2: TODAS las reservas del
-- booking (incluida la cancelada) quedan payment_status='paid', sin
-- cuenta por cobrar.
-- ---------------------------------------------------------------------
do $$
declare
  v_room1 uuid; v_type1 uuid; v_room2 uuid; v_type2 uuid;
  v_result jsonb; v_res1 uuid; v_res2 uuid; v_booking uuid;
begin
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
    'Institución', 'RED 5', '70500005', 'red5@fixture.test',
    '2027-09-19', '2027-09-20', 'phone', null, null,
    'client', 'room', null, (select account_id from fixture_account)
  );
  v_res1 := ((v_result->'created')->>0)::uuid;
  v_res2 := ((v_result->'created')->>1)::uuid;
  select booking_id into v_booking from public.reservations where id = v_res1;

  create temp table fixture_red5 as select v_res1 as res1, v_res2 as res2, v_booking as booking_id;
end $$;

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

select public.record_booking_advance(
  (select booking_id from fixture_red5), 960, 'EFECTIVO', null, null, null, null, null, 'Adelanto exacto RED 5'
);
select public.cancel_reservation((select res2 from fixture_red5), 'No-show habitación 2');
select public.check_in_reservation((select res1 from fixture_red5), '11400005', '1990-01-01', 'BO', 'La Paz', false);
select public.check_out_room((select room_id from public.reservations where id = (select res1 from fixture_red5)));

select is(
  (select count(*)::int from public.booking_balances
    where booking_id = (select booking_id from fixture_red5) and event_type = 'group_closed'),
  1, '(red5-1) cierra en el check-out de la última habitación activa'
);
select is(
  (select amount_bs from public.booking_balances
    where booking_id = (select booking_id from fixture_red5) and event_type = 'group_closed'),
  0.00, '(red5-2) saldo neto 0 (adelanto = contrato exacto)'
);
select is(
  (select count(*)::int from public.receivables where booking_id = (select booking_id from fixture_red5)),
  0, '(red5-3) sin cuenta por cobrar (nada pendiente)'
);
select is(
  (select payment_status from public.reservations where id = (select res1 from fixture_red5)),
  'paid', '(red5-4) la habitación que hizo check-out queda paid por el cierre con saldo 0 (#391)'
);
select is(
  (select payment_status from public.reservations where id = (select res2 from fixture_red5)),
  'paid', '(red5-5) la habitación CANCELADA también queda paid -- el saldo del grupo está saldado (#391)'
);

-- ---------------------------------------------------------------------
-- (red6) booking institucional con saldo pendiente al cerrar (adelanto
-- parcial): la habitación queda pending hasta que se salda la cuenta por
-- cobrar de grupo (eso ya lo cubre 26_group_billing_settle_receivable_
-- booking.sql -- acá solo se confirma el estado INMEDIATAMENTE tras el
-- cierre).
-- ---------------------------------------------------------------------
do $$
declare
  v_room uuid; v_type uuid; v_res uuid; v_booking uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 2 and rt.base_price_bs = 800
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  perform set_config('request.jwt.claims',
    '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true); -- reception_admin

  v_res := public.create_reservation(
    v_room, v_type, 'Institución', 'RED 6', '70500006', 'red6@fixture.test',
    '2027-09-21', '2027-09-22', 1, 'phone', null, null, true,
    'client', 'room', null, (select account_id from fixture_account),
    null, null, null, null, false, null
  );
  select booking_id into v_booking from public.reservations where id = v_res;

  create temp table fixture_red6 as select v_res as res1, v_booking as booking_id;
end $$;

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

select public.record_booking_advance(
  (select booking_id from fixture_red6), 300, 'EFECTIVO', null, null, null, null, null, 'Adelanto parcial RED 6'
);
select public.check_in_reservation((select res1 from fixture_red6), '11400006', '1990-01-01', 'BO', 'La Paz', false);
select public.check_out_room((select room_id from public.reservations where id = (select res1 from fixture_red6)));

select is(
  (select amount_bs from public.booking_balances
    where booking_id = (select booking_id from fixture_red6) and event_type = 'group_closed'),
  500.00, '(red6-1) saldo neto 500 al cerrar (800 - 300)'
);
select is(
  (select count(*)::int from public.receivables where booking_id = (select booking_id from fixture_red6)),
  1, '(red6-2) se genera la cuenta por cobrar de grupo'
);
select is(
  (select payment_status from public.reservations where id = (select res1 from fixture_red6)),
  'pending', '(red6-3) la habitación queda pending -- todavía hay saldo, recién pasa a paid al saldar la cuenta (26_*)'
);

-- =======================================================================
-- SECCIÓN 3 -- RED (review fix, decisión #391 v2: modelo correcto, no
-- parche). El review de esta rama reprodujo en vivo un bug crítico: el
-- `update ... set payment_status='paid'` masivo de `_close_booking_group`
-- (y la misma sobreescritura en el tail de `settle_receivable`) pisaba
-- cualquier cuenta por cobrar de EXTRAS de una habitación (reservation_id
-- seteado, CTAS_POR_COBRAR) que todavía estuviera pendiente. La regla
-- correcta: una habitación institucional es 'paid' SOLO si (1) el grupo
-- cerró, (2) la deuda del GRUPO está saldada (sin cuenta por cobrar de
-- booking, o esa cuenta ya está 'paid' -- una cancelada NO cuenta como
-- saldada) Y (3) todas SUS PROPIAS cuentas por cobrar de extras están
-- 'paid'. Todas las fixtures de esta sección usan el pool 480/2occ (17
-- libres a esta altura del archivo, sin alias con otro pool ya usado).
-- =======================================================================

-- ---------------------------------------------------------------------
-- (redfix-a) EL CASO DEL REVIEW: grupo prepago (adelanto = contrato,
-- neto 0). La última habitación tiene 80 de extras vía CTAS_POR_COBRAR.
-- Al cerrar: la OTRA habitación (sin deuda propia) queda 'paid'; ÉSTA
-- queda 'pending' hasta que se salda su propia cuenta de extras.
-- ---------------------------------------------------------------------
do $$
declare
  v_room1 uuid; v_type1 uuid; v_room2 uuid; v_type2 uuid;
  v_result jsonb; v_res1 uuid; v_res2 uuid; v_booking uuid;
begin
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
    'Institución', 'REDFIX A', '70600001', 'redfixa@fixture.test',
    '2027-10-01', '2027-10-02', 'phone', null, null,
    'client', 'room', null, (select account_id from fixture_account)
  );
  v_res1 := ((v_result->'created')->>0)::uuid;
  v_res2 := ((v_result->'created')->>1)::uuid;
  select booking_id into v_booking from public.reservations where id = v_res1;

  create temp table fixture_redfix_a as select v_res1 as res1, v_res2 as res2, v_booking as booking_id;
end $$;

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

select public.record_booking_advance(
  (select booking_id from fixture_redfix_a), 960, 'EFECTIVO', null, null, null, null, null, 'Adelanto exacto REDFIX A'
);

select public.check_in_reservation((select res1 from fixture_redfix_a), '11500001', '1990-01-01', 'BO', 'La Paz', false);
select public.check_out_room((select room_id from public.reservations where id = (select res1 from fixture_redfix_a)));

select public.check_in_reservation((select res2 from fixture_redfix_a), '11500002', '1990-01-01', 'BO', 'La Paz', false);
reset role;
insert into public.folio_charges (folio_id, description, amount_bs)
select f.id, 'Extra fixture REDFIX A', 80.00
from public.folios f where f.reservation_id = (select res2 from fixture_redfix_a);
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

select public.check_out_room(
  (select room_id from public.reservations where id = (select res2 from fixture_redfix_a)),
  'CTAS_POR_COBRAR', null, null, (select account_id from fixture_account)
);

select is(
  (select payment_status from public.reservations where id = (select res1 from fixture_redfix_a)),
  'paid', '(redfix-a1) room1 (sin deuda propia) queda paid al cerrar el grupo con neto 0'
);
select is(
  (select payment_status from public.reservations where id = (select res2 from fixture_redfix_a)),
  'pending', '(redfix-a2) room2 (extras 80 pendientes) SIGUE pending pese a que el grupo cerró con neto 0 -- el bug del review'
);
select is(
  (select row(amount_bs, reservation_id, booking_id, status)
     from public.receivables where reservation_id = (select res2 from fixture_redfix_a)),
  (select row(80.00, (select res2 from fixture_redfix_a), null::uuid, 'pending'::text)),
  '(redfix-a3) la cuenta de extras de room2 sigue pending, 80'
);
select is(
  (select count(*)::int from public.receivables
    where booking_id = (select booking_id from fixture_redfix_a) and reservation_id is null),
  0, '(redfix-a4) sin cuenta de GRUPO (neto 0, nada que facturar a nivel de booking)'
);

select public.settle_receivable(
  (select id from public.receivables where reservation_id = (select res2 from fixture_redfix_a)),
  'EFECTIVO'
);
select is(
  (select payment_status from public.reservations where id = (select res2 from fixture_redfix_a)),
  'paid', '(redfix-a5) room2 pasa a paid SOLO al saldar su propia cuenta de extras'
);

-- ---------------------------------------------------------------------
-- (redfix-b) grupo con saldo pendiente (neto > 0) al cerrar Y una
-- habitación con extras pendientes propias. Saldar la cuenta de GRUPO
-- marca paid a la que no tenía deuda propia, pero NO a la que todavía
-- debe sus extras; saldar esa cuenta de extras recién ahí la marca paid.
-- ---------------------------------------------------------------------
do $$
declare
  v_room1 uuid; v_type1 uuid; v_room2 uuid; v_type2 uuid;
  v_result jsonb; v_res1 uuid; v_res2 uuid; v_booking uuid;
begin
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
    'Institución', 'REDFIX B', '70600002', 'redfixb@fixture.test',
    '2027-10-03', '2027-10-04', 'phone', null, null,
    'client', 'room', null, (select account_id from fixture_account)
  );
  v_res1 := ((v_result->'created')->>0)::uuid;
  v_res2 := ((v_result->'created')->>1)::uuid;
  select booking_id into v_booking from public.reservations where id = v_res1;

  create temp table fixture_redfix_b as select v_res1 as res1, v_res2 as res2, v_booking as booking_id;
end $$;

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

select public.record_booking_advance(
  (select booking_id from fixture_redfix_b), 300, 'EFECTIVO', null, null, null, null, null, 'Adelanto parcial REDFIX B'
);

select public.check_in_reservation((select res1 from fixture_redfix_b), '11500003', '1990-01-01', 'BO', 'La Paz', false);
select public.check_out_room((select room_id from public.reservations where id = (select res1 from fixture_redfix_b)));

select public.check_in_reservation((select res2 from fixture_redfix_b), '11500004', '1990-01-01', 'BO', 'La Paz', false);
reset role;
insert into public.folio_charges (folio_id, description, amount_bs)
select f.id, 'Extra fixture REDFIX B', 80.00
from public.folios f where f.reservation_id = (select res2 from fixture_redfix_b);
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

select public.check_out_room(
  (select room_id from public.reservations where id = (select res2 from fixture_redfix_b)),
  'CTAS_POR_COBRAR', null, null, (select account_id from fixture_account)
);

select is(
  (select payment_status from public.reservations where id = (select res1 from fixture_redfix_b)),
  'pending', '(redfix-b1) room1 pending al cerrar: el grupo cerró pero la deuda de GRUPO (660) no está saldada'
);
select is(
  (select payment_status from public.reservations where id = (select res2 from fixture_redfix_b)),
  'pending', '(redfix-b2) room2 pending al cerrar (deuda de grupo Y extras propias sin saldar)'
);
select is(
  (select row(amount_bs, status) from public.receivables
     where booking_id = (select booking_id from fixture_redfix_b) and reservation_id is null),
  (select row(660.00, 'pending'::text)),
  '(redfix-b3) cuenta de GRUPO por 660 (960-300), pending'
);

select public.settle_receivable(
  (select id from public.receivables
     where booking_id = (select booking_id from fixture_redfix_b) and reservation_id is null),
  'EFECTIVO'
);
select is(
  (select payment_status from public.reservations where id = (select res1 from fixture_redfix_b)),
  'paid', '(redfix-b4) room1 pasa a paid al saldar la cuenta de GRUPO (no tenía deuda propia)'
);
select is(
  (select payment_status from public.reservations where id = (select res2 from fixture_redfix_b)),
  'pending', '(redfix-b5) room2 SIGUE pending -- saldar la cuenta de grupo NO pisa su cuenta de extras, todavía pendiente'
);

select public.settle_receivable(
  (select id from public.receivables where reservation_id = (select res2 from fixture_redfix_b)),
  'EFECTIVO'
);
select is(
  (select payment_status from public.reservations where id = (select res2 from fixture_redfix_b)),
  'paid', '(redfix-b6) room2 recién pasa a paid al saldar TAMBIÉN su propia cuenta de extras'
);

-- ---------------------------------------------------------------------
-- (redfix-c) saldar la cuenta de EXTRAS de una habitación mientras la
-- cuenta de GRUPO sigue pendiente: la habitación sigue pending (la deuda
-- del grupo pesa más).
-- ---------------------------------------------------------------------
do $$
declare
  v_room1 uuid; v_type1 uuid; v_room2 uuid; v_type2 uuid;
  v_result jsonb; v_res1 uuid; v_res2 uuid; v_booking uuid;
begin
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
    'Institución', 'REDFIX C', '70600003', 'redfixc@fixture.test',
    '2027-10-05', '2027-10-06', 'phone', null, null,
    'client', 'room', null, (select account_id from fixture_account)
  );
  v_res1 := ((v_result->'created')->>0)::uuid;
  v_res2 := ((v_result->'created')->>1)::uuid;
  select booking_id into v_booking from public.reservations where id = v_res1;

  create temp table fixture_redfix_c as select v_res1 as res1, v_res2 as res2, v_booking as booking_id;
end $$;

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

select public.record_booking_advance(
  (select booking_id from fixture_redfix_c), 300, 'EFECTIVO', null, null, null, null, null, 'Adelanto parcial REDFIX C'
);

select public.check_in_reservation((select res1 from fixture_redfix_c), '11500005', '1990-01-01', 'BO', 'La Paz', false);
select public.check_out_room((select room_id from public.reservations where id = (select res1 from fixture_redfix_c)));

select public.check_in_reservation((select res2 from fixture_redfix_c), '11500006', '1990-01-01', 'BO', 'La Paz', false);
reset role;
insert into public.folio_charges (folio_id, description, amount_bs)
select f.id, 'Extra fixture REDFIX C', 50.00
from public.folios f where f.reservation_id = (select res2 from fixture_redfix_c);
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

select public.check_out_room(
  (select room_id from public.reservations where id = (select res2 from fixture_redfix_c)),
  'CTAS_POR_COBRAR', null, null, (select account_id from fixture_account)
);

select is(
  (select payment_status from public.reservations where id = (select res2 from fixture_redfix_c)),
  'pending', '(redfix-c1) room2 pending antes de saldar nada'
);

select public.settle_receivable(
  (select id from public.receivables where reservation_id = (select res2 from fixture_redfix_c)),
  'EFECTIVO'
);
select is(
  (select payment_status from public.reservations where id = (select res2 from fixture_redfix_c)),
  'pending', '(redfix-c2) room2 SIGUE pending tras saldar SOLO sus extras -- la cuenta de GRUPO (660) sigue pendiente'
);
select is(
  (select status from public.receivables
     where booking_id = (select booking_id from fixture_redfix_c) and reservation_id is null),
  'pending', '(redfix-c3) la cuenta de GRUPO sigue pending (no se tocó)'
);

-- ---------------------------------------------------------------------
-- (redfix-d) cancel_receivable sobre la cuenta de GRUPO: la habitación
-- sigue pending (una cuenta cancelada NO cuenta como saldada, regresión).
-- ---------------------------------------------------------------------
do $$
declare
  v_room uuid; v_type uuid; v_res uuid; v_booking uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 2 and rt.base_price_bs = 480
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  perform set_config('request.jwt.claims',
    '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true); -- reception_admin

  v_res := public.create_reservation(
    v_room, v_type, 'Institución', 'REDFIX D', '70600004', 'redfixd@fixture.test',
    '2027-10-07', '2027-10-08', 1, 'phone', null, null, true,
    'client', 'room', null, (select account_id from fixture_account),
    null, null, null, null, false, null
  );
  select booking_id into v_booking from public.reservations where id = v_res;

  create temp table fixture_redfix_d as select v_res as res1, v_booking as booking_id;
end $$;

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

select public.check_in_reservation((select res1 from fixture_redfix_d), '11500007', '1990-01-01', 'BO', 'La Paz', false);
select public.check_out_room((select room_id from public.reservations where id = (select res1 from fixture_redfix_d)));

select public.cancel_receivable(
  (select id from public.receivables where booking_id = (select booking_id from fixture_redfix_d)),
  'Se decidió no cobrar, cortesía institucional'
);
select is(
  (select status from public.receivables where booking_id = (select booking_id from fixture_redfix_d)),
  'cancelled', '(redfix-d1) la cuenta de grupo queda cancelled'
);
select is(
  (select payment_status from public.reservations where id = (select res1 from fixture_redfix_d)),
  'pending', '(redfix-d2) la habitación SIGUE pending -- una cuenta cancelada no cuenta como saldada (regresión)'
);

select * from finish();
rollback;
