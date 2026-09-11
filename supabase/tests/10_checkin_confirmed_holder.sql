-- =====================================================================
-- Check-in: confirmed_at + titular obligatorio. (change:
-- reservation-booker-vs-guest, PR2b-db, 1 de 2). Ver
-- 20260911020000_checkin_confirmed_holder.sql.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(16);

select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
select is(current_user_role(), 'root', 'fixture: sesión con rol root');


-- ---------------------------------------------------------------------
-- 0) Esquema: confirmed_at existe y es nullable.
-- ---------------------------------------------------------------------
select has_column('public', 'reservation_guests', 'confirmed_at',
  'reservation_guests.confirmed_at existe');
select col_is_null('public', 'reservation_guests', 'confirmed_at',
  'confirmed_at es nullable (precargado = NULL)');


-- ---------------------------------------------------------------------
-- 1) Backfill: huéspedes de estadías checked_in/checked_out preexistentes
--    (seed) quedaron confirmados.
-- ---------------------------------------------------------------------
select ok(
  not exists (
    select 1 from public.reservation_guests rg
    join public.reservations r on r.id = rg.reservation_id
    where r.status in ('checked_in', 'checked_out') and rg.confirmed_at is null
  ),
  'backfill: ningún huésped de una estadía checked_in/checked_out quedó sin confirmed_at'
);


-- ---------------------------------------------------------------------
-- 2) Toggle OFF sin datos de titular al check-in -> rechazado.
-- ---------------------------------------------------------------------
do $$
declare
  v_room_id      uuid;
  v_room_type_id uuid;
  v_res_id       uuid;
begin
  select o.room_id, o.room_type_id into v_room_id, v_room_type_id
  from public.room_type_options o
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where not exists (
    select 1 from public.reservations x where x.room_id = o.room_id
      and x.status in ('confirmed','checked_in')
      and x.check_in_date < '2032-01-05' and '2032-01-01' < x.check_out_date
  ) limit 1;

  v_res_id := public.create_reservation(
    v_room_id, v_room_type_id, 'SinTitular', 'Pendiente',
    '70000010', null, '2032-01-01', '2032-01-05', 1, 'phone',
    null, null, false
  );

  begin
    perform public.check_in_reservation_with_guests(
      p_reservation_id => v_res_id, p_document => '90000001', p_birth_date => null::date,
      p_country_code => 'BO', p_city => 'La Paz', p_wants_offers => false
    );
    raise exception 'no debió permitir el check-in sin titular';
  exception when others then
    if sqlerrm <> 'Debe indicar un huésped titular antes del check-in' then
      raise;
    end if;
  end;
end $$;
select pass('check-in sin titular resuelto: rechazado con el mensaje exacto');


-- ---------------------------------------------------------------------
-- 3) Toggle OFF + datos de titular nuevo al check-in -> éxito, guest_id
--    seteado, holder confirmado, invariante cerrada (el hueco que dejaba
--    pasar reservas checked_in con guest_id NULL ya no existe).
-- ---------------------------------------------------------------------
do $$
declare
  v_room_id      uuid;
  v_room_type_id uuid;
  v_res_id       uuid;
  v_guest_id     uuid;
  v_confirmed    timestamptz;
begin
  select o.room_id, o.room_type_id into v_room_id, v_room_type_id
  from public.room_type_options o
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where not exists (
    select 1 from public.reservations x where x.room_id = o.room_id
      and x.status in ('confirmed','checked_in')
      and x.check_in_date < '2032-01-10' and '2032-01-06' < x.check_out_date
  ) limit 1;

  v_res_id := public.create_reservation(
    v_room_id, v_room_type_id, 'SinTitular', 'ConDatos',
    '70000011', null, '2032-01-06', '2032-01-10', 1, 'phone',
    null, null, false
  );

  perform public.check_in_reservation_with_guests(
    p_reservation_id => v_res_id, p_document => '90000002', p_birth_date => null::date,
    p_country_code => 'BO', p_city => 'La Paz', p_wants_offers => false,
    p_holder_first_name => 'Nuevo', p_holder_last_name => 'Titular'
  );

  select guest_id into v_guest_id from public.reservations where id = v_res_id;
  if v_guest_id is null then
    raise exception 'se esperaba guest_id seteado tras resolver el titular en el check-in';
  end if;

  select confirmed_at into v_confirmed
  from public.reservation_guests where reservation_id = v_res_id and role = 'holder';
  if v_confirmed is null then
    raise exception 'el holder resuelto en el check-in debe quedar confirmado';
  end if;

  if not exists (
    select 1 from public.reservations
    where id = v_res_id and status = 'checked_in' and guest_id is not null
  ) then
    raise exception 'la reserva debía quedar checked_in con guest_id no nulo';
  end if;
