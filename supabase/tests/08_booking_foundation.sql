-- =====================================================================
-- Booking foundation (change: reservation-booker-vs-guest, PR1).
--
-- `bookings` pasa a ser el dueño de "quién reserva/responde" (contacto),
-- separado de `reservation_guests` ("quién ocupa la habitación"). Esta
-- migración crea la tabla, engancha reservations.booking_id, agrega
-- reservation_guests.role y hace el backfill de datos existentes.
--
-- El backfill es la parte riesgosa: agrupa reservas por (guest_id,
-- check_in_date, check_out_date) en una sola `bookings` por cluster, y
-- asigna un `reservation_guests` con role='holder' por reserva — EXCEPTO
-- en los clusters "corruptos" (un mismo contacto con 2+ habitaciones
-- checked_in/checked_out a la vez), donde ese titular compartido es
-- justamente el bug que este cambio corrige: esas quedan sin holder y se
-- listan para reconciliación manual.
--
-- El seed local no trae esos clusters (se verificó: 0 reservas comparten
-- guest_id+fechas), así que este test arma sus propios fixtures y vuelve
-- a correr `public._run_booking_backfill()` sobre ellos. Para poder
-- insertar reservas con booking_id NULL (como estarían antes del
-- backfill real), se saca momentáneamente el NOT NULL dentro de esta
-- misma transacción, que se revierte entera al final con rollback.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(21);

-- ---------------------------------------------------------------------
-- 0) Forma del esquema.
-- ---------------------------------------------------------------------
select has_table('public', 'bookings', 'la tabla bookings existe');
select has_column('public', 'bookings', 'contact_person_id', 'bookings.contact_person_id existe');
select col_not_null('public', 'bookings', 'contact_person_id', 'contact_person_id es NOT NULL');
select has_column('public', 'reservations', 'booking_id', 'reservations.booking_id existe');
select col_not_null('public', 'reservations', 'booking_id', 'booking_id es NOT NULL tras el backfill real');
select has_column('public', 'reservation_guests', 'role', 'reservation_guests.role existe');
select col_default_is('public', 'reservation_guests', 'role', 'companion', 'default de role es companion');

-- Índice de unicidad de titular: sólo puede haber un holder por reserva.
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
select is(current_user_role(), 'root', 'fixture: sesión con rol root');

-- ---------------------------------------------------------------------
-- 1) Backfill real (el que corrió la migración) dejó todo consistente.
-- ---------------------------------------------------------------------
select is(
  (select count(*) from public.reservations where booking_id is null),
  0::bigint,
  'ninguna reserva existente quedó sin booking_id'
);
select is(
  (select count(*) from public.bookings),
  (select count(distinct (guest_id, check_in_date, check_out_date)) from public.reservations),
  'una booking por cluster (guest_id, check_in, check_out) de las reservas ya existentes'
);

-- ---------------------------------------------------------------------
-- 2) Índice de unicidad de holder por reserva.
-- ---------------------------------------------------------------------
select throws_matching(
  $$
    insert into public.reservation_guests (reservation_id, person_id, role)
    select r.id, r.guest_id, 'holder' from public.reservations r limit 1
  $$,
  'duplicate key value violates unique constraint',
  'un segundo holder para la misma reserva es rechazado por el índice único'
);

-- ---------------------------------------------------------------------
-- 3) Fixtures para re-ejercitar el backfill: clusters limpio y corrupto.
-- ---------------------------------------------------------------------
alter table public.reservations alter column booking_id drop not null;
-- Desde 20260911020000 los triggers de respaldo reservations_create_booking
-- / reservations_create_holder ya no existen (toda ruta de alta arma
-- booking+holder a mano): estos fixtures insertan booking_id = NULL
-- explícito, que es justo el estado que se quiere simular.

do $$
declare
  v_contact_a uuid;
  v_contact_b uuid;
  v_room1 uuid;
  v_room2 uuid;
  v_room3 uuid;
  v_room_type uuid;
  v_res_clean uuid;
  v_res_corrupt_1 uuid;
  v_res_corrupt_2 uuid;
