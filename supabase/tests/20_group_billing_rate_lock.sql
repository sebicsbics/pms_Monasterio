-- =====================================================================
-- Caracterización de apply_rate_change / approve_rate_discount_request
-- (change: group-billing, stage 6, Slice 3, branch
-- feat/booking-13-rate-lock) -- deben pasar SIN tocar una línea de SQL.
--
-- Prueba que el refactor que sigue en este mismo branch (delegar la
-- rama "aplica directo" de apply_rate_change a _apply_rate_change_direct
-- en vez de duplicar su lógica inline, y agregar un candado para
-- reservas con contrato institucional ya congelado) no cambia ningún
-- resultado observable de HOY. Las pruebas RED del candado nuevo se
-- agregan en un commit posterior sobre este mismo archivo, junto con
-- la migración 20260911110000_group_billing_rate_lock.sql.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(23);

create or replace function pg_temp.snap() returns text language sql as $$
  select row(
    (select count(*) from public.reservations),
    (select count(*) from public.rate_overrides),
    (select count(*) from public.rate_discount_requests),
    (select count(*) from public.booking_balances)
  )::text
$$;

-- ---------------------------------------------------------------------
-- Fixtures compartidas de caracterización: 4 reservas each_stay,
-- habitación 1-persona/350, libres.
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

do $$
declare v_room uuid; v_room_type uuid; v_r1 uuid; v_r2 uuid; v_r3 uuid; v_r4 uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_room_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 350
    and o.room_id not in (select room_id from public.reservations)
  limit 1;
  v_r1 := public.create_reservation(v_room, v_room_type, 'Rate', 'Lock A', '70000101', 'rate.a@fixture.test',
    '2027-08-01', '2027-08-03', 1, 'phone', null, null, true);

  select o.room_id, o.room_type_id into v_room, v_room_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 350
    and o.room_id not in (select room_id from public.reservations)
  limit 1;
  v_r2 := public.create_reservation(v_room, v_room_type, 'Rate', 'Lock B', '70000102', 'rate.b@fixture.test',
    '2027-08-01', '2027-08-03', 1, 'phone', null, null, true);

  select o.room_id, o.room_type_id into v_room, v_room_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 350
    and o.room_id not in (select room_id from public.reservations)
  limit 1;
  v_r3 := public.create_reservation(v_room, v_room_type, 'Rate', 'Lock C', '70000103', 'rate.c@fixture.test',
    '2027-08-01', '2027-08-03', 1, 'phone', null, null, true);

  select o.room_id, o.room_type_id into v_room, v_room_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 350
    and o.room_id not in (select room_id from public.reservations)
  limit 1;
  v_r4 := public.create_reservation(v_room, v_room_type, 'Rate', 'Lock D', '70000104', 'rate.d@fixture.test',
    '2027-08-01', '2027-08-03', 1, 'phone', null, null, true);

  create temp table fixture_rooms as select v_r1 as r1, v_r2 as r2, v_r3 as r3, v_r4 as r4;
end $$;

-- ---------------------------------------------------------------------
-- (a) CARACTERIZACIÓN: each_stay, reception, descuento <=20% -> se
--     aplica directo. Congela el resultado completo: la fila devuelta,
--     el total actualizado, el rate_overrides exacto y que no se crea
--     ninguna solicitud.
-- ---------------------------------------------------------------------
create temp table result_a as
  select * from public.apply_rate_change(
    (select r1 from fixture_rooms),
    (select room_type_id from public.reservations where id = (select r1 from fixture_rooms)),
    350, 2, 300, 'Caracterización: descuento chico'
  );

select is((select applied from result_a), true, '(a) descuento <=20%: applied=true');
select is((select discount_pct from result_a), 14.29, '(a) discount_pct = (350-300)/350*100 redondeado');
select is((select request_id from result_a), null::uuid, '(a) request_id es NULL cuando se aplica directo');
select is(
  (select total_amount_bs from public.reservations where id = (select r1 from fixture_rooms)),
  600.00,
  '(a) total_amount_bs pasa a 300 x 2 noches = 600'
);
select is(
  (select previous_rate_bs from public.rate_overrides where reservation_id = (select r1 from fixture_rooms)),
  350.00,
  '(a) rate_overrides.previous_rate_bs queda en el precio de lista (350)'
);
select is(
  (select new_rate_bs from public.rate_overrides where reservation_id = (select r1 from fixture_rooms)),
  300.00,
  '(a) rate_overrides.new_rate_bs queda en el precio aplicado (300)'
);
select is(
  (select count(*)::int from public.rate_discount_requests where reservation_id = (select r1 from fixture_rooms)),
  0,
  '(a) sin solicitud (ni pending ni approved) cuando el descuento entra directo'
);

