-- =====================================================================
-- Una persona no puede ocupar dos estadías activas que se solapen.
-- (change: reservation-booker-vs-guest, PR3).
--
-- reservation_guests gana stay_range (daterange, '[)') y active (bool),
-- mantenidos por triggers desde reservations, y un EXCLUDE USING gist
-- rechaza el solapamiento para la misma persona mientras ambas filas
-- estén activas (confirmed/checked_in). Cancelado/checked_out no bloquea.
--
-- NOTA sobre el mensaje al usuario: por presupuesto de tamaño de PR, esta
-- migración NO traduce la violación (SQLSTATE 23P01) a español en las RPCs
-- de alta/check-in/modify_stay_dates/change_room -- queda documentado como
-- deuda de una PR siguiente (ver apply-progress). Estos tests verifican
-- el rechazo a nivel de base (SQLSTATE 23P01 / mensaje del EXCLUDE).
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(18);

select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
select is(current_user_role(), 'root', 'fixture: sesión con rol root');

-- ---------------------------------------------------------------------
-- 0) Esquema: columnas, extensión, constraint.
-- ---------------------------------------------------------------------
select has_column('reservation_guests', 'stay_range', 'reservation_guests.stay_range existe');
select has_column('reservation_guests', 'active', 'reservation_guests.active existe');
select ok(
  exists (select 1 from pg_extension where extname = 'btree_gist'),
  'btree_gist instalada'
);
select ok(
  exists (
    select 1 from pg_constraint
    where conname = 'reservation_guests_no_overlap'
      and conrelid = 'public.reservation_guests'::regclass
  ),
  'existe el EXCLUDE reservation_guests_no_overlap'
);

-- ---------------------------------------------------------------------
-- Fixture: dos habitaciones libres + dos personas.
-- ---------------------------------------------------------------------
-- DISTINCT ON (room_id), no GROUP BY: una habitación puede tener varios
-- room_type_id en room_type_options (varios tipos posibles para la misma
-- físicamente), y `group by room_id, room_type_id` + `order by room_id
-- limit 2` podía, quedando dos filas empatadas en room_id, devolver DOS
-- FILAS DE LA MISMA HABITACIÓN (mismo room_id, distinto room_type_id) en
-- vez de dos habitaciones distintas -- exactamente el bug que hacía
-- fallar 3.2 (modify_stay_dates) ~1 de cada 3 `db reset` (v_room_a y
-- v_room_b terminaban siendo la MISMA habitación física, así que
-- "extenderla hasta solaparse con la otra" no solapaba con nada ajeno).
-- DISTINCT ON + su propio ORDER BY (room_id, room_type_id) garantiza
-- UNA fila por room_id, siempre la de menor room_type_id -- determinista
-- entre resets.
create temp table rooms2 on commit drop as
select distinct on (o.room_id) o.room_id, o.room_type_id
from public.room_type_options o
join public.rooms r on r.id = o.room_id and r.operational_status = 'available'
order by o.room_id, o.room_type_id
limit 2;

do $$
declare
  v_room_a  uuid;
  v_type_a  uuid;
  v_room_b  uuid;
  v_type_b  uuid;
  v_person  uuid;
  v_res_a   uuid;
  v_res_b   uuid;
  v_booking uuid;
begin
  select room_id, room_type_id into v_room_a, v_type_a from rooms2 order by room_id limit 1;
  select room_id, room_type_id into v_room_b, v_type_b from rooms2 order by room_id offset 1 limit 1;

  insert into public.people (first_name, last_name) values ('Overlap', 'Persona')
    returning id into v_person;
  insert into public.guests (person_id) values (v_person);

  insert into public.bookings (contact_person_id) values (v_person)
    returning id into v_booking;

  insert into public.reservations (
    guest_id, room_id, room_type_id, check_in_date, check_out_date,
    status, booking_id, total_amount_bs
  ) values (
    v_person, v_room_a, v_type_a, '2026-10-01', '2026-10-05', 'confirmed', v_booking, 100
  ) returning id into v_res_a;
  insert into public.reservation_guests (reservation_id, person_id, role)
  values (v_res_a, v_person, 'holder');

  insert into public.reservations (
    guest_id, room_id, room_type_id, check_in_date, check_out_date,
    status, booking_id, total_amount_bs
  ) values (
    v_person, v_room_b, v_type_b, '2026-10-03', '2026-10-07', 'confirmed', v_booking, 100
  ) returning id into v_res_b;

  begin
    insert into public.reservation_guests (reservation_id, person_id, role)
    values (v_res_b, v_person, 'holder');
    raise exception 'NO_SE_RECHAZO';
  exception
    when exclusion_violation then
      perform set_config('overlap.test1', 'ok', true);
  end;
