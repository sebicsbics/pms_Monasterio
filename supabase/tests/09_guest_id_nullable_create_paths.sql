-- =====================================================================
-- guest_id nullable + rutas de alta + arrivals() (change:
-- reservation-booker-vs-guest, PR2a-db).
--
-- Prueba que:
--  - reservations.guest_id acepta NULL (pero la FK sigue viva si se
--    setea a alguien que no existe);
--  - create_reservation respeta el toggle p_contact_stays;
--  - create_bulk_reservation NUNCA hace titular al organizador y arma el
--    titular sólo si vino un occupant precargado, habitación por
--    habitación (dos habitaciones -> dos titulares distintos, ninguno
--    es el organizador);
--  - el check-in de una habitación del bulk NO toca al titular de otra;
--  - arrivals() lee el contacto desde bookings y tolera guest_id NULL.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(22);

select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
select is(current_user_role(), 'root', 'fixture: sesión con rol root');

-- ---------------------------------------------------------------------
-- 0) guest_id nullable, FK viva.
-- ---------------------------------------------------------------------
select ok(
  (select is_nullable = 'YES' from information_schema.columns
     where table_schema = 'public' and table_name = 'reservations'
       and column_name = 'guest_id'),
  'reservations.guest_id ahora acepta NULL'
);

select throws_matching(
  $$
    update public.reservations
    set guest_id = '00000000-0000-0000-0000-000000000000'
    where id = (select id from public.reservations limit 1)
  $$,
  'violates foreign key constraint',
  'la FK de guest_id sigue viva cuando se setea a alguien que no existe'
);

-- ---------------------------------------------------------------------
-- 1) create_reservation: toggle ON (default) -> contacto = titular.
-- ---------------------------------------------------------------------
do $$
declare
  v_room_id      uuid;
  v_room_type_id uuid;
  v_res_id       uuid;
  v_guest_id     uuid;
  v_booking_id   uuid;
  v_holder_count int;
begin
  select o.room_id, o.room_type_id into v_room_id, v_room_type_id
  from public.room_type_options o
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  join public.rooms r on r.id = o.room_id
  where not exists (
    select 1 from public.reservations x
    where x.room_id = o.room_id
      and x.status in ('confirmed', 'checked_in')
      and x.check_in_date < '2031-03-05' and '2031-03-01' < x.check_out_date
  )
  limit 1;

  v_res_id := public.create_reservation(
    v_room_id, v_room_type_id, 'Toggle', 'On',
    '70000001', null, '2031-03-01', '2031-03-05', 1, 'phone'
  );

  select guest_id, booking_id into v_guest_id, v_booking_id
  from public.reservations where id = v_res_id;

  select count(*) into v_holder_count
  from public.reservation_guests where reservation_id = v_res_id and role = 'holder';

  if v_guest_id is null then
    raise exception 'toggle ON: se esperaba guest_id no nulo';
  end if;
  if v_booking_id is null then
    raise exception 'toggle ON: se esperaba booking_id no nulo';
  end if;
  if v_holder_count <> 1 then
    raise exception 'toggle ON: se esperaba exactamente 1 holder, hubo %', v_holder_count;
  end if;
  if not exists (
    select 1 from public.bookings b
    where b.id = v_booking_id and b.contact_person_id = v_guest_id
  ) then
    raise exception 'toggle ON: el contacto de la booking debe ser el mismo que el titular';
  end if;
end $$;
select pass('create_reservation toggle ON: contacto = titular, booking creada');

-- ---------------------------------------------------------------------
-- 2) create_reservation: toggle OFF -> sin titular, booking igual.
-- ---------------------------------------------------------------------
do $$
declare
  v_room_id      uuid;
  v_room_type_id uuid;
  v_res_id       uuid;
  v_guest_id     uuid;
  v_booking_id   uuid;
  v_holder_count int;
begin
  select o.room_id, o.room_type_id into v_room_id, v_room_type_id
  from public.room_type_options o
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where not exists (
    select 1 from public.reservations x
    where x.room_id = o.room_id
      and x.status in ('confirmed', 'checked_in')
      and x.check_in_date < '2031-03-10' and '2031-03-06' < x.check_out_date
  )
  limit 1;

  v_res_id := public.create_reservation(
    v_room_id, v_room_type_id, 'Toggle', 'Off',
    '70000002', null, '2031-03-06', '2031-03-10', 1, 'phone',
    null, null, false
  );

  select guest_id, booking_id into v_guest_id, v_booking_id
  from public.reservations where id = v_res_id;

  select count(*) into v_holder_count
  from public.reservation_guests where reservation_id = v_res_id and role = 'holder';

  if v_guest_id is not null then
    raise exception 'toggle OFF: se esperaba guest_id NULL';
  end if;
  if v_booking_id is null then
    raise exception 'toggle OFF: se esperaba booking_id no nulo igual';
  end if;
  if v_holder_count <> 0 then
    raise exception 'toggle OFF: se esperaba 0 holders, hubo %', v_holder_count;
  end if;
