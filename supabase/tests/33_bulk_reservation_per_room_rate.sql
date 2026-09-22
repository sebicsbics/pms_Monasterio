-- =====================================================================
-- create_bulk_reservation: el precio pactado es una propiedad de CADA
-- habitación (`p_rooms[].rate_bs`), no de la reserva completa (change:
-- per-room-rate-in-bulk). Antes, un solo p_rate_bs booking-level se
-- comparaba contra el precio de lista de CADA habitación dentro del
-- loop, aplanando precios distintos de habitaciones distintas al mismo
-- valor (defecto real de sandbox: habitación 6 a 480 y habitación 7 a
-- 350, ambas terminaban en 400 con una sola entrada de tarifa).
--
-- Ver 20260922130000_bulk_reservation_per_room_rate.sql: reescritura de
-- SOLO EL CUERPO (misma firma de 18 parámetros, sin DROP). p_rate_bs se
-- conserva como FALLBACK para habitaciones sin `rate_bs` propio. p_reason
-- sigue siendo ÚNICO por alta (decisión de usuario): se graba igual en
-- la auditoría de cada habitación que difiera de su propio precio de
-- lista.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
select is(current_user_role(), 'root', 'fixture: sesión con rol root');

-- ---------------------------------------------------------------------
-- Fixtures propios: dos room_types NUEVOS a distinto precio de lista y
-- dos habitaciones físicas NUEVAS, una de cada tipo (nunca "la primera
-- disponible" -- se seedean explícitamente).
-- ---------------------------------------------------------------------
do $$
declare
  v_type_a uuid; v_type_b uuid; v_room_a uuid; v_room_b uuid; v_account uuid;
begin
  insert into public.room_types (name, base_price_bs, max_occupancy)
  values ('Fixture PRR Tipo A', 480, 2) returning id into v_type_a;
  insert into public.room_types (name, base_price_bs, max_occupancy)
  values ('Fixture PRR Tipo B', 350, 1) returning id into v_type_b;

  insert into public.rooms (room_number, floor, room_type_id, operational_status)
  values ('PRR-A', 9, v_type_a, 'available') returning id into v_room_a;
  insert into public.room_type_options (room_id, room_type_id) values (v_room_a, v_type_a);

  insert into public.rooms (room_number, floor, room_type_id, operational_status)
  values ('PRR-B', 9, v_type_b, 'available') returning id into v_room_b;
  insert into public.room_type_options (room_id, room_type_id) values (v_room_b, v_type_b);

  insert into public.receivable_accounts (name, kind) values ('Fixture PRR Cuenta', 'empresa')
    returning id into v_account;

  create temp table fixture_prr as
    select v_room_a as room_a, v_type_a as type_a, v_room_b as room_b, v_type_b as type_b,
           v_account as account_id;
end $$;

-- ---------------------------------------------------------------------
-- (1) EL CASO DECISIVO: dos habitaciones con precio de LISTA distinto
--     (480 y 350), cada una con un precio PACTADO distinto (400 y 300),
--     un solo p_reason compartido -> cada reserva queda en su propio
--     precio (NO aplanadas a un valor común) y cada una queda auditada
--     con el MISMO motivo compartido.
-- ---------------------------------------------------------------------
do $$
declare
  v_room_a uuid; v_type_a uuid; v_room_b uuid; v_type_b uuid; v_account uuid;
  v_result jsonb; v_res_a uuid; v_res_b uuid; v_booking uuid;
begin
  select room_a, type_a, room_b, type_b, account_id
    into v_room_a, v_type_a, v_room_b, v_type_b, v_account
  from fixture_prr;

  v_result := public.create_bulk_reservation(
    p_rooms => jsonb_build_array(
      jsonb_build_object('room_id', v_room_a, 'room_type_id', v_type_a, 'num_guests', 2, 'rate_bs', 400),
      jsonb_build_object('room_id', v_room_b, 'room_type_id', v_type_b, 'num_guests', 1, 'rate_bs', 300)
    ),
    p_first_name => 'Precio', p_last_name => 'PorHabitacion', p_phone => '70000040', p_email => null,
    p_check_in => '2035-01-01', p_check_out => '2035-01-03', p_method => 'phone',
    p_reason => 'Convenio institucional negociado',
    p_payer_mode => 'client', p_rate_mode => 'room', p_receivable_account_id => v_account
  );
  v_res_a := ((v_result->'created')->>0)::uuid;
  v_res_b := ((v_result->'created')->>1)::uuid;
  select booking_id into v_booking from public.reservations where id = v_res_a;

  create temp table fixture_decisive as
    select v_res_a as reservation_a, v_res_b as reservation_b, v_booking as booking_id;
end $$;

select is(
  (select total_amount_bs from public.reservations where id = (select reservation_a from fixture_decisive)),
  800.00, 'habitación A (lista 480, pactado 400) x 2 noches = 800, NO aplanada al valor de la otra habitación'
);
select is(
  (select total_amount_bs from public.reservations where id = (select reservation_b from fixture_decisive)),
  600.00, 'habitación B (lista 350, pactado 300) x 2 noches = 600, precio propio conservado'
);
select is(
  (select count(*)::int from public.rate_overrides
    where reservation_id = (select reservation_a from fixture_decisive)
      and previous_rate_bs = 480 and new_rate_bs = 400),
  1, 'habitación A auditada con SU PROPIO precio de lista (480) como previo'
);
select is(
  (select count(*)::int from public.rate_overrides
    where reservation_id = (select reservation_b from fixture_decisive)
      and previous_rate_bs = 350 and new_rate_bs = 300),
  1, 'habitación B auditada con SU PROPIO precio de lista (350) como previo'
);
select is(
  (select reason from public.rate_overrides
    where reservation_id = (select reservation_a from fixture_decisive)),
  'Convenio institucional negociado', 'habitación A: el motivo compartido queda auditado'
);
select is(
  (select reason from public.rate_overrides
    where reservation_id = (select reservation_b from fixture_decisive)),
  'Convenio institucional negociado', 'habitación B: el MISMO motivo compartido queda auditado (un solo p_reason)'
);
select is(
  (select amount_bs from public.booking_balances where booking_id = (select booking_id from fixture_decisive)),
  1400.00, 'contract_agreed = 800 + 600 = 1400, cada habitación con su propio precio pactado'
);

-- ---------------------------------------------------------------------
-- (2) Fallback: una habitación SIN rate_bs propio cae al p_rate_bs
--     booking-level; la otra, CON rate_bs propio, lo ignora.
-- ---------------------------------------------------------------------
do $$
declare
  v_room_a uuid; v_type_a uuid; v_room_b uuid; v_type_b uuid; v_account uuid;
  v_result jsonb; v_res_a uuid; v_res_b uuid;
begin
  select room_a, type_a, account_id into v_room_a, v_type_a, v_account from fixture_prr;
  -- habitación B nueva (distinta a la del escenario 1, ya reservada) --
  -- se crea una tercera físicamente nueva para no chocar con fechas.
  insert into public.room_types (name, base_price_bs, max_occupancy)
  values ('Fixture PRR Tipo C', 350, 1) returning id into v_type_b;
  insert into public.rooms (room_number, floor, room_type_id, operational_status)
  values ('PRR-C', 9, v_type_b, 'available') returning id into v_room_b;
  insert into public.room_type_options (room_id, room_type_id) values (v_room_b, v_type_b);

  v_result := public.create_bulk_reservation(
    p_rooms => jsonb_build_array(
      jsonb_build_object('room_id', v_room_a, 'room_type_id', v_type_a, 'num_guests', 2, 'rate_bs', 420),
      jsonb_build_object('room_id', v_room_b, 'room_type_id', v_type_b, 'num_guests', 1)
    ),
    p_first_name => 'Fallback', p_last_name => 'BookingLevel', p_phone => '70000041', p_email => null,
    p_check_in => '2035-02-01', p_check_out => '2035-02-03', p_method => 'phone',
    p_rate_bs => 300, p_reason => 'Fallback booking-level',
    p_payer_mode => 'client', p_rate_mode => 'room', p_receivable_account_id => v_account
  );
  v_res_a := ((v_result->'created')->>0)::uuid;
  v_res_b := ((v_result->'created')->>1)::uuid;

  create temp table fixture_fallback as select v_res_a as reservation_a, v_res_b as reservation_b;
end $$;

select is(
  (select total_amount_bs from public.reservations where id = (select reservation_a from fixture_fallback)),
  840.00, 'habitación con rate_bs propio (420) IGNORA el fallback booking-level: 420x2=840'
);
select is(
  (select total_amount_bs from public.reservations where id = (select reservation_b from fixture_fallback)),
  600.00, 'habitación SIN rate_bs propio cae al fallback p_rate_bs booking-level (300x2=600)'
);

-- ---------------------------------------------------------------------
-- (3) ACL/prosecdef/proconfig intactos tras el body-only rewrite.
-- ---------------------------------------------------------------------
select ok(
  (select prosecdef from pg_proc where proname = 'create_bulk_reservation'),
  'create_bulk_reservation sigue siendo SECURITY DEFINER'
);
select is(
  (select proconfig from pg_proc where proname = 'create_bulk_reservation')::text,
  '{search_path=public}',
  'create_bulk_reservation conserva su SET search_path'
);

select * from finish();
rollback;