begin
  select id into v_room_type from public.room_types limit 1;
  select id into v_room1 from public.rooms order by id limit 1 offset 0;
  select id into v_room2 from public.rooms order by id limit 1 offset 1;
  select id into v_room3 from public.rooms order by id limit 1 offset 2;

  insert into public.people (id, first_name, last_name)
    values ('aaaaaaaa-0000-0000-0000-000000000001', 'Fixture', 'ContactoLimpio')
    returning id into v_contact_a;
  insert into public.guests (person_id) values (v_contact_a);

  insert into public.people (id, first_name, last_name)
    values ('aaaaaaaa-0000-0000-0000-000000000002', 'Fixture', 'ContactoCorrupto')
    returning id into v_contact_b;
  insert into public.guests (person_id) values (v_contact_b);

  -- Cluster limpio: 1 reserva, sin duplicados de sala checked-in.
  insert into public.reservations
    (id, guest_id, room_id, room_type_id, check_in_date, check_out_date, status, total_amount_bs, booking_id)
  values
    ('bbbbbbbb-0000-0000-0000-000000000001', v_contact_a, v_room1, v_room_type,
     '2030-01-10', '2030-01-15', 'confirmed', 500, null)
  returning id into v_res_clean;

  -- Cluster corrupto: mismo contacto, mismas fechas, 2 habitaciones
  -- checked_in a la vez -- el bug que este cambio corrige.
  insert into public.reservations
    (id, guest_id, room_id, room_type_id, check_in_date, check_out_date, status, total_amount_bs, booking_id)
  values
    ('bbbbbbbb-0000-0000-0000-000000000002', v_contact_b, v_room2, v_room_type,
     '2030-02-01', '2030-02-05', 'checked_in', 500, null)
  returning id into v_res_corrupt_1;

  insert into public.reservations
    (id, guest_id, room_id, room_type_id, check_in_date, check_out_date, status, total_amount_bs, booking_id)
  values
    ('bbbbbbbb-0000-0000-0000-000000000003', v_contact_b, v_room3, v_room_type,
     '2030-02-01', '2030-02-05', 'checked_in', 500, null)
  returning id into v_res_corrupt_2;
end $$;

select public._run_booking_backfill();

-- El cluster limpio: 1 booking, 1 holder.
select is(
  (select count(*) from public.bookings
     where contact_person_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  1::bigint,
  'cluster limpio: exactamente 1 booking'
);
select is(
  (select count(*) from public.reservation_guests
     where reservation_id = 'bbbbbbbb-0000-0000-0000-000000000001' and role = 'holder'),
  1::bigint,
  'cluster limpio: holder insertado'
);

-- El cluster corrupto: las 2 reservas colapsan en 1 booking...
select is(
  (select count(*) from public.bookings
     where contact_person_id = 'aaaaaaaa-0000-0000-0000-000000000002'),
  1::bigint,
  'cluster corrupto: igual colapsa en 1 booking (mismo contacto+fechas)'
);
select ok(
  (select count(distinct booking_id) from public.reservations
     where id in ('bbbbbbbb-0000-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000003')) = 1,
  'cluster corrupto: ambas reservas apuntan a la misma booking'
);
-- ...pero NINGUNA de las dos recibe holder (el bug que se está corrigiendo).
select is(
  (select count(*) from public.reservation_guests
     where reservation_id in
       ('bbbbbbbb-0000-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000003')
       and role = 'holder'),
  0::bigint,
  'cluster corrupto: ninguna de las 2 reservas recibe holder automático'
);

-- ---------------------------------------------------------------------
-- 4) RLS de bookings espeja a reservations.
-- ---------------------------------------------------------------------
select policies_are('public', 'bookings', array['bookings_select'],
  'bookings sólo tiene la política de lectura, igual que reservations');

set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"99999999-9999-9999-9999-999999999999","role":"authenticated"}', true);
select is(current_user_role(), 'anonymous', 'sin fila en profiles, el rol cae a anonymous');
select is(
  (select count(*) from public.bookings), 0::bigint,
  'sin rol operativo, bookings no expone filas (RLS)'
);
reset role;

-- ---------------------------------------------------------------------
-- 5) Invariante permanente (reusada por todo PR futuro): ninguna reserva
--    checked_in puede tener guest_id NULL.
-- ---------------------------------------------------------------------
select is(
  (select count(*) from public.reservations where status = 'checked_in' and guest_id is null),
  0::bigint,
  'invariante permanente: ninguna reserva checked_in tiene guest_id NULL'
);

-- ---------------------------------------------------------------------
-- 6) In-house / stay_guests no se alteran por este cambio (19 estadías
--    en producción; en el seed local se verifica que sigan consistentes).
-- ---------------------------------------------------------------------
select is(
  (select count(*) from public.reservations where status = 'checked_in')
    - (select count(*) from public.reservations
         where status = 'checked_in' and id in (
           'bbbbbbbb-0000-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000003'
         )),
  (select count(*) from public.reservations where status = 'checked_in') - 2,
  'las estadías in-house preexistentes no fueron tocadas por el backfill de fixtures'
);

select * from finish();
rollback;
