-- =====================================================================
-- Cambios de estadía (modify_stay_dates, change_room, reschedule_
-- reservation) sobre reservas institucionales con contrato ya congelado
-- (change: group-billing, stage 6, Slice 3b, branch
-- feat/booking-13c-client-stay-changes).
--
-- Regla (decisions-round-5, sdd/group-billing):
--   - EXTENDER (modify_stay_dates con salida más tarde, o
--     reschedule_reservation que cambia la cantidad de noches) -> se
--     rechaza. "Para extender una reserva institucional creá una
--     reserva nueva."
--   - ACORTAR (modify_stay_dates con salida más temprana), change_room,
--     y reschedule_reservation manteniendo la misma cantidad de noches
--     -> permitido. El contrato (booking_balances) nunca se toca, y
--     total_amount_bs de la reserva NO cambia (ver nota de diseño en la
--     migración 20260911116000 sobre change_room: deja > 1 tramo sin
--     reajustar, documentado, no pierde plata porque el folio siempre
--     lee total_amount_bs directo).
--
-- PRIMERA MITAD: CARACTERIZACIÓN de reschedule_reservation y change_room
-- para reservas each_stay tal como se comportan HOY -- deben pasar SIN
-- tocar una línea de SQL, y siguen pasando igual después de la
-- migración (el candado nuevo sólo mira reservas con contract_agreed).
-- modify_stay_dates para each_stay ya está cubierto por
-- 01_tramos_de_estadia.sql -- no se duplica acá.
--
-- SEGUNDA MITAD: pruebas RED del candado nuevo sobre reservas
-- institucionales congeladas -- deben FALLAR contra el código actual
-- (sin este branch) y pasar recién después de la migración
-- 20260911116000_group_billing_client_stay_changes.sql.
--
-- FIXTURE relativa a current_date para los casos que pasan por
-- modify_stay_dates/change_room (exigen status='checked_in' y
-- modify_stay_dates valida contra current_date, mismo patrón que
-- 01_tramos_de_estadia.sql -- ver su cabecera). Los casos de sólo
-- reschedule_reservation (no valida contra current_date) usan fechas
-- futuras fijas, mismo patrón que 20_group_billing_rate_lock.sql.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(29);

create or replace function pg_temp.snap_res(p_id uuid) returns text language sql as $$
  select row(
    (select total_amount_bs from public.reservations where id = p_id),
    (select check_in_date from public.reservations where id = p_id),
    (select check_out_date from public.reservations where id = p_id),
    (select room_id from public.reservations where id = p_id),
    (select count(*)::int from public.stay_segments where reservation_id = p_id),
    (select coalesce(sum(bb.amount_bs) filter (where bb.event_type = 'contract_agreed'), 0)
       from public.booking_balances bb
       join public.reservations r on r.booking_id = bb.booking_id
       where r.id = p_id),
    (select count(*)::int from public.booking_balances bb
       join public.reservations r on r.booking_id = bb.booking_id
       where r.id = p_id),
    (select count(*)::int from public.reservation_reschedules where reservation_id = p_id)
  )::text
$$;

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

-- =======================================================================
-- Fixtures institucionales congeladas (reception_admin, contrato con
-- contract_agreed insertado al crear). Tarifa pactada 300/noche, 4
-- noches -> 1200, para que las divisiones den exactas en cada caso.
-- =======================================================================
select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true); -- reception_admin

do $$
declare v_account uuid;
begin
  insert into public.receivable_accounts (name, kind) values ('Fixture Client Stay Changes SA', 'empresa')
    returning id into v_account;
  create temp table fixture_account as select v_account as account_id;
end $$;