end $$;
select pass('create_reservation toggle OFF: guest_id NULL, sin holder, booking igual creada');

-- ---------------------------------------------------------------------
-- 3) create_bulk_reservation: dos habitaciones, occupants distintos.
--    El organizador NUNCA es titular. Una tercera habitación SIN
--    occupants queda con guest_id NULL y sin holder.
-- ---------------------------------------------------------------------
do $$
declare
  v_rooms        jsonb;
  v_room1        uuid; v_type1 uuid;
  v_room2        uuid; v_type2 uuid;
  v_room3        uuid; v_type3 uuid;
  v_result       jsonb;
  v_created      jsonb;
  v_res1         uuid; v_res2 uuid; v_res3 uuid;
  v_guest1       uuid; v_guest2 uuid; v_guest3 uuid;
  v_booking1     uuid; v_booking2 uuid; v_booking3 uuid;
  v_organizer_id uuid;
begin
  select o.room_id, o.room_type_id into v_room1, v_type1
  from public.room_type_options o
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where not exists (
    select 1 from public.reservations x where x.room_id = o.room_id
      and x.status in ('confirmed','checked_in')
      and x.check_in_date < '2031-04-05' and '2031-04-01' < x.check_out_date
  ) order by o.room_id limit 1;

  select o.room_id, o.room_type_id into v_room2, v_type2
  from public.room_type_options o
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where o.room_id <> v_room1
    and not exists (
      select 1 from public.reservations x where x.room_id = o.room_id
        and x.status in ('confirmed','checked_in')
        and x.check_in_date < '2031-04-05' and '2031-04-01' < x.check_out_date
    ) order by o.room_id limit 1;

  select o.room_id, o.room_type_id into v_room3, v_type3
  from public.room_type_options o
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where o.room_id not in (v_room1, v_room2)
    and not exists (
      select 1 from public.reservations x where x.room_id = o.room_id
        and x.status in ('confirmed','checked_in')
        and x.check_in_date < '2031-04-05' and '2031-04-01' < x.check_out_date
    ) order by o.room_id limit 1;

  v_rooms := jsonb_build_array(
    jsonb_build_object(
      'room_id', v_room1, 'room_type_id', v_type1, 'num_guests', 1,
      'occupants', jsonb_build_array(
        jsonb_build_object('first_name','Bulk','last_name','Holder1','document','BLK-001')
      )
    ),
    jsonb_build_object(
      'room_id', v_room2, 'room_type_id', v_type2, 'num_guests', 1,
      'occupants', jsonb_build_array(
        jsonb_build_object('first_name','Bulk','last_name','Holder2','document','BLK-002')
      )
    ),
    jsonb_build_object('room_id', v_room3, 'room_type_id', v_type3, 'num_guests', 1)
  );

  v_result := public.create_bulk_reservation(
    v_rooms, 'Organizadora', 'Grupo', '70000003', null, '2031-04-01', '2031-04-05', 'phone'
  );
  v_created := v_result->'created';
  if jsonb_array_length(v_created) <> 3 then
    raise exception 'se esperaban 3 reservas creadas, hubo %: %', jsonb_array_length(v_created), v_result;
  end if;

  v_res1 := (v_created->>0)::uuid;
  v_res2 := (v_created->>1)::uuid;
  v_res3 := (v_created->>2)::uuid;

  select guest_id, booking_id into v_guest1, v_booking1 from public.reservations where id = v_res1;
  select guest_id, booking_id into v_guest2, v_booking2 from public.reservations where id = v_res2;
  select guest_id, booking_id into v_guest3, v_booking3 from public.reservations where id = v_res3;

  select contact_person_id into v_organizer_id from public.bookings where id = v_booking1;

  if v_guest1 is null or v_guest2 is null then
    raise exception 'las 2 habitaciones con occupants deben tener guest_id';
  end if;
  if v_guest1 = v_guest2 then
    raise exception 'los 2 titulares deben ser personas distintas';
  end if;
  if v_guest1 = v_organizer_id or v_guest2 = v_organizer_id then
    raise exception 'el organizador NUNCA debe ser titular de una habitación';
  end if;
  if v_guest3 is not null then
    raise exception 'la habitación sin occupants debe quedar con guest_id NULL';
  end if;
  if exists (select 1 from public.reservation_guests where reservation_id = v_res3) then
    raise exception 'la habitación sin occupants no debe tener holder';
  end if;
  if v_booking1 <> v_booking2 or v_booking2 <> v_booking3 then
    raise exception 'las 3 habitaciones deben compartir UNA sola booking del grupo';
  end if;
  if not exists (
    select 1 from public.reservation_guests
    where reservation_id = v_res1 and person_id = v_guest1 and role = 'holder'
  ) then
    raise exception 'room1: holder no registrado en reservation_guests';
  end if;
