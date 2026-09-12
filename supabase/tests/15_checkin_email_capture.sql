-- =====================================================================
-- Check-in: captura de correo del titular ("Acepta recibir promociones
-- por correo" no tenía dónde guardar la dirección). change:
-- reservation-booker-vs-guest, PR8 (decisión #316). Ver
-- 20260911080000_checkin_email_capture.sql.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
select is(current_user_role(), 'root', 'fixture: sesión con rol root');


-- ---------------------------------------------------------------------
-- 1) Titular sin correo cargado -> se guarda el correo dado.
-- ---------------------------------------------------------------------
do $$
declare
  v_room_id      uuid;
  v_room_type_id uuid;
  v_res_id       uuid;
  v_guest_id     uuid;
  v_email        text;
begin
  select o.room_id, o.room_type_id into v_room_id, v_room_type_id
  from public.room_type_options o
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where not exists (
    select 1 from public.reservations x where x.room_id = o.room_id
      and x.status in ('confirmed','checked_in')
      and x.check_in_date < '2033-01-05' and '2033-01-01' < x.check_out_date
  ) limit 1;

  v_res_id := public.create_reservation(
    v_room_id, v_room_type_id, 'SinCorreo', 'Titular',
    '70000020', null, '2033-01-01', '2033-01-05', 1, 'phone'
  );

  perform public.check_in_reservation_with_guests(
    p_reservation_id => v_res_id, p_document => '90000020', p_birth_date => null::date,
    p_country_code => 'BO', p_city => 'La Paz', p_wants_offers => true,
    p_email => 'nueva@example.com'
  );

  select guest_id into v_guest_id from public.reservations where id = v_res_id;
  select email into v_email from public.people where id = v_guest_id;
  if v_email <> 'nueva@example.com' then
    raise exception 'se esperaba que el correo del titular quedara guardado, quedó: %', v_email;
  end if;
end $$;
select pass('titular sin correo cargado: el correo dado en el check-in queda guardado');


-- ---------------------------------------------------------------------
-- 2) p_email en blanco/NULL no borra un correo ya cargado.
-- ---------------------------------------------------------------------
do $$
declare
  v_room_id      uuid;
  v_room_type_id uuid;
  v_res_id       uuid;
  v_guest_id     uuid;
  v_email        text;
begin
  select o.room_id, o.room_type_id into v_room_id, v_room_type_id
  from public.room_type_options o
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where not exists (
    select 1 from public.reservations x where x.room_id = o.room_id
      and x.status in ('confirmed','checked_in')
      and x.check_in_date < '2033-02-05' and '2033-02-01' < x.check_out_date
  ) limit 1;

  v_res_id := public.create_reservation(
    v_room_id, v_room_type_id, 'ConCorreo', 'Titular',
    '70000021', null, '2033-02-01', '2033-02-05', 1, 'phone'
  );

  select guest_id into v_guest_id from public.reservations where id = v_res_id;
  update public.people set email = 'previo@example.com' where id = v_guest_id;

  perform public.check_in_reservation_with_guests(
    p_reservation_id => v_res_id, p_document => '90000021', p_birth_date => null::date,
    p_country_code => 'BO', p_city => 'La Paz', p_wants_offers => false,
    p_email => '   '
  );

  select email into v_email from public.people where id = v_guest_id;
  if v_email <> 'previo@example.com' then
    raise exception 'un p_email en blanco no debía tocar el correo ya cargado, quedó: %', v_email;
  end if;
end $$;
select pass('p_email en blanco/NULL deja intacto el correo ya cargado');


-- ---------------------------------------------------------------------
-- 3) Correo que ya pertenece a OTRA persona -> mensaje claro en
--    español, nunca la violación cruda (23505).
-- ---------------------------------------------------------------------
do $$
declare
  v_room_id       uuid;
  v_room_type_id  uuid;
  v_res_id        uuid;
  v_other_person  uuid;