-- (frozen extend): checked_in, 4 noches @300 = 1200, current_date-3..current_date+1.
do $$
declare v_room uuid; v_room_type uuid; v_res uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_room_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 350
    and o.room_id not in (select room_id from public.reservations)
  limit 1;
  v_res := public.create_reservation(
    v_room, v_room_type, 'Frozen', 'Extiende', '70000204', 'frozen.extiende@fixture.test',
    current_date - 3, current_date + 1, 1, 'phone', 300, 'Tarifa institucional pactada', true,
    'client', 'room', null, (select account_id from fixture_account), null, null, null, null, false, null
  );
  update public.reservations set status = 'checked_in' where id = v_res;
  create temp table fixture_frozen_extend as select v_res as reservation_id, v_room as room_id;
end $$;

-- (frozen shorten): mismo esquema, room propio.
do $$
declare v_room uuid; v_room_type uuid; v_res uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_room_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 350
    and o.room_id not in (select room_id from public.reservations)
  limit 1;
  v_res := public.create_reservation(
    v_room, v_room_type, 'Frozen', 'Acorta', '70000205', 'frozen.acorta@fixture.test',
    current_date - 3, current_date + 1, 1, 'phone', 300, 'Tarifa institucional pactada', true,
    'client', 'room', null, (select account_id from fixture_account), null, null, null, null, false, null
  );
  update public.reservations set status = 'checked_in' where id = v_res;
  create temp table fixture_frozen_shorten as select v_res as reservation_id, v_room as room_id;
end $$;

-- (frozen change_room): room propio y room destino, ambos "Doble
-- Estándar" (pool separado de "Simple Estándar" -- NOTA: "Simple
-- Estándar" y "Matrimonial" resultaron ser, en los datos locales, en
-- gran parte las MISMAS habitaciones físicas con dos fichas de precio
-- (room_type_options duplicado) -- usar "Matrimonial" acá agotaba el
-- mismo pool ya consumido por los fixtures Simple Estándar de arriba.
-- "Doble Estándar" es un pool realmente disjunto). La tarifa pactada
-- (300) es independiente del precio de lista de cualquiera de los dos
-- tipos.
do $$
declare v_room uuid; v_room_type uuid; v_res uuid; v_new_room uuid; v_new_room_type uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_room_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.name = 'Doble Estándar'
    and o.room_id not in (select room_id from public.reservations)
  limit 1;
  v_res := public.create_reservation(
    v_room, v_room_type, 'Frozen', 'Cambia Cuarto', '70000206', 'frozen.cambiocuarto@fixture.test',
    current_date - 3, current_date + 1, 1, 'phone', 300, 'Tarifa institucional pactada', true,
    'client', 'room', null, (select account_id from fixture_account), null, null, null, null, false, null
  );
  update public.reservations set status = 'checked_in' where id = v_res;

  select o.room_id, o.room_type_id into v_new_room, v_new_room_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.name = 'Doble Estándar'
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  create temp table fixture_frozen_change_room as
    select v_res as reservation_id, v_room as room_id, v_new_room as new_room_id, v_new_room_type as new_room_type_id;
end $$;

-- (frozen reschedule): confirmed (sin check-in), fechas futuras fijas, 4
-- noches @300=1200. "Doble Estándar" también acá (mismo motivo de pool
-- disjunto explicado arriba).
do $$
declare v_room uuid; v_room_type uuid; v_res uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_room_type
  from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
  where rt.name = 'Doble Estándar'
    and o.room_id not in (select room_id from public.reservations)
  limit 1;
  v_res := public.create_reservation(
    v_room, v_room_type, 'Frozen', 'Reprograma', '70000207', 'frozen.reprograma@fixture.test',
    '2027-09-01', '2027-09-05', 1, 'phone', 300, 'Tarifa institucional pactada', true,
    'client', 'room', null, (select account_id from fixture_account), null, null, null, null, false, null
  );
  create temp table fixture_frozen_reschedule as select v_res as reservation_id;
end $$;