end $$;
select pass('check-in con datos de titular nuevos: guest_id resuelto, holder confirmado, checked_in');


-- ---------------------------------------------------------------------
-- 4) Bulk con occupant precargado (holder) que NO se confirma hasta el
--    check-in; su propia fila se actualiza/confirma, nunca se re-inserta.
-- ---------------------------------------------------------------------
do $$
declare
  v_rooms        jsonb;
  v_room1        uuid; v_type1 uuid;
  v_result       jsonb;
  v_res1         uuid;
  v_guest1       uuid;
  v_person_count int;
  v_confirmed    timestamptz;
begin
  select o.room_id, o.room_type_id into v_room1, v_type1
  from public.room_type_options o
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where not exists (
    select 1 from public.reservations x where x.room_id = o.room_id
      and x.status in ('confirmed','checked_in')
      and x.check_in_date < '2032-02-05' and '2032-02-01' < x.check_out_date
  ) order by o.room_id limit 1;

  v_rooms := jsonb_build_array(
    jsonb_build_object(
      'room_id', v_room1, 'room_type_id', v_type1, 'num_guests', 1,
      'occupants', jsonb_build_array(
        jsonb_build_object('first_name','Precargado','last_name','Holder','document','PRE-001')
      )
    )
  );

  v_result := public.create_bulk_reservation(
    v_rooms, 'Organiza', 'Dora', '70000012', null, '2032-02-01', '2032-02-05', 'phone'
  );
  v_res1 := ((v_result->'created')->>0)::uuid;

  select guest_id into v_guest1 from public.reservations where id = v_res1;

  select confirmed_at into v_confirmed
  from public.reservation_guests where reservation_id = v_res1 and role = 'holder';
  if v_confirmed is not null then
    raise exception 'holder precargado en bulk debía quedar SIN confirmar hasta el check-in';
  end if;

  select count(*) into v_person_count from public.people where id = v_guest1;
  if v_person_count <> 1 then
    raise exception 'precondición rota: debía existir exactamente 1 people row para el holder precargado';
  end if;

  perform public.check_in_reservation_with_guests(
    p_reservation_id => v_res1, p_document => 'PRE-001', p_birth_date => null::date,
    p_country_code => 'BO', p_city => 'La Paz', p_wants_offers => false
  );

  select count(*) into v_person_count from public.people where id = v_guest1;
  if v_person_count <> 1 then
    raise exception 'el check-in NO debía re-insertar la fila del holder precargado';
  end if;

  select confirmed_at into v_confirmed
  from public.reservation_guests where reservation_id = v_res1 and role = 'holder';
  if v_confirmed is null then
    raise exception 'el check-in debía confirmar al holder precargado (su propia fila)';
  end if;
end $$;
select pass('bulk con occupant precargado: no se confirma hasta el check-in, su propia fila se actualiza (no se re-inserta)');


-- ---------------------------------------------------------------------
-- 5) Aislamiento bulk: check-in de room1 con titular nuevo no toca el
--    documento del contacto de la booking (spec: contacto nunca escribe
--    su ficha de huésped salvo que él mismo sea el titular).
-- ---------------------------------------------------------------------
do $$
declare
  v_rooms         jsonb;
  v_room1         uuid; v_type1 uuid;
  v_room2         uuid; v_type2 uuid;
  v_result        jsonb;
  v_res1          uuid; v_res2 uuid;
  v_contact_id    uuid;
  v_booking_id    uuid;
  v_contact_doc   text;