end $$;

select is(current_setting('overlap.test1', true), 'ok',
  '3.1: insertar la misma persona en dos estadías activas que se solapan es rechazado');

-- ---------------------------------------------------------------------
-- 3.4: cancelado/checked_out no bloquea el re-booking solapado.
-- ---------------------------------------------------------------------
do $$
declare
  v_room_a  uuid;
  v_type_a  uuid;
  v_room_b  uuid;
  v_type_b  uuid;
  v_person  uuid;
  v_res_a   uuid;
  v_res_b   uuid;
  v_booking uuid;
begin
  select room_id, room_type_id into v_room_a, v_type_a from rooms2 order by room_id limit 1;
  select room_id, room_type_id into v_room_b, v_type_b from rooms2 order by room_id offset 1 limit 1;

  insert into public.people (first_name, last_name) values ('Cancelada', 'Persona')
    returning id into v_person;
  insert into public.guests (person_id) values (v_person);
  insert into public.bookings (contact_person_id) values (v_person)
    returning id into v_booking;

  insert into public.reservations (
    guest_id, room_id, room_type_id, check_in_date, check_out_date,
    status, booking_id, total_amount_bs
  ) values (
    v_person, v_room_a, v_type_a, '2026-11-01', '2026-11-05', 'cancelled', v_booking, 100
  ) returning id into v_res_a;
  insert into public.reservation_guests (reservation_id, person_id, role)
  values (v_res_a, v_person, 'holder');

  -- Se solapa en fechas con la cancelada, pero como esa está inactiva no
  -- debe rechazarse.
  insert into public.reservations (
    guest_id, room_id, room_type_id, check_in_date, check_out_date,
    status, booking_id, total_amount_bs
  ) values (
    v_person, v_room_b, v_type_b, '2026-11-03', '2026-11-07', 'confirmed', v_booking, 100
  ) returning id into v_res_b;
  insert into public.reservation_guests (reservation_id, person_id, role)
  values (v_res_b, v_person, 'holder');

  perform set_config('overlap.test4', 'ok', true);
end $$;

select is(current_setting('overlap.test4', true), 'ok',
  '3.4: una estadía cancelada no bloquea otra que se solapa en fechas');

-- ---------------------------------------------------------------------
-- Back-to-back: checkout de una = check-in de la otra, permitido ('[)').
-- ---------------------------------------------------------------------
do $$
declare
  v_room_a  uuid;
  v_type_a  uuid;
  v_room_b  uuid;
  v_type_b  uuid;
  v_person  uuid;
  v_res_a   uuid;
  v_res_b   uuid;
  v_booking uuid;
begin
  select room_id, room_type_id into v_room_a, v_type_a from rooms2 order by room_id limit 1;
  select room_id, room_type_id into v_room_b, v_type_b from rooms2 order by room_id offset 1 limit 1;

  insert into public.people (first_name, last_name) values ('Backtoback', 'Persona')
    returning id into v_person;
  insert into public.guests (person_id) values (v_person);
  insert into public.bookings (contact_person_id) values (v_person)
    returning id into v_booking;

  insert into public.reservations (
    guest_id, room_id, room_type_id, check_in_date, check_out_date,
    status, booking_id, total_amount_bs
  ) values (
    v_person, v_room_a, v_type_a, '2026-12-01', '2026-12-05', 'confirmed', v_booking, 100
  ) returning id into v_res_a;
  insert into public.reservation_guests (reservation_id, person_id, role)
  values (v_res_a, v_person, 'holder');

  -- Empieza exactamente el día del checkout anterior.
  insert into public.reservations (
    guest_id, room_id, room_type_id, check_in_date, check_out_date,
    status, booking_id, total_amount_bs
  ) values (
    v_person, v_room_b, v_type_b, '2026-12-05', '2026-12-08', 'confirmed', v_booking, 100
  ) returning id into v_res_b;
  insert into public.reservation_guests (reservation_id, person_id, role)
  values (v_res_b, v_person, 'holder');

  perform set_config('overlap.backtoback', 'ok', true);