-- ---------------------------------------------------------------------
-- (9)-(10, RED) modify_stay_dates EXTENDER sobre reserva congelada: se
--     rechaza, nada cambia.
-- ---------------------------------------------------------------------
create temp table snap_9 as select pg_temp.snap_res((select reservation_id from fixture_frozen_extend)) as s;

select throws_matching(
  format($$ select public.modify_stay_dates(%L, %L, 300, 'Quiere quedarse más') $$,
    (select room_id from fixture_frozen_extend),
    (select check_out_date + 2 from public.reservations where id = (select reservation_id from fixture_frozen_extend))),
  'Para extender una reserva institucional creá una reserva nueva',
  '(9) modify_stay_dates rechaza extender una reserva institucional congelada'
);
select is(
  pg_temp.snap_res((select reservation_id from fixture_frozen_extend)),
  (select s from snap_9),
  '(10) el intento rechazado no modifica reserva/tramos/contrato/booking_balances'
);

-- ---------------------------------------------------------------------
-- (11)-(16, GREEN) modify_stay_dates ACORTAR sobre reserva congelada: se
--     permite, el contrato/total NO cambian, sólo se ajustan fechas y
--     tramos operativos.
-- ---------------------------------------------------------------------
select is(
  public.modify_stay_dates(
    (select room_id from fixture_frozen_shorten),
    (select check_out_date - 1 from public.reservations where id = (select reservation_id from fixture_frozen_shorten)),
    null, 'Se va antes de lo pactado'
  ),
  1200.00,
  '(11) modify_stay_dates acortar en una reserva congelada devuelve el total SIN CAMBIOS (1200)'
);
select is(
  (select total_amount_bs from public.reservations where id = (select reservation_id from fixture_frozen_shorten)),
  1200.00,
  '(12) total_amount_bs de la reserva queda igual (1200) aunque se acorten noches'
);
-- (la salida efectivamente se movió 1 día antes -- 3 noches en vez de 4)
select is(
  (select (check_out_date - check_in_date)::int from public.reservations where id = (select reservation_id from fixture_frozen_shorten)),
  3,
  '(13) la estadía queda en 3 noches tras acortar'
);
select is(
  (select count(*)::int from public.stay_segments where reservation_id = (select reservation_id from fixture_frozen_shorten)),
  1,
  '(14) sigue habiendo un único tramo (nunca se abrió un segundo, EXTENDER está bloqueado)'
);
select is(
  (select rate_bs from public.stay_segments where reservation_id = (select reservation_id from fixture_frozen_shorten)),
  400.00,
  '(15) el tramo único se reajusta a 1200/3=400 por el propio trigger -- sigue sumando el total'
);
select is(
  pg_temp.snap_res((select reservation_id from fixture_frozen_shorten)),
  (select row(
    1200.00::numeric,
    (select check_in_date from public.reservations where id = (select reservation_id from fixture_frozen_shorten)),
    (select check_out_date from public.reservations where id = (select reservation_id from fixture_frozen_shorten)),
    (select room_id from fixture_frozen_shorten),
    1,
    1200.00::numeric,
    1,
    0
  )::text),
  '(16) el contrato (booking_balances) y su monto quedan exactamente iguales tras acortar'
);