begin
  select o.room_id, o.room_type_id into v_room1, v_type1
  from public.room_type_options o
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where not exists (
    select 1 from public.reservations x where x.room_id = o.room_id
      and x.status in ('confirmed','checked_in')
      and x.check_in_date < '2032-03-05' and '2032-03-01' < x.check_out_date
  ) order by o.room_id limit 1;

  select o.room_id, o.room_type_id into v_room2, v_type2
  from public.room_type_options o
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where o.room_id <> v_room1
    and not exists (
      select 1 from public.reservations x where x.room_id = o.room_id
        and x.status in ('confirmed','checked_in')
        and x.check_in_date < '2032-03-05' and '2032-03-01' < x.check_out_date
    ) order by o.room_id limit 1;

  v_rooms := jsonb_build_array(
    jsonb_build_object('room_id', v_room1, 'room_type_id', v_type1, 'num_guests', 1),
    jsonb_build_object('room_id', v_room2, 'room_type_id', v_type2, 'num_guests', 1)
  );

  v_result := public.create_bulk_reservation(
    v_rooms, 'Coordinador', 'Grupo', '70000013', null, '2032-03-01', '2032-03-05', 'phone'
  );
  v_res1 := ((v_result->'created')->>0)::uuid;
  v_res2 := ((v_result->'created')->>1)::uuid;

  select booking_id into v_booking_id from public.reservations where id = v_res1;
  select contact_person_id into v_contact_id from public.bookings where id = v_booking_id;

  perform public.check_in_reservation_with_guests(
    p_reservation_id => v_res1, p_document => 'AISLADO-001', p_birth_date => null::date,
    p_country_code => 'BO', p_city => 'La Paz', p_wants_offers => false,
    p_holder_first_name => 'Sala1', p_holder_last_name => 'Titular'
  );

  select passport_number into v_contact_doc from public.guests where person_id = v_contact_id;
  if v_contact_doc is not null then
    raise exception 'el check-in de room1 escribió el documento en la ficha del CONTACTO del grupo';
  end if;

  if exists (
    select 1 from public.reservations where id = v_res2 and status <> 'confirmed'
  ) then
    raise exception 'room2 no debía verse afectada por el check-in de room1';
  end if;
end $$;
select pass('bulk: check-in con titular nuevo en room1 no escribe la ficha del contacto ni afecta room2');


-- ---------------------------------------------------------------------
-- 6) Dual-write agencia/canal: check-in escribe también en bookings.
-- ---------------------------------------------------------------------
do $$
declare
  v_room_id      uuid;
  v_room_type_id uuid;
  v_res_id       uuid;
  v_booking_id   uuid;
  v_agency       text;
begin
  select o.room_id, o.room_type_id into v_room_id, v_room_type_id
  from public.room_type_options o
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where not exists (
    select 1 from public.reservations x where x.room_id = o.room_id
      and x.status in ('confirmed','checked_in')
      and x.check_in_date < '2032-04-05' and '2032-04-01' < x.check_out_date
  ) limit 1;

  v_res_id := public.create_reservation(
    v_room_id, v_room_type_id, 'Dual', 'Write',
    '70000014', null, '2032-04-01', '2032-04-05', 1, 'phone'
  );

  select booking_id into v_booking_id from public.reservations where id = v_res_id;

  perform public.check_in_reservation_with_guests(
    p_reservation_id => v_res_id, p_document => '90000003', p_birth_date => null::date,
    p_country_code => 'BO', p_city => 'La Paz', p_wants_offers => false,
    p_agency_name => 'Agencia Dual SRL'
  );

  select agency_name into v_agency from public.bookings where id = v_booking_id;
  if v_agency <> 'Agencia Dual SRL' then
    raise exception 'el check-in debía escribir agency_name también en bookings';
  end if;
end $$;
select pass('check-in escribe agency_name/channel_code también en bookings (dual-write)');


-- ---------------------------------------------------------------------
-- 7) Invariante permanente + cierre del hueco intermedio.
-- ---------------------------------------------------------------------
select is(
  (select count(*) from public.reservations where status = 'checked_in' and guest_id is null),
  0::bigint,
  'invariante permanente: ninguna reserva checked_in tiene guest_id NULL'
);


-- ---------------------------------------------------------------------
-- 10) Higiene de grants (funciones tocadas en esta migración).
-- ---------------------------------------------------------------------
select ok(not has_function_privilege('anon',
    'public.check_in_reservation_with_guests(uuid,text,date,text,text,boolean,text,text,text,text,jsonb,text,text,text,text,uuid)',
    'execute'),
  'anon no puede ejecutar check_in_reservation_with_guests');
select ok(has_function_privilege('authenticated',
    'public.check_in_reservation_with_guests(uuid,text,date,text,text,boolean,text,text,text,text,jsonb,text,text,text,text,uuid)',
    'execute'),
  'authenticated sí puede ejecutar check_in_reservation_with_guests');

select ok(not has_function_privilege('anon', 'public.add_reservation_companions(uuid,jsonb)', 'execute'),
  'anon no puede ejecutar add_reservation_companions');
select ok(not has_function_privilege('authenticated', 'public.add_reservation_companions(uuid,jsonb)', 'execute'),
  'add_reservation_companions es interna: tampoco la ejecuta authenticated directo');

select ok(not has_function_privilege('anon', 'public.add_guests_to_stay(uuid,jsonb,numeric,text)', 'execute'),
  'anon no puede ejecutar add_guests_to_stay');
select ok(has_function_privilege('authenticated', 'public.add_guests_to_stay(uuid,jsonb,numeric,text)', 'execute'),
  'authenticated sí puede ejecutar add_guests_to_stay');


select * from finish();
rollback;