end $$;

select is(current_setting('overlap.backtoback', true), 'ok',
  'checkout de una estadía = check-in de la siguiente: permitido (rango semiabierto)');

-- ---------------------------------------------------------------------
-- Compañero en dos estadías solapadas también rechazado (no sólo holder).
-- ---------------------------------------------------------------------
do $$
declare
  v_room_a  uuid;
  v_type_a  uuid;
  v_room_b  uuid;
  v_type_b  uuid;
  v_holder1 uuid;
  v_holder2 uuid;
  v_companion uuid;
  v_res_a   uuid;
  v_res_b   uuid;
  v_booking uuid;
begin
  select room_id, room_type_id into v_room_a, v_type_a from rooms2 order by room_id limit 1;
  select room_id, room_type_id into v_room_b, v_type_b from rooms2 order by room_id offset 1 limit 1;

  insert into public.people (first_name, last_name) values ('Titular1', 'X') returning id into v_holder1;
  insert into public.guests (person_id) values (v_holder1);
  insert into public.people (first_name, last_name) values ('Titular2', 'X') returning id into v_holder2;
  insert into public.guests (person_id) values (v_holder2);
  insert into public.people (first_name, last_name) values ('Companion', 'Duplicado') returning id into v_companion;
  insert into public.guests (person_id) values (v_companion);

  insert into public.bookings (contact_person_id) values (v_holder1) returning id into v_booking;
  insert into public.reservations (
    guest_id, room_id, room_type_id, check_in_date, check_out_date, status, booking_id, total_amount_bs
  ) values (
    v_holder1, v_room_a, v_type_a, '2027-01-01', '2027-01-05', 'confirmed', v_booking, 100
  ) returning id into v_res_a;
  insert into public.reservation_guests (reservation_id, person_id, role) values (v_res_a, v_holder1, 'holder');
  insert into public.reservation_guests (reservation_id, person_id, role) values (v_res_a, v_companion, 'companion');

  insert into public.bookings (contact_person_id) values (v_holder2) returning id into v_booking;
  insert into public.reservations (
    guest_id, room_id, room_type_id, check_in_date, check_out_date, status, booking_id, total_amount_bs
  ) values (
    v_holder2, v_room_b, v_type_b, '2027-01-03', '2027-01-07', 'confirmed', v_booking, 100
  ) returning id into v_res_b;
  insert into public.reservation_guests (reservation_id, person_id, role) values (v_res_b, v_holder2, 'holder');

  begin
    insert into public.reservation_guests (reservation_id, person_id, role)
    values (v_res_b, v_companion, 'companion');
    raise exception 'NO_SE_RECHAZO';
  exception
    when exclusion_violation then
      perform set_config('overlap.companion', 'ok', true);
  end;
end $$;

select is(current_setting('overlap.companion', true), 'ok',
  'un acompañante en dos estadías activas que se solapan también es rechazado, no sólo el titular');

-- ---------------------------------------------------------------------
-- 3.2: modify_stay_dates (extend, reemplaza a extend_stay) crea un solapamiento nuevo -> rechazado por el
-- trigger de sync (recalc_reservation_total actualiza check_out_date).
-- ---------------------------------------------------------------------
do $$
declare
  v_room_a uuid; v_type_a uuid; v_room_b uuid; v_type_b uuid;
  v_person uuid; v_res_a uuid; v_res_b uuid; v_booking uuid;
