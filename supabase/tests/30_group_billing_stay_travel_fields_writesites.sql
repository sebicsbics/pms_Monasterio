-- =====================================================================
-- Travel fields (origin_city, travel_purpose, transport_means): mover
-- los 3 puntos de alta que hoy escriben en `guests` para que escriban
-- en `reservation_guests` (change: group-billing, stage 6, Slice 8b,
-- branch feat/booking-20-travel-fields-writesites). Spec R8.1, R8.3.
--
-- (a) el titular vía check_in_reservation_with_guests -> aterriza en
--     reservation_guests, NO en guests.
-- (b) el titular vía walk_in_check_in_with_guests -> aterriza en
--     reservation_guests, NO en guests.
-- (c, NUEVO, brecha #338.4) un acompañante agregado vía
--     add_reservation_companions con origin_city en el jsonb -> aterriza
--     en reservation_guests para ese (reservation_id, person_id), NO en
--     guests.
-- (d) occupation de un acompañante -> sigue aterrizando en guests
--     (sin cambios, confirma que el split es solo de campos de viaje).
-- (e) volver a llamar add_reservation_companions para el mismo
--     acompañante (rama on conflict) -> los campos de viaje se
--     actualizan vía coalesce, no se blanquean con una llamada
--     posterior con nulls.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

-- ---------------------------------------------------------------------
-- (a) Titular vía check_in_reservation_with_guests.
-- ---------------------------------------------------------------------
do $$
declare
  v_room_id uuid; v_room_type_id uuid; v_res uuid; v_guest_id uuid;
begin
  select o.room_id, o.room_type_id into v_room_id, v_room_type_id
  from public.room_type_options o
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where not exists (
    select 1 from public.reservations x where x.room_id = o.room_id
      and x.status in ('confirmed','checked_in')
      and x.check_in_date < '2034-05-05' and '2034-05-01' < x.check_out_date
  ) limit 1;

  v_res := public.create_reservation(
    v_room_id, v_room_type_id, 'Viajera', 'Sitio8b',
    '70000050', null, '2034-05-01', '2034-05-05', 1, 'phone',
    null, null, false
  );
  perform public.check_in_reservation_with_guests(
    p_reservation_id => v_res, p_document => '11100050', p_birth_date => '1990-01-01'::date,
    p_country_code => 'BO', p_city => 'La Paz', p_wants_offers => false,
    p_origin_city => 'Cochabamba', p_travel_purpose => 'Negocios', p_transport_means => 'Avión',
    p_holder_first_name => 'Viajera', p_holder_last_name => 'Sitio8b'
  );

  select person_id into v_guest_id from public.guests where passport_number = '11100050';

  create temp table fixture_a as select v_res as res_id, v_guest_id as person_id;
end $$;

select is(
  (select origin_city from public.reservation_guests
    where reservation_id = (select res_id from fixture_a) and role = 'holder'),
  'Cochabamba',
  '(a1) check_in_reservation_with_guests escribe origin_city en reservation_guests'
);
select is(
  (select travel_purpose from public.reservation_guests
    where reservation_id = (select res_id from fixture_a) and role = 'holder'),
  'Negocios',
  '(a2) check_in_reservation_with_guests escribe travel_purpose en reservation_guests'
);
select is(
  (select transport_means from public.reservation_guests
    where reservation_id = (select res_id from fixture_a) and role = 'holder'),
  'Avión',
  '(a3) check_in_reservation_with_guests escribe transport_means en reservation_guests'
);
select is(
  (select origin_city from public.guests where person_id = (select person_id from fixture_a)),
  null,
  '(a4, neg) check_in_reservation_with_guests ya NO escribe origin_city en guests'
);

-- ---------------------------------------------------------------------
-- (b) Titular vía walk_in_check_in_with_guests.
-- ---------------------------------------------------------------------
do $$
declare
  v_room_id uuid; v_room_type_id uuid; v_res uuid; v_guest_id uuid;
begin
  select o.room_id, o.room_type_id into v_room_id, v_room_type_id
  from public.room_type_options o
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where not exists (
    select 1 from public.reservations x where x.room_id = o.room_id
      and x.status in ('confirmed','checked_in')
      and x.check_in_date <= current_date and current_date < x.check_out_date
  ) limit 1;

  v_res := public.walk_in_check_in_with_guests(
    v_room_id, v_room_type_id, 'Walkin', 'Sitio8b', '90000051', null,
    null::date, 'BO', 'La Paz', false, 2, null, null,
    'Sucre', 'Turismo', null, 'Bus'
  );

  select guest_id into v_guest_id from public.reservations where id = v_res;

  create temp table fixture_b as select v_res as res_id, v_guest_id as person_id;
end $$;

select is(
  (select origin_city from public.reservation_guests
    where reservation_id = (select res_id from fixture_b) and role = 'holder'),
  'Sucre',
  '(b1) walk_in_check_in_with_guests escribe origin_city en reservation_guests'
);
select is(
  (select origin_city from public.guests where person_id = (select person_id from fixture_b)),
  null,
  '(b2, neg) walk_in_check_in_with_guests ya NO escribe origin_city en guests'
);

-- ---------------------------------------------------------------------
-- (c, d, e) Acompañante vía add_reservation_companions.
-- ---------------------------------------------------------------------
do $$
declare
  v_person uuid;
begin
  perform public.add_reservation_companions(
    (select res_id from fixture_a),
    jsonb_build_array(jsonb_build_object(
      'first_name', 'Acompañante', 'last_name', 'Sitio8b',
      'document', '90000052', 'origin_city', 'Tarija',
      'travel_purpose', 'Familiar', 'transport_means', 'Auto',
      'occupation', 'Ingeniera'
    ))
  );

  select person_id into v_person from public.guests where passport_number = '90000052';
  create temp table fixture_c as select v_person as person_id;
end $$;

select is(
  (select origin_city from public.reservation_guests
    where reservation_id = (select res_id from fixture_a)
      and person_id = (select person_id from fixture_c)),
  'Tarija',
  '(c) add_reservation_companions escribe origin_city en reservation_guests, no en guests'
);
select is(
  (select origin_city from public.guests where person_id = (select person_id from fixture_c)),
  null,
  '(c2, neg) add_reservation_companions ya NO escribe origin_city en guests'
);
select is(
  (select occupation from public.guests where person_id = (select person_id from fixture_c)),
  'Ingeniera',
  '(d) occupation del acompañante sigue aterrizando en guests (sin cambios)'
);

-- (e) re-llamar con nulls en los campos de viaje no debe blanquearlos
-- (rama on conflict actualiza vía coalesce).
select lives_ok(
  $$
  select public.add_reservation_companions(
    (select res_id from fixture_a),
    jsonb_build_array(jsonb_build_object(
      'first_name', 'Acompañante', 'last_name', 'Sitio8b',
      'document', '90000052'
    ))
  )
  $$,
  '(e0) segunda llamada a add_reservation_companions (rama on conflict) no falla'
);
select is(
  (select origin_city from public.reservation_guests
    where reservation_id = (select res_id from fixture_a)
      and person_id = (select person_id from fixture_c)),
  'Tarija',
  '(e) segunda llamada sin origin_city no blanquea el valor ya capturado (coalesce)'
);

select * from finish();
rollback;
