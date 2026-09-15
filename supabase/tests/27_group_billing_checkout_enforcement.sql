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
select plan(16);

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

select * from finish();
rollback;
