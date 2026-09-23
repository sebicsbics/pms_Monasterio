-- =====================================================================
-- list_reservations_brief(): el selector de "Registrar anticipo" no debe
-- ofrecer reservas de bookings institucionales (payer_mode = 'client'),
-- porque record_anticipo ya las rechaza (spec R6.4, feat/booking-17). El
-- anticipo institucional va por record_booking_advance / "Grupos e
-- Instituciones" (feat/booking-14, feat/booking-24). Cubre las DOS
-- direcciones: institucional AUSENTE, each_stay PRESENTE. Además, prueba
-- que el guard de record_anticipo sigue vivo si se lo llama directo
-- (defensa en profundidad -- la UI no reemplaza a la base) (change:
-- fix/anticipos-exclude-institutional).
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true); -- root

-- ---------------------------------------------------------------------
-- Fixtures propios: room_type + dos habitaciones nuevas, una reserva
-- institucional (payer_mode='client') y una each_stay normal.
-- ---------------------------------------------------------------------
do $$
declare
  v_type uuid; v_room_client uuid; v_room_each uuid; v_account uuid;
begin
  insert into public.room_types (name, base_price_bs, max_occupancy)
  values ('Fixture Brief Excludes Client', 300, 2) returning id into v_type;

  insert into public.rooms (room_number, floor, room_type_id, operational_status)
  values ('9881', 9, v_type, 'available') returning id into v_room_client;
  insert into public.room_type_options (room_id, room_type_id) values (v_room_client, v_type);

  insert into public.rooms (room_number, floor, room_type_id, operational_status)
  values ('9882', 9, v_type, 'available') returning id into v_room_each;
  insert into public.room_type_options (room_id, room_type_id) values (v_room_each, v_type);

  insert into public.receivable_accounts (name, kind)
  values ('Fixture Brief Excludes Client Agencia', 'agencia') returning id into v_account;

  create temp table fixture_brief_excludes_client as
  select v_type as room_type_id, v_room_client as room_client, v_room_each as room_each,
    v_account as account_id;
end $$;

do $$
declare
  v_res uuid;
begin
  v_res := public.create_reservation(
    (select room_client from fixture_brief_excludes_client),
    (select room_type_id from fixture_brief_excludes_client),
    'Fixture', 'Institucional Brief', '70399101', 'brief.client@fixture.test',
    '2027-09-10', '2027-09-12', 2, 'phone', null, null, true,
    'client', 'room', null, (select account_id from fixture_brief_excludes_client),
    null, null, null, null, false, null
  );
  create temp table fixture_brief_res_client as select v_res as reservation_id;
end $$;

do $$
declare
  v_res uuid;
begin
  v_res := public.create_reservation(
    (select room_each from fixture_brief_excludes_client),
    (select room_type_id from fixture_brief_excludes_client),
    'Fixture', 'Each Stay Brief', '70399102', 'brief.each@fixture.test',
    '2027-09-10', '2027-09-12', 2, 'phone', null, null, true
  );
  create temp table fixture_brief_res_each as select v_res as reservation_id;
end $$;

-- (1) La reserva institucional NO aparece en list_reservations_brief().
select is(
  (select count(*)::int from public.list_reservations_brief()
    where id = (select reservation_id from fixture_brief_res_client)),
  0,
  '(1) la reserva institucional (payer_mode=client) no aparece en list_reservations_brief()'
);

-- (2) La reserva each_stay SIGUE apareciendo (no vaciamos la lista entera).
select is(
  (select count(*)::int from public.list_reservations_brief()
    where id = (select reservation_id from fixture_brief_res_each)),
  1,
  '(2) la reserva each_stay sigue apareciendo en list_reservations_brief()'
);

-- (3) Defensa en profundidad: record_anticipo sigue rechazando la reserva
-- institucional si se la llama directo, aunque la UI ya no la ofrezca.
select throws_ok(
  $$ select public.record_anticipo(
    (select reservation_id from fixture_brief_res_client),
    100, 'EFECTIVO', null
  ) $$,
  'Las reservas institucionales no usan anticipos por habitación; usá el adelanto de grupo',
  '(3) record_anticipo sigue rechazando anticipos por habitación en reservas institucionales'
);

select * from finish();
rollback;
