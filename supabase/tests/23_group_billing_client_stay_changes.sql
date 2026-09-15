-- =====================================================================
-- CARACTERIZACIÓN de reschedule_reservation y change_room para reservas
-- each_stay, tal como se comportan HOY -- antes de agregar el candado de
-- contrato institucional congelado (change: group-billing, stage 6,
-- Slice 3b, branch feat/booking-13c-client-stay-changes). Deben pasar
-- SIN tocar una línea de SQL, y siguen pasando igual después de la
-- migración que sigue (el candado nuevo sólo mira reservas con
-- contract_agreed). modify_stay_dates para each_stay ya está cubierto
-- por 01_tramos_de_estadia.sql -- no se duplica acá.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

-- ---------------------------------------------------------------------
-- CARACTERIZACIÓN: fixtures each_stay (reception), tarifa fija para que
-- las cuentas sean exactas (350/noche, sin resto en la división).
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

do $$
declare v_room uuid; v_room_type uuid; v_res uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_room_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 350
    and o.room_id not in (select room_id from public.reservations)
  limit 1;
  v_res := public.create_reservation(v_room, v_room_type, 'Caracter', 'Reschedule Extiende', '70000201',
    'char.reschedule.extiende@fixture.test', '2027-09-01', '2027-09-04', 1, 'phone', null, null, true);
  create temp table fixture_char_reschedule_extend as select v_res as reservation_id;
end $$;

do $$
declare v_room uuid; v_room_type uuid; v_res uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_room_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 350
    and o.room_id not in (select room_id from public.reservations)
  limit 1;
  v_res := public.create_reservation(v_room, v_room_type, 'Caracter', 'Reschedule Igual', '70000202',
    'char.reschedule.igual@fixture.test', '2027-09-01', '2027-09-04', 1, 'phone', null, null, true);
  create temp table fixture_char_reschedule_same as select v_res as reservation_id;
end $$;

-- change_room each_stay: entró hace 1 día, sale en 2 -- 3 noches @350.
do $$
declare v_room uuid; v_room_type uuid; v_res uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_room_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 350
    and o.room_id not in (select room_id from public.reservations)
  limit 1;
  v_res := public.create_reservation(v_room, v_room_type, 'Caracter', 'Change Room', '70000203',
    'char.changeroom@fixture.test', current_date - 1, current_date + 2, 1, 'phone', null, null, true);
  update public.reservations set status = 'checked_in' where id = v_res;
  create temp table fixture_char_change_room as select v_res as reservation_id, v_room as old_room_id;
end $$;

do $$
declare v_new_room uuid; v_new_room_type uuid;
begin
  select o.room_id, o.room_type_id into v_new_room, v_new_room_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.name = 'Doble Estándar'
    and o.room_id not in (select room_id from public.reservations)
  limit 1;
  create temp table fixture_char_change_room_target as select v_new_room as new_room_id, v_new_room_type as new_room_type_id;
end $$;

-- ---------------------------------------------------------------------
-- (1) CARACTERIZACIÓN: reschedule_reservation each_stay, cambia la
--     cantidad de noches (3 -> 5). Hoy se permite: el total se
--     recalcula manteniendo la tarifa por noche (350).
-- ---------------------------------------------------------------------
select lives_ok(
  $$ select public.reschedule_reservation(
       (select reservation_id from fixture_char_reschedule_extend),
       '2027-09-01', '2027-09-06', 'Caracterización: se queda más noches'
     ) $$,
  '(1) each_stay: reschedule_reservation con distinta cantidad de noches sigue permitido'
);
select is(
  (select total_amount_bs from public.reservations where id = (select reservation_id from fixture_char_reschedule_extend)),
  1750.00,
  '(2) each_stay: el total se recalcula a la misma tarifa por noche (350x5=1750)'
);
select is(
  (select count(*)::int from public.reservation_reschedules where reservation_id = (select reservation_id from fixture_char_reschedule_extend)),
  1,
  '(3) each_stay: reschedule_reservation audita el cambio en reservation_reschedules'
);

-- ---------------------------------------------------------------------
-- (4)-(5) CARACTERIZACIÓN: reschedule_reservation each_stay, misma
--     cantidad de noches (sólo se corre 1 día) -- el total no cambia.
-- ---------------------------------------------------------------------
select is(
  (select (public.reschedule_reservation(
       (select reservation_id from fixture_char_reschedule_same),
       '2027-09-02', '2027-09-05', 'Caracterización: se corre un día, mismas noches'
     )).total_amount_bs),
  1050.00,
  '(4) each_stay: reschedule_reservation manteniendo noches no cambia el total (350x3=1050)'
);
select is(
  (select row(check_in_date, check_out_date) from public.reservations where id = (select reservation_id from fixture_char_reschedule_same)),
  row('2027-09-02'::date, '2027-09-05'::date),
  '(5) each_stay: las fechas se actualizan igual aunque las noches no cambien'
);

-- ---------------------------------------------------------------------
-- (6)-(8) CARACTERIZACIÓN: change_room each_stay -- el total se
--     recalcula a partir de los tramos (1 noche vieja @350 + 2 noches
--     nuevas @400 = 1150), quedan 2 tramos.
-- ---------------------------------------------------------------------
select is(
  public.change_room(
    (select old_room_id from fixture_char_change_room),
    (select new_room_id from fixture_char_change_room_target),
    (select new_room_type_id from fixture_char_change_room_target),
    400, null, 'Caracterización: cambio de habitación'
  ),
  1150.00,
  '(6) each_stay: change_room recalcula el total con la tarifa nueva (350x1 + 400x2 = 1150)'
);
select is(
  (select room_id from public.reservations where id = (select reservation_id from fixture_char_change_room)),
  (select new_room_id from fixture_char_change_room_target),
  '(7) each_stay: change_room mueve la reserva a la habitación nueva'
);
select is(
  (select count(*)::int from public.stay_segments where reservation_id = (select reservation_id from fixture_char_change_room)),
  2,
  '(8) each_stay: change_room deja 2 tramos (el viejo recortado + el nuevo)'
);

select * from finish();
rollback;