-- ---------------------------------------------------------------------
-- (17)-(22, GREEN) change_room sobre reserva congelada: se permite, el
--     contrato/total NO cambian, aunque la tarifa nueva pasada sea
--     distinta.
-- ---------------------------------------------------------------------
select is(
  public.change_room(
    (select room_id from fixture_frozen_change_room),
    (select new_room_id from fixture_frozen_change_room),
    (select new_room_type_id from fixture_frozen_change_room),
    999, null, 'Cambia de habitación, contrato congelado'
  ),
  1200.00,
  '(17) change_room en una reserva congelada devuelve el total SIN CAMBIOS (1200), ignora la tarifa nueva'
);
select is(
  (select total_amount_bs from public.reservations where id = (select reservation_id from fixture_frozen_change_room)),
  1200.00,
  '(18) total_amount_bs de la reserva queda igual (1200) tras el cambio de habitación'
);
select is(
  (select room_id from public.reservations where id = (select reservation_id from fixture_frozen_change_room)),
  (select new_room_id from fixture_frozen_change_room),
  '(19) la reserva queda apuntando a la habitación nueva'
);
select is(
  (select count(*)::int from public.stay_segments where reservation_id = (select reservation_id from fixture_frozen_change_room)),
  2,
  '(20) quedan 2 tramos (el viejo recortado + el nuevo) -- deuda documentada: su suma puede no calzar con el total'
);
select is(
  (select operational_status from public.rooms where id = (select room_id from fixture_frozen_change_room)),
  'dirty',
  '(21) la habitación vieja queda sucia'
);
select is(
  (select count(*)::int from public.booking_balances bb
     join public.reservations r on r.booking_id = bb.booking_id
     where r.id = (select reservation_id from fixture_frozen_change_room) and bb.event_type = 'contract_agreed'),
  1,
  '(22) el contrato sigue teniendo un único contract_agreed -- nunca se tocó'
);

-- ---------------------------------------------------------------------
-- (23)-(24, RED) reschedule_reservation con DISTINTA cantidad de noches
--     sobre reserva congelada: se rechaza, nada cambia.
-- ---------------------------------------------------------------------
create temp table snap_23 as select pg_temp.snap_res((select reservation_id from fixture_frozen_reschedule)) as s;

select throws_matching(
  $$ select public.reschedule_reservation(
       (select reservation_id from fixture_frozen_reschedule),
       '2027-09-01', '2027-09-08', 'Quiere sumar noches por reprogramación'
     ) $$,
  'Una reserva institucional solo puede moverse de fecha manteniendo la cantidad de noches',
  '(23) reschedule_reservation rechaza cambiar la cantidad de noches en una reserva congelada'
);
select is(
  pg_temp.snap_res((select reservation_id from fixture_frozen_reschedule)),
  (select s from snap_23),
  '(24) el intento rechazado no modifica reserva/contrato/reservation_reschedules'
);

-- ---------------------------------------------------------------------
-- (25)-(29, GREEN) reschedule_reservation manteniendo la MISMA cantidad
--     de noches sobre reserva congelada: se permite, contrato/total NO
--     cambian.
-- ---------------------------------------------------------------------
select is(
  (select (public.reschedule_reservation(
       (select reservation_id from fixture_frozen_reschedule),
       '2027-09-02', '2027-09-06', 'Se corre un día, mismas 4 noches'
     )).total_amount_bs),
  1200.00,
  '(25) reschedule_reservation manteniendo noches no cambia el total (sigue en 1200)'
);
select is(
  (select row(check_in_date, check_out_date) from public.reservations where id = (select reservation_id from fixture_frozen_reschedule)),
  row('2027-09-02'::date, '2027-09-06'::date),
  '(26) las fechas se actualizan igual que en una reserva each_stay'
);
select is(
  (select count(*)::int from public.booking_balances bb
     join public.reservations r on r.booking_id = bb.booking_id
     where r.id = (select reservation_id from fixture_frozen_reschedule) and bb.event_type = 'contract_agreed'),
  1,
  '(27) el contrato sigue teniendo un único contract_agreed tras reprogramar'
);
select is(
  (select amount_bs from public.booking_balances bb
     join public.reservations r on r.booking_id = bb.booking_id
     where r.id = (select reservation_id from fixture_frozen_reschedule) and bb.event_type = 'contract_agreed'),
  1200.00,
  '(28) el monto del contrato queda exactamente igual (1200)'
);
select is(
  (select count(*)::int from public.reservation_reschedules where reservation_id = (select reservation_id from fixture_frozen_reschedule)),
  1,
  '(29) reschedule_reservation audita el movimiento permitido igual que en each_stay'
);

select * from finish();
rollback;