end $$;
select pass('create_bulk_reservation: 2 titulares distintos, organizador nunca titular, 1 booking, room sin occupants queda NULL');

-- ---------------------------------------------------------------------
-- 4) Bulk check-in de una habitación no toca al titular de otra
--    (2a.4). Reusa las reservas creadas en el bloque anterior.
-- ---------------------------------------------------------------------
do $$
declare
  v_res1        uuid;
  v_res2        uuid;
  v_guest1      uuid;
  v_before_fn   text;
  v_before_ln   text;
  v_after_fn    text;
  v_after_ln    text;
begin
  select r.id, r.guest_id into v_res1, v_guest1
  from public.reservations r
  join public.reservation_guests rg on rg.reservation_id = r.id and rg.role = 'holder'
  join public.people p on p.id = rg.person_id and p.last_name = 'Holder1'
  where r.status = 'confirmed'
  limit 1;

  select r.id into v_res2
  from public.reservations r
  join public.reservation_guests rg on rg.reservation_id = r.id and rg.role = 'holder'
  join public.people p on p.id = rg.person_id and p.last_name = 'Holder2'
  where r.status = 'confirmed'
  limit 1;

  select first_name, last_name into v_before_fn, v_before_ln
  from public.people where id = v_guest1;

  perform public.check_in_reservation_with_guests(
    p_reservation_id => v_res2, p_document => 'BLK-002-DOC', p_birth_date => null::date,
    p_country_code => 'BO', p_city => 'La Paz', p_wants_offers => false
  );

  select first_name, last_name into v_after_fn, v_after_ln
  from public.people where id = v_guest1;

  if v_before_fn is distinct from v_after_fn or v_before_ln is distinct from v_after_ln then
    raise exception 'el check-in de room2 alteró el perfil del titular de room1';
  end if;
  if not exists (select 1 from public.reservations where id = v_res2 and status = 'checked_in') then
    raise exception 'room2 debía quedar checked_in';
  end if;
  if exists (select 1 from public.reservations where id = v_res1 and status = 'checked_in') then
    raise exception 'room1 no debía verse afectada por el check-in de room2';
  end if;
end $$;
select pass('check-in de room2 no altera al titular de room1 (bulk con occupants precargados)');

-- ---------------------------------------------------------------------
-- 5) arrivals(): contacto desde bookings, tolera guest_id NULL, expone
--    holder_first_name/holder_last_name.
-- ---------------------------------------------------------------------
do $$
declare
  v_room_id      uuid;
  v_room_type_id uuid;
  v_res_id       uuid;
  v_row          record;
begin
  select o.room_id, o.room_type_id into v_room_id, v_room_type_id
  from public.room_type_options o
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where not exists (
    select 1 from public.reservations x where x.room_id = o.room_id
      and x.status in ('confirmed','checked_in')
      and x.check_in_date < '2031-05-05' and '2031-05-01' < x.check_out_date
  ) limit 1;

  v_res_id := public.create_reservation(
    v_room_id, v_room_type_id, 'Solo', 'Contacto',
    '70000004', 'solo.contacto@example.com', '2031-05-01', '2031-05-05', 1, 'phone',
    null, null, false
  );

  select * into v_row from public.arrivals('2031-05-01', '2031-05-05')
  where reservation_id = v_res_id;

  if v_row.reservation_id is null then
    raise exception 'arrivals() no devolvió la reserva con guest_id NULL';
  end if;
  if v_row.first_name <> 'Solo' or v_row.last_name <> 'Contacto' then
    raise exception 'arrivals() no está leyendo el contacto desde bookings';
  end if;
  if v_row.holder_first_name is not null or v_row.holder_last_name is not null then
    raise exception 'arrivals(): holder_first_name/last_name deben ser NULL sin titular';
  end if;