begin
  insert into public.people (first_name, last_name, email)
  values ('Ya', 'Registrado', 'ocupado@example.com')
  returning id into v_other_person;

  select o.room_id, o.room_type_id into v_room_id, v_room_type_id
  from public.room_type_options o
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where not exists (
    select 1 from public.reservations x where x.room_id = o.room_id
      and x.status in ('confirmed','checked_in')
      and x.check_in_date < '2033-03-05' and '2033-03-01' < x.check_out_date
  ) limit 1;

  v_res_id := public.create_reservation(
    v_room_id, v_room_type_id, 'CorreoDuplicado', 'Titular',
    '70000022', null, '2033-03-01', '2033-03-05', 1, 'phone'
  );

  begin
    perform public.check_in_reservation_with_guests(
      p_reservation_id => v_res_id, p_document => '90000022', p_birth_date => null::date,
      p_country_code => 'BO', p_city => 'La Paz', p_wants_offers => true,
      p_email => 'ocupado@example.com'
    );
    raise exception 'no debió permitir un correo que ya pertenece a otra persona';
  exception when others then
    if sqlerrm <> 'Ese correo ya está registrado para otro huésped' then
      raise;
    end if;
  end;
end $$;
select pass('correo ya usado por otra persona: rechazado con el mensaje exacto en español, no 23505 crudo');


-- ---------------------------------------------------------------------
-- 4) Bulk: check-in del holder de room1 con correo nuevo NUNCA toca la
--    ficha del contacto de la booking (mismo aislamiento que el resto
--    de la función).
-- ---------------------------------------------------------------------
do $$
declare
  v_rooms        jsonb;
  v_room1        uuid; v_type1 uuid;
  v_result       jsonb;
  v_res1         uuid;
  v_contact_id   uuid;
  v_booking_id   uuid;
  v_contact_mail text;
begin
  select o.room_id, o.room_type_id into v_room1, v_type1
  from public.room_type_options o
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where not exists (
    select 1 from public.reservations x where x.room_id = o.room_id
      and x.status in ('confirmed','checked_in')
      and x.check_in_date < '2033-04-05' and '2033-04-01' < x.check_out_date
  ) limit 1;

  v_rooms := jsonb_build_array(
    jsonb_build_object('room_id', v_room1, 'room_type_id', v_type1, 'num_guests', 1)
  );

  v_result := public.create_bulk_reservation(
    v_rooms, 'ContactoBulk', 'Correo', '70000023', null, '2033-04-01', '2033-04-05', 'phone'
  );
  v_res1 := ((v_result->'created')->>0)::uuid;

  select booking_id into v_booking_id from public.reservations where id = v_res1;
  select contact_person_id into v_contact_id from public.bookings where id = v_booking_id;

  perform public.check_in_reservation_with_guests(
    p_reservation_id => v_res1, p_document => '90000023', p_birth_date => null::date,
    p_country_code => 'BO', p_city => 'La Paz', p_wants_offers => true,
    p_holder_first_name => 'Sala1Bulk', p_holder_last_name => 'Titular',
    p_email => 'holder-bulk@example.com'
  );

  select email into v_contact_mail from public.people where id = v_contact_id;
  if v_contact_mail is not null then
    raise exception 'el correo del check-in se escribió en la ficha del CONTACTO, no del titular';
  end if;
end $$;
select pass('bulk: el correo del check-in se guarda en el titular, nunca en el contacto de la booking');


-- ---------------------------------------------------------------------
-- 5) Higiene de grants: anon no puede ejecutar la función re-creada.
-- ---------------------------------------------------------------------
select ok(not has_function_privilege('anon',
  'public.check_in_reservation_with_guests(uuid,text,date,text,text,boolean,text,text,text,text,jsonb,text,text,text,text,uuid,text,text)',
  'execute'),
  'anon no puede ejecutar check_in_reservation_with_guests tras la migración de correo');
select ok(has_function_privilege('authenticated',
  'public.check_in_reservation_with_guests(uuid,text,date,text,text,boolean,text,text,text,text,jsonb,text,text,text,text,uuid,text,text)',
  'execute'),
  'authenticated sí puede ejecutar check_in_reservation_with_guests tras la migración de correo');


select * from finish();
rollback;
