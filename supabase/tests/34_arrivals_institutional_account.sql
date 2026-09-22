-- =====================================================================
-- arrivals(): la reserva institucional (payer_mode='client') trae la
-- cuenta por cobrar (account_name/account_kind) para que el check-in no
-- obligue a recepción a retipear la agencia/empresa que la reserva ya
-- conoce (change: fix/institutional-ui-coherence). Cubre las DOS
-- direcciones: institucional CON cuenta, y each_stay SIN cuenta.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true); -- root

-- ---------------------------------------------------------------------
-- Fixtures propios: un room_type + dos habitaciones NUEVAS, nunca "la
-- primera disponible".
-- ---------------------------------------------------------------------
do $$
declare
  v_type uuid; v_room_client uuid; v_room_each uuid; v_account uuid;
begin
  insert into public.room_types (name, base_price_bs, max_occupancy)
  values ('Fixture Arrivals Account', 300, 2) returning id into v_type;

  insert into public.rooms (room_number, floor, room_type_id, operational_status)
  values ('9871', 9, v_type, 'available') returning id into v_room_client;
  insert into public.room_type_options (room_id, room_type_id) values (v_room_client, v_type);

  insert into public.rooms (room_number, floor, room_type_id, operational_status)
  values ('9872', 9, v_type, 'available') returning id into v_room_each;
  insert into public.room_type_options (room_id, room_type_id) values (v_room_each, v_type);

  insert into public.receivable_accounts (name, kind)
  values ('Fixture Arrivals Agencia', 'agencia') returning id into v_account;

  create temp table fixture_arrivals_account as
  select v_type as room_type_id, v_room_client as room_client, v_room_each as room_each,
    v_account as account_id;
end $$;

-- ---------------------------------------------------------------------
-- (a) Reserva institucional con cuenta -> arrivals() trae el nombre y
--     el tipo de la cuenta.
-- ---------------------------------------------------------------------
do $$
declare
  v_res uuid;
begin
  v_res := public.create_reservation(
    (select room_client from fixture_arrivals_account),
    (select room_type_id from fixture_arrivals_account),
    'Fixture', 'Cliente Institucional', '70399001', 'aa.client@fixture.test',
    '2027-09-01', '2027-09-03', 2, 'phone', null, null, true,
    'client', 'room', null, (select account_id from fixture_arrivals_account),
    null, null, null, null, false, null
  );
  create temp table fixture_arrivals_res_client as select v_res as reservation_id;
end $$;

-- ---------------------------------------------------------------------
-- (b) Reserva each_stay normal, sin cuenta -> arrivals() NO debe traer
--     ningún nombre de cuenta (evita el falso positivo de la dirección
--     institucional colando datos a la reserva normal).
-- ---------------------------------------------------------------------
do $$
declare
  v_res uuid;
begin
  v_res := public.create_reservation(
    (select room_each from fixture_arrivals_account),
    (select room_type_id from fixture_arrivals_account),
    'Fixture', 'Huesped Normal', '70399002', 'aa.each@fixture.test',
    '2027-09-01', '2027-09-03', 2, 'phone', null, null, true
  );
  create temp table fixture_arrivals_res_each as select v_res as reservation_id;
end $$;

select is(
  (select account_name from public.arrivals('2027-09-01', '2027-09-01')
    where reservation_id = (select reservation_id from fixture_arrivals_res_client)),
  'Fixture Arrivals Agencia',
  '(a1) la reserva institucional trae el nombre de su cuenta por cobrar'
);
select is(
  (select account_kind from public.arrivals('2027-09-01', '2027-09-01')
    where reservation_id = (select reservation_id from fixture_arrivals_res_client)),
  'agencia',
  '(a2) ... y el tipo de cuenta ("agencia")'
);
select is(
  (select account_name from public.arrivals('2027-09-01', '2027-09-01')
    where reservation_id = (select reservation_id from fixture_arrivals_res_each)),
  null,
  '(b1) la reserva each_stay no trae nombre de cuenta'
);
select is(
  (select account_kind from public.arrivals('2027-09-01', '2027-09-01')
    where reservation_id = (select reservation_id from fixture_arrivals_res_each)),
  null,
  '(b2) ... ni tipo de cuenta'
);

select * from finish();
rollback;