end $$;
select pass('arrivals(): contacto desde bookings, guest_id NULL tolerado, holder_* NULL');

do $$
declare
  v_res_id uuid;
  v_row    record;
begin
  select r.id into v_res_id
  from public.reservations r
  join public.reservation_guests rg on rg.reservation_id = r.id and rg.role = 'holder'
  join public.people p on p.id = rg.person_id and p.last_name = 'On'
  where r.status = 'confirmed'
  limit 1;

  select * into v_row from public.arrivals('2031-03-01', '2031-03-05')
  where reservation_id = v_res_id;

  if v_row.holder_first_name <> 'Toggle' or v_row.holder_last_name <> 'On' then
    raise exception 'arrivals(): holder_first_name/last_name deben reflejar al titular cuando existe';
  end if;
end $$;
select pass('arrivals(): holder_first_name/last_name reflejan al titular cuando existe');

-- ---------------------------------------------------------------------
-- 6) Higiene de grants.
-- ---------------------------------------------------------------------
-- feat/booking-10-contract-single cambió la aridad de create_reservation
-- (13 -> 23 parámetros, R2.8): la firma vieja ya no existe, se referencia
-- la nueva.
select ok(not has_function_privilege('anon',
    'public.create_reservation(uuid,uuid,text,text,text,text,date,date,integer,text,numeric,text,boolean,text,text,numeric,uuid,text,text,text,text,boolean,text)',
    'execute'),
  'anon no puede ejecutar create_reservation');
select ok(has_function_privilege('authenticated',
    'public.create_reservation(uuid,uuid,text,text,text,text,date,date,integer,text,numeric,text,boolean,text,text,numeric,uuid,text,text,text,text,boolean,text)',
    'execute'),
  'authenticated sí puede ejecutar create_reservation');

select ok(not has_function_privilege('anon',
    'public.create_bulk_reservation(jsonb,text,text,text,text,date,date,text,numeric,text,text,text,numeric,uuid,text,text,text,text)',
    'execute'),
  'anon no puede ejecutar create_bulk_reservation');
select ok(has_function_privilege('authenticated',
    'public.create_bulk_reservation(jsonb,text,text,text,text,date,date,text,numeric,text,text,text,numeric,uuid,text,text,text,text)',
    'execute'),
  'authenticated sí puede ejecutar create_bulk_reservation');

select ok(not has_function_privilege('anon', 'public.arrivals(date,date)', 'execute'),
  'anon no puede ejecutar arrivals');
select ok(has_function_privilege('authenticated', 'public.arrivals(date,date)', 'execute'),
  'authenticated sí puede ejecutar arrivals');

select ok(not has_function_privilege('anon', 'public._run_booking_backfill()', 'execute'),
  'anon no puede ejecutar _run_booking_backfill (interna)');
select ok(not has_function_privilege('authenticated', 'public._run_booking_backfill()', 'execute'),
  'authenticated tampoco puede ejecutar _run_booking_backfill (interna)');

-- _create_booking_for_new_reservation / _create_holder_for_new_reservation
-- (triggers de respaldo de PR1) se dropearon en 20260911020000: toda ruta
-- de alta arma booking+holder a mano ahora. Ver supabase/tests/10_*.sql.

-- ---------------------------------------------------------------------
-- 7) Privilegios de tabla sobre bookings (verificado manualmente por el
--    coordinador: sin cambios necesarios, sólo se deja el guard).
-- ---------------------------------------------------------------------
select ok(not has_table_privilege('anon', 'public.bookings', 'SELECT'),
  'anon no tiene SELECT en bookings');
select ok(not has_table_privilege('anon', 'public.bookings', 'INSERT'),
  'anon no tiene INSERT en bookings');
select ok(not has_table_privilege('anon', 'public.bookings', 'UPDATE'),
  'anon no tiene UPDATE en bookings');
select ok(not has_table_privilege('anon', 'public.bookings', 'DELETE'),
  'anon no tiene DELETE en bookings');

-- ---------------------------------------------------------------------
-- 8) Invariante permanente reusada (PR1): ninguna reserva checked_in
--    tiene guest_id NULL en el estado normal del seed (el bulk
--    check-in de más arriba sí tenía holder, así que no la rompe).
-- ---------------------------------------------------------------------
select is(
  (select count(*) from public.reservations where status = 'checked_in' and guest_id is null),
  0::bigint,
  'invariante permanente: sigue sin reservas checked_in con guest_id NULL en este flujo'
);

select * from finish();
rollback;