begin
  select room_id, room_type_id into v_room_a, v_type_a from rooms2 order by room_id limit 1;
  select room_id, room_type_id into v_room_b, v_type_b from rooms2 order by room_id offset 1 limit 1;

  insert into public.people (first_name, last_name) values ('Extiende', 'Persona')
    returning id into v_person;
  insert into public.guests (person_id) values (v_person);
  insert into public.bookings (contact_person_id) values (v_person) returning id into v_booking;

  insert into public.reservations (
    guest_id, room_id, room_type_id, check_in_date, check_out_date, status, booking_id, total_amount_bs
  ) values (
    v_person, v_room_a, v_type_a, '2027-02-01', '2027-02-05', 'checked_in', v_booking, 100
  ) returning id into v_res_a;
  insert into public.reservation_guests (reservation_id, person_id, role) values (v_res_a, v_person, 'holder');

  insert into public.reservations (
    guest_id, room_id, room_type_id, check_in_date, check_out_date, status, booking_id, total_amount_bs
  ) values (
    v_person, v_room_b, v_type_b, '2027-02-06', '2027-02-09', 'checked_in', v_booking, 100
  ) returning id into v_res_b;
  insert into public.reservation_guests (reservation_id, person_id, role) values (v_res_b, v_person, 'holder');

  begin
    -- Extiende room_a hasta el 2027-02-07: se solapa con room_b (06-09).
    perform public.modify_stay_dates(v_room_a, '2027-02-07'::date, 100::numeric);
    raise exception 'NO_SE_RECHAZO';
  exception
    when exclusion_violation then
      perform set_config('overlap.extend', 'ok', true);
  end;
end $$;

select is(current_setting('overlap.extend', true), 'ok',
  '3.2: modify_stay_dates (reemplaza a extend_stay) que crea un solapamiento nuevo para la misma persona es rechazado');

-- ---------------------------------------------------------------------
-- 3.3: change_room preserva la restricción.
--
-- change_room en sí NO cambia fechas (sólo room_id/room_type_id -- el
-- tramo se recorta/abre pero el span total de la reserva no se altera),
-- así que no puede POR SÍ SOLO generar un solapamiento nuevo -- eso ya
-- lo cubre 3.2 (modify_stay_dates). Lo que sí hay que probar es que,
-- DESPUÉS de mover de habitación, la sincronización sigue funcionando:
-- ni el trigger ni la restricción quedan rotos por el cambio de cuarto.
-- ---------------------------------------------------------------------
do $$
declare
  v_room_a uuid; v_type_a uuid; v_room_b uuid; v_type_b uuid; v_room_c uuid; v_type_c uuid;
  v_person uuid; v_res_a uuid; v_res_b uuid; v_booking uuid;
begin
  select o.room_id, o.room_type_id into v_room_c, v_type_c
  from public.room_type_options o
  join public.rooms r on r.id = o.room_id and r.operational_status = 'available'
  where o.room_id not in (select room_id from rooms2)
  limit 1;

  select room_id, room_type_id into v_room_a, v_type_a from rooms2 order by room_id limit 1;
  select room_id, room_type_id into v_room_b, v_type_b from rooms2 order by room_id offset 1 limit 1;

  insert into public.people (first_name, last_name) values ('Cambia', 'Habitacion')
    returning id into v_person;
  insert into public.guests (person_id) values (v_person);
  insert into public.bookings (contact_person_id) values (v_person) returning id into v_booking;

  -- Estadía a mover: room_a, checked_in.
  insert into public.reservations (
    guest_id, room_id, room_type_id, check_in_date, check_out_date, status, booking_id, total_amount_bs
  ) values (
    v_person, v_room_a, v_type_a, '2027-03-01', '2027-03-05', 'checked_in', v_booking, 100
  ) returning id into v_res_a;
  insert into public.reservation_guests (reservation_id, person_id, role) values (v_res_a, v_person, 'holder');

  -- Otra estadía activa de la MISMA persona, sin solapar todavía
  -- (empieza el mismo día en que la de arriba sale -- back to back, OK).
  insert into public.reservations (
    guest_id, room_id, room_type_id, check_in_date, check_out_date, status, booking_id, total_amount_bs
  ) values (
    v_person, v_room_c, v_type_c, '2027-03-05', '2027-03-09', 'confirmed', v_booking, 100
  ) returning id into v_res_b;
  insert into public.reservation_guests (reservation_id, person_id, role) values (v_res_b, v_person, 'holder');

  -- Mueve la estadía de room_a a room_b: no toca fechas, no debe romper
  -- nada (ni la restricción, ni la sincronización).
  perform public.change_room(v_room_a, v_room_b, v_type_b, 100::numeric);

  if not exists (
    select 1 from public.reservation_guests
    where reservation_id = v_res_a and stay_range = daterange('2027-03-01', '2027-03-05', '[)')
  ) then
    raise exception 'CHANGE_ROOM_ROMPIO_SYNC';
  end if;

  -- Y la restricción sigue viva después del cambio de cuarto: extender
  -- la estadía movida hacia el solapamiento sigue rechazándose.
  begin
    perform public.modify_stay_dates(v_room_b, '2027-03-07'::date, 100::numeric);
    raise exception 'NO_SE_RECHAZO';
  exception
    when exclusion_violation then
      perform set_config('overlap.changeroom', 'ok', true);
  end;
