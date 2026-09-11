-- =====================================================================
-- Unificación de alta de booking/holder + drop de triggers de respaldo.
-- (change: reservation-booker-vs-guest, PR2b-db, 2 de 2). Ver
-- 20260911030000_unify_booking_holder_creation.sql.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(10);

select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
select is(current_user_role(), 'root', 'fixture: sesión con rol root');


-- ---------------------------------------------------------------------
-- 1) walk_in_check_in: arma booking + holder explícito, confirmed_at now().
-- ---------------------------------------------------------------------
do $$
declare
  v_room_id  uuid;
  v_type_id  uuid;
  v_res_id   uuid;
  v_person   uuid;
  v_booking  uuid;
  v_confirmed timestamptz;
begin
  select r.id, o.room_type_id into v_room_id, v_type_id
  from public.rooms r
  join public.room_type_options o on o.room_id = r.id
  where r.operational_status = 'available'
  limit 1;

  v_res_id := public.walk_in_check_in(
    v_room_id, v_type_id, 'Walkin', 'Directo', '90000099', 'walkin@test.com',
    '1990-01-01', 'BO', 'La Paz', false, 1
  );

  select guest_id, booking_id into v_person, v_booking from public.reservations where id = v_res_id;
  if v_booking is null then
    raise exception 'walk_in_check_in debía setear booking_id';
  end if;
  if not exists (select 1 from public.bookings where id = v_booking and contact_person_id = v_person) then
    raise exception 'walk_in_check_in: el contacto de la booking debe ser el propio walk-in';
  end if;

  select confirmed_at into v_confirmed
  from public.reservation_guests where reservation_id = v_res_id and role = 'holder';
  if v_confirmed is null then
    raise exception 'walk_in_check_in: el holder debe quedar confirmado (es un check-in inmediato)';
  end if;
end $$;
select pass('walk_in_check_in: booking + holder explícitos, confirmed_at inmediato');


-- ---------------------------------------------------------------------
-- 2) Unificación: no quedan triggers/funciones de respaldo de PR1.
-- ---------------------------------------------------------------------
select ok(
  not exists (
    select 1 from pg_trigger where tgname in ('reservations_create_booking', 'reservations_create_holder')
  ),
  'los triggers de respaldo de PR1 fueron dropeados'
);
select ok(
  not exists (
    select 1 from pg_proc where proname in
      ('_create_booking_for_new_reservation', '_create_holder_for_new_reservation')
  ),
  'las funciones de respaldo de PR1 fueron dropeadas'
);


-- ---------------------------------------------------------------------
-- 3) Higiene de grants (funciones tocadas en esta migración).
-- ---------------------------------------------------------------------
select ok(not has_function_privilege('anon',
    'public.walk_in_check_in_with_guests(uuid,uuid,text,text,text,text,date,text,text,boolean,integer,numeric,text,text,text,text,text,jsonb,text,text,text)',
    'execute'),
  'anon no puede ejecutar walk_in_check_in_with_guests');
select ok(has_function_privilege('authenticated',
    'public.walk_in_check_in_with_guests(uuid,uuid,text,text,text,text,date,text,text,boolean,integer,numeric,text,text,text,text,text,jsonb,text,text,text)',
    'execute'),
  'authenticated sí puede ejecutar walk_in_check_in_with_guests');

select ok(not has_function_privilege('anon',
    'public.walk_in_check_in(uuid,uuid,text,text,text,text,date,text,text,boolean,integer,numeric,text)',
    'execute'),
  'anon no puede ejecutar walk_in_check_in');
select ok(has_function_privilege('authenticated',
    'public.walk_in_check_in(uuid,uuid,text,text,text,text,date,text,text,boolean,integer,numeric,text)',
    'execute'),
  'authenticated sí puede ejecutar walk_in_check_in');

select ok(not has_function_privilege('anon',
    'public.create_reservation(uuid,uuid,text,text,text,text,date,date,int,text,numeric,text,boolean)',
    'execute'),
  'anon no puede ejecutar create_reservation');
select ok(has_function_privilege('authenticated',
    'public.create_reservation(uuid,uuid,text,text,text,text,date,date,int,text,numeric,text,boolean)',
    'execute'),
  'authenticated sí puede ejecutar create_reservation');


select * from finish();
rollback;