-- ---------------------------------------------------------------------
-- (b) CARACTERIZACIÓN: each_stay, reception, descuento >20% -> NO se
--     aplica, queda 'pending'. Total sin cambios, sin rate_overrides.
-- ---------------------------------------------------------------------
create temp table result_b as
  select * from public.apply_rate_change(
    (select r2 from fixture_rooms),
    (select room_type_id from public.reservations where id = (select r2 from fixture_rooms)),
    350, 2, 200, 'Caracterización: descuento grande, reception'
  );

select is((select applied from result_b), false, '(b) descuento >20% de reception: applied=false');
select is((select discount_pct from result_b), 42.86, '(b) discount_pct = (350-200)/350*100 redondeado');
select is(
  (select total_amount_bs from public.reservations where id = (select r2 from fixture_rooms)),
  700.00,
  '(b) total_amount_bs NO cambia (sigue en 350x2=700) mientras está pending'
);
select is(
  (select status from public.rate_discount_requests where id = (select request_id from result_b)),
  'pending',
  '(b) la solicitud queda pending'
);
select ok(
  (select resolved_by is null and resolved_at is null and applied_at is null
     from public.rate_discount_requests where id = (select request_id from result_b)),
  '(b) resolved_by/resolved_at/applied_at quedan sin setear mientras está pending'
);
select is(
  (select count(*)::int from public.rate_overrides where reservation_id = (select r2 from fixture_rooms)),
  0,
  '(b) rate_overrides NO se toca mientras la solicitud está pending'
);

-- ---------------------------------------------------------------------
-- (c) CARACTERIZACIÓN: each_stay, reception_admin, descuento >20% -> se
--     aplica directo (bypass de rol), auto-aprobado y auditado.
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true); -- reception_admin

create temp table result_c as
  select * from public.apply_rate_change(
    (select r3 from fixture_rooms),
    (select room_type_id from public.reservations where id = (select r3 from fixture_rooms)),
    350, 2, 200, 'Caracterización: descuento grande, reception_admin'
  );

select is((select applied from result_c), true, '(c) descuento >20% de reception_admin: applied=true (bypass de rol)');
select is(
  (select total_amount_bs from public.reservations where id = (select r3 from fixture_rooms)),
  400.00,
  '(c) total_amount_bs pasa a 200 x 2 noches = 400'
);
select is(
  (select count(*)::int from public.rate_overrides where reservation_id = (select r3 from fixture_rooms)),
  1,
  '(c) queda auditado en rate_overrides'
);
select is(
  (select status from public.rate_discount_requests where id = (select request_id from result_c)),
  'approved',
  '(c) la solicitud queda auto-aprobada, nunca pending'
);
select ok(
  (select resolved_by is not null and resolved_at is not null and applied_at is not null
     from public.rate_discount_requests where id = (select request_id from result_c)),
  '(c) resolved_by/resolved_at/applied_at quedan seteados en el alta automática'
);

-- ---------------------------------------------------------------------
-- (d) CARACTERIZACIÓN: approve_rate_discount_request sobre la solicitud
--     pending de (b), aprobada por reception_admin.
-- ---------------------------------------------------------------------
create temp table result_d as
  select * from public.approve_rate_discount_request((select request_id from result_b));

select is(
  (select total_amount_bs from result_d),
  400.00,
  '(d) approve_rate_discount_request actualiza el total a 200x2=400'
);
select is(
  (select status from public.rate_discount_requests where id = (select request_id from result_b)),
  'approved',
  '(d) la solicitud queda approved'
);
select is(
  (select count(*)::int from public.rate_overrides where reservation_id = (select r2 from fixture_rooms)),
  1,
  '(d) queda auditada en rate_overrides al aprobar'
);

-- ---------------------------------------------------------------------
-- (e) CARACTERIZACIÓN, llamador indirecto: override_reservation_rate
--     (usado por RoomPanel/ArrivalsList) delega en apply_rate_change --
--     sigue funcionando igual para un each_stay sin contrato.
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

select lives_ok(
  $$ select public.override_reservation_rate(
       (select r4 from fixture_rooms), 300, 'Caracterización: llamador indirecto'
     ) $$,
  '(e) override_reservation_rate (llamador indirecto de apply_rate_change) sigue funcionando'
);
select is(
  (select total_amount_bs from public.reservations where id = (select r4 from fixture_rooms)),
  600.00,
  '(e) el total se actualiza igual que si se llamara apply_rate_change directo (300x2=600)'
);

select * from finish();
rollback;