end $$;

select is(current_setting('overlap.changeroom', true), 'ok',
  '3.3: change_room preserva la restricción -- tras mover de cuarto, un solapamiento nuevo sigue rechazado'
);

-- ---------------------------------------------------------------------
-- Pre-flight: la función que cuenta violaciones detecta un fixture que
-- las tiene. No se puede crear el fixture con el EXCLUDE puesto, así que
-- se lo saca DENTRO de esta transacción (se pierde igual con el rollback
-- final del archivo).
-- ---------------------------------------------------------------------
do $$
declare
  v_room_a uuid; v_type_a uuid; v_room_b uuid; v_type_b uuid;
  v_person uuid; v_res_a uuid; v_res_b uuid; v_booking uuid;
  v_count  int;
begin
  alter table public.reservation_guests drop constraint reservation_guests_no_overlap;

  select room_id, room_type_id into v_room_a, v_type_a from rooms2 order by room_id limit 1;
  select room_id, room_type_id into v_room_b, v_type_b from rooms2 order by room_id offset 1 limit 1;

  insert into public.people (first_name, last_name) values ('Preflight', 'Violacion')
    returning id into v_person;
  insert into public.guests (person_id) values (v_person);
  insert into public.bookings (contact_person_id) values (v_person) returning id into v_booking;

  insert into public.reservations (
    guest_id, room_id, room_type_id, check_in_date, check_out_date, status, booking_id, total_amount_bs
  ) values (
    v_person, v_room_a, v_type_a, '2027-04-01', '2027-04-05', 'confirmed', v_booking, 100
  ) returning id into v_res_a;
  insert into public.reservation_guests (reservation_id, person_id, role) values (v_res_a, v_person, 'holder');

  insert into public.reservations (
    guest_id, room_id, room_type_id, check_in_date, check_out_date, status, booking_id, total_amount_bs
  ) values (
    v_person, v_room_b, v_type_b, '2027-04-03', '2027-04-07', 'confirmed', v_booking, 100
  ) returning id into v_res_b;
  insert into public.reservation_guests (reservation_id, person_id, role) values (v_res_b, v_person, 'holder');

  select count(*) into v_count from public._stay_overlap_violations();
  if v_count = 0 then
    raise exception 'PREFLIGHT_NO_DETECTO';
  end if;
  perform set_config('overlap.preflight', v_count::text, true);
end $$;

select is(current_setting('overlap.preflight', true), '1',
  'pre-flight: _stay_overlap_violations() detecta el fixture violatorio (1 par)');

-- ---------------------------------------------------------------------
-- Higiene de grants (3.7): ni las funciones de trigger ni el helper de
-- pre-flight son invocables directamente por nadie de negocio.
-- ---------------------------------------------------------------------
select ok(not has_function_privilege('anon',
    'public.sync_reservation_guests_stay_range()', 'execute'),
  'anon no puede ejecutar sync_reservation_guests_stay_range');
select ok(not has_function_privilege('authenticated',
    'public.sync_reservation_guests_stay_range()', 'execute'),
  'authenticated tampoco: sólo la invoca el trigger');
select ok(not has_function_privilege('anon',
    'public.init_reservation_guests_stay_range()', 'execute'),
  'anon no puede ejecutar init_reservation_guests_stay_range');
select ok(not has_function_privilege('authenticated',
    'public.init_reservation_guests_stay_range()', 'execute'),
  'authenticated tampoco: sólo la invoca el trigger');
select ok(not has_function_privilege('anon',
    'public._stay_overlap_violations()', 'execute'),
  'anon no puede ejecutar el helper de pre-flight');
select ok(not has_function_privilege('authenticated',
    'public._stay_overlap_violations()', 'execute'),
  'authenticated tampoco: es interno del pre-flight y de este test');

reset role;
select * from finish();
rollback;
