-- =====================================================================
-- Sobre-ocupación permitida solo con motivo obligatorio. (change:
-- reservation-booker-vs-guest, PR4, 7/8). Ver
-- 20260911050000_occupancy_override_reason.sql.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(17);

select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
select is(current_user_role(), 'root', 'fixture: sesión con rol root');


-- ---------------------------------------------------------------------
-- 0) Esquema: occupancy_overrides.
-- ---------------------------------------------------------------------
select has_table('public', 'occupancy_overrides', 'occupancy_overrides existe');
select has_column('public', 'occupancy_overrides', 'reason', 'tiene columna reason');
select col_not_null('public', 'occupancy_overrides', 'reason', 'reason es NOT NULL');


-- ---------------------------------------------------------------------
-- 1) check_in_reservation_with_guests: sobre-ocupación sin motivo ->
--    rechazada con el mensaje exacto. 'Simple Estándar' admite 1;
--    titular + 1 acompañante = 2.
-- ---------------------------------------------------------------------
do $$
declare
  v_room_id uuid; v_room_type_id uuid; v_res_id uuid;
begin
  select o.room_id, o.room_type_id into v_room_id, v_room_type_id
  from public.room_type_options o
  join public.room_types rt on rt.id = o.room_type_id and rt.max_occupancy = 1
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where not exists (
    select 1 from public.reservations x where x.room_id = o.room_id
      and x.status in ('confirmed','checked_in')
      and x.check_in_date < '2033-01-05' and '2033-01-01' < x.check_out_date
  ) order by o.room_id limit 1;

  v_res_id := public.create_reservation(
    v_room_id, v_room_type_id, 'Sin', 'Motivo',
    '70000020', null, '2033-01-01', '2033-01-05', 1, 'phone'
  );

  begin
    perform public.check_in_reservation_with_guests(
      p_reservation_id => v_res_id, p_document => '90000010', p_birth_date => null::date,
      p_country_code => 'BO', p_city => 'La Paz', p_wants_offers => false,
      p_companions => jsonb_build_array(
        jsonb_build_object('first_name','Extra','last_name','Huésped')
      )
    );
    raise exception 'no debió permitir la sobre-ocupación sin motivo';
  exception when others then
    if sqlerrm <> 'La habitación admite 1 huésped(es); estás registrando 2. Indique un motivo para exceder el límite.' then
      raise;
    end if;
  end;
end $$;
select pass('check-in: sobre-ocupación sin motivo rechazada con el mensaje exacto');


-- ---------------------------------------------------------------------
-- 2) check_in_reservation_with_guests: con motivo -> éxito inmediato,
--    fila de auditoría con created_by.
-- ---------------------------------------------------------------------
do $$
declare
  v_room_id uuid; v_room_type_id uuid; v_res_id uuid;
  v_override record;
begin
  select o.room_id, o.room_type_id into v_room_id, v_room_type_id
  from public.room_type_options o
  join public.room_types rt on rt.id = o.room_type_id and rt.max_occupancy = 1
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where not exists (
    select 1 from public.reservations x where x.room_id = o.room_id
      and x.status in ('confirmed','checked_in')
      and x.check_in_date < '2033-01-10' and '2033-01-06' < x.check_out_date
  ) order by o.room_id limit 1;

  v_res_id := public.create_reservation(
    v_room_id, v_room_type_id, 'Con', 'Motivo',
    '70000021', null, '2033-01-06', '2033-01-10', 1, 'phone'
  );

  perform public.check_in_reservation_with_guests(
    p_reservation_id => v_res_id, p_document => '90000011', p_birth_date => null::date,
    p_country_code => 'BO', p_city => 'La Paz', p_wants_offers => false,
    p_companions => jsonb_build_array(
      jsonb_build_object('first_name','Extra','last_name','Huésped2')
    ),
    p_occupancy_reason => 'Cuna adicional para bebé'
  );

  if not exists (
    select 1 from public.reservations where id = v_res_id and status = 'checked_in'
  ) then
    raise exception 'el check-in con motivo debía completarse de inmediato (sin aprobación)';
  end if;

  select * into v_override from public.occupancy_overrides where reservation_id = v_res_id;
  if v_override.reason <> 'Cuna adicional para bebé' then
    raise exception 'se esperaba la fila de auditoría con el motivo indicado';
  end if;
  if v_override.max_occupancy <> 1 or v_override.resulting_occupancy <> 2 then
    raise exception 'la fila de auditoría no registró max/resulting occupancy correctos';
  end if;
  if v_override.created_by is null then
    raise exception 'se esperaba created_by seteado (auth.uid() del que hizo el check-in)';
  end if;
end $$;
select pass('check-in: sobre-ocupación con motivo, éxito inmediato + fila de auditoría con created_by');


-- ---------------------------------------------------------------------
-- 3) Dentro del máximo: no se pide motivo, no se inserta fila.
-- ---------------------------------------------------------------------
do $$
declare
  v_room_id uuid; v_room_type_id uuid; v_res_id uuid;
  v_count int;
begin
  select o.room_id, o.room_type_id into v_room_id, v_room_type_id
  from public.room_type_options o
  join public.room_types rt on rt.id = o.room_type_id and rt.max_occupancy = 2
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where not exists (
    select 1 from public.reservations x where x.room_id = o.room_id
      and x.status in ('confirmed','checked_in')
      and x.check_in_date < '2033-01-15' and '2033-01-11' < x.check_out_date
  ) order by o.room_id limit 1;

  v_res_id := public.create_reservation(
    v_room_id, v_room_type_id, 'Dentro', 'DelMax',
    '70000022', null, '2033-01-11', '2033-01-15', 1, 'phone'
  );

  perform public.check_in_reservation_with_guests(
    p_reservation_id => v_res_id, p_document => '90000012', p_birth_date => null::date,
    p_country_code => 'BO', p_city => 'La Paz', p_wants_offers => false,
    p_companions => jsonb_build_array(
      jsonb_build_object('first_name','Acomp','last_name','Ante')
    )
  );

  select count(*) into v_count from public.occupancy_overrides where reservation_id = v_res_id;
  if v_count <> 0 then
    raise exception 'dentro del máximo no debía crearse fila de auditoría';
  end if;
end $$;
select pass('check-in: dentro del máximo, sin motivo pedido y sin fila de auditoría');


-- ---------------------------------------------------------------------
-- 4) walk_in_check_in_with_guests: sobre-ocupación sin motivo rechazada,
--    con motivo registra la fila.
-- ---------------------------------------------------------------------
do $$
declare
  v_room_id uuid; v_room_type_id uuid; v_res_id uuid;
  v_count int;
begin
  select o.room_id, o.room_type_id into v_room_id, v_room_type_id
  from public.room_type_options o
  join public.room_types rt on rt.id = o.room_type_id and rt.max_occupancy = 1
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where not exists (
    select 1 from public.reservations x where x.room_id = o.room_id
      and x.status in ('confirmed','checked_in')
      and x.check_in_date < '2033-02-05' and '2033-02-01' < x.check_out_date
  ) order by o.room_id limit 1;

  begin
    perform public.walk_in_check_in_with_guests(
      v_room_id, v_room_type_id, 'Walkin', 'SinMotivo', '90000013', null,
      null::date, 'BO', 'La Paz', false, 4, null, null, null, null, null, null,
      jsonb_build_array(jsonb_build_object('first_name','Extra','last_name','Walkin'))
    );
    raise exception 'no debió permitir walk-in con sobre-ocupación sin motivo';
  exception when others then
    if sqlerrm <> 'La habitación admite 1 huésped(es); estás registrando 2. Indique un motivo para exceder el límite.' then
      raise;
    end if;
  end;

  v_res_id := public.walk_in_check_in_with_guests(
    v_room_id, v_room_type_id, 'Walkin', 'ConMotivo', '90000014', null,
    null::date, 'BO', 'La Paz', false, 4, null, null, null, null, null, null,
    jsonb_build_array(jsonb_build_object('first_name','Extra','last_name','Walkin2')),
    null, null, 'Colchón adicional'
  );

  select count(*) into v_count from public.occupancy_overrides where reservation_id = v_res_id;
  if v_count <> 1 then
    raise exception 'walk-in con motivo debía registrar exactamente una fila de auditoría';
  end if;
end $$;
select pass('walk-in: sobre-ocupación sin motivo rechazada, con motivo registra fila de auditoría');


-- ---------------------------------------------------------------------
-- 5) add_guests_to_stay: sobre-ocupación sin motivo rechazada, con
--    motivo registra la fila.
-- ---------------------------------------------------------------------
do $$
declare
  v_room_id uuid; v_room_type_id uuid; v_res_id uuid;
  v_count int;
begin
  select o.room_id, o.room_type_id into v_room_id, v_room_type_id
  from public.room_type_options o
  join public.room_types rt on rt.id = o.room_type_id and rt.max_occupancy = 1
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where not exists (
    select 1 from public.reservations x where x.room_id = o.room_id
      and x.status in ('confirmed','checked_in')
      and x.check_in_date < '2033-02-10' and '2033-02-06' < x.check_out_date
  ) order by o.room_id limit 1;

  v_res_id := public.walk_in_check_in_with_guests(
    v_room_id, v_room_type_id, 'Estadía', 'Activa', '90000015', null,
    null::date, 'BO', 'La Paz', false, 4
  );

  begin
    perform public.add_guests_to_stay(
      v_room_id,
      jsonb_build_array(jsonb_build_object('first_name','Suma','last_name','SinMotivo')),
      0, null
    );
    raise exception 'no debió permitir add_guests_to_stay con sobre-ocupación sin motivo';
  exception when others then
    if sqlerrm <> 'La habitación admite 1 huésped(es); estás registrando 2. Indique un motivo para exceder el límite.' then
      raise;
    end if;
  end;

  perform public.add_guests_to_stay(
    v_room_id,
    jsonb_build_array(jsonb_build_object('first_name','Suma','last_name','ConMotivo')),
    0, null, 'Familiar llegó después'
  );

  select count(*) into v_count from public.occupancy_overrides where reservation_id = v_res_id;
  if v_count <> 1 then
    raise exception 'add_guests_to_stay con motivo debía registrar exactamente una fila de auditoría';
  end if;
end $$;
select pass('add_guests_to_stay: sobre-ocupación sin motivo rechazada, con motivo registra fila de auditoría');


-- ---------------------------------------------------------------------
-- 6) create_bulk_reservation: motivo por habitación (occupancy_reason
--    dentro de cada elemento). Sin motivo rechaza esa habitación
--    (queda en failed); con motivo se crea y registra auditoría.
-- ---------------------------------------------------------------------
do $$
declare
  v_room1 uuid; v_type1 uuid;
  v_room2 uuid; v_type2 uuid;
  v_rooms jsonb;
  v_result jsonb;
  v_res2 uuid;
  v_count int;
  v_failed_err text;
begin
  select o.room_id, o.room_type_id into v_room1, v_type1
  from public.room_type_options o
  join public.room_types rt on rt.id = o.room_type_id and rt.max_occupancy = 1
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where not exists (
    select 1 from public.reservations x where x.room_id = o.room_id
      and x.status in ('confirmed','checked_in')
      and x.check_in_date < '2033-03-05' and '2033-03-01' < x.check_out_date
  ) order by o.room_id limit 1;

  select o.room_id, o.room_type_id into v_room2, v_type2
  from public.room_type_options o
  join public.room_types rt on rt.id = o.room_type_id and rt.max_occupancy = 1
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where o.room_id <> v_room1
    and not exists (
      select 1 from public.reservations x where x.room_id = o.room_id
        and x.status in ('confirmed','checked_in')
        and x.check_in_date < '2033-03-05' and '2033-03-01' < x.check_out_date
    ) order by o.room_id limit 1;

  v_rooms := jsonb_build_array(
    jsonb_build_object('room_id', v_room1, 'room_type_id', v_type1, 'num_guests', 2),
    jsonb_build_object(
      'room_id', v_room2, 'room_type_id', v_type2, 'num_guests', 2,
      'occupancy_reason', 'Familia con bebé en cuna'
    )
  );

  v_result := public.create_bulk_reservation(
    v_rooms, 'Grupo', 'Bulk', '70000023', null, '2033-03-01', '2033-03-05', 'phone'
  );

  if jsonb_array_length(v_result->'created') <> 1 then
    raise exception 'se esperaba exactamente 1 habitación creada (la que trae motivo)';
  end if;
  if jsonb_array_length(v_result->'failed') <> 1 then
    raise exception 'se esperaba exactamente 1 habitación fallida (la que no trae motivo)';
  end if;

  v_failed_err := (v_result->'failed'->0->>'error');
  if v_failed_err <> 'La habitación admite 1 huésped(es); estás registrando 2. Indique un motivo para exceder el límite.' then
    raise exception 'el motivo de falla no fue el mensaje exacto de sobre-ocupación';
  end if;

  v_res2 := ((v_result->'created')->>0)::uuid;
  select count(*) into v_count from public.occupancy_overrides where reservation_id = v_res2;
  if v_count <> 1 then
    raise exception 'la habitación con motivo debía registrar exactamente una fila de auditoría';
  end if;
end $$;
select pass('create_bulk_reservation: motivo por habitación -- sin motivo falla esa habitación, con motivo la crea y audita');


-- ---------------------------------------------------------------------
-- 7) Regresión: el techo de sanity de 20 personas por habitación sigue
--    vigente, sin relación con el motivo.
-- ---------------------------------------------------------------------
do $$
declare
  v_room1 uuid; v_type1 uuid;
  v_rooms jsonb;
  v_result jsonb;
  v_failed_err text;
begin
  select o.room_id, o.room_type_id into v_room1, v_type1
  from public.room_type_options o
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where not exists (
    select 1 from public.reservations x where x.room_id = o.room_id
      and x.status in ('confirmed','checked_in')
      and x.check_in_date < '2033-04-05' and '2033-04-01' < x.check_out_date
  ) order by o.room_id limit 1;

  v_rooms := jsonb_build_array(
    jsonb_build_object(
      'room_id', v_room1, 'room_type_id', v_type1, 'num_guests', 21,
      'occupancy_reason', 'Igual debe fallar por el techo de 20'
    )
  );

  v_result := public.create_bulk_reservation(
    v_rooms, 'Cap', 'Sanity', '70000024', null, '2033-04-01', '2033-04-05', 'phone'
  );

  if jsonb_array_length(v_result->'created') <> 0 then
    raise exception 'no debió crearse: 21 personas supera el techo de sanity de 20';
  end if;

  v_failed_err := (v_result->'failed'->0->>'error');
  if v_failed_err !~ 'implausible' then
    raise exception 'se esperaba el mensaje de ocupación implausible del techo de 20, aunque hubiera motivo';
  end if;
end $$;
select pass('create_bulk_reservation: el techo de sanity de 20 personas sigue vigente, el motivo no lo evita');


-- ---------------------------------------------------------------------
-- 8) Higiene de grants (funciones re-creadas en esta migración) + RLS de
--    la tabla nueva.
-- ---------------------------------------------------------------------
select ok(not has_function_privilege('anon',
    'public.check_in_reservation_with_guests(uuid,text,date,text,text,boolean,text,text,text,text,jsonb,text,text,text,text,uuid,text)',
    'execute'),
  'anon no puede ejecutar check_in_reservation_with_guests (arity nueva)');
select ok(has_function_privilege('authenticated',
    'public.check_in_reservation_with_guests(uuid,text,date,text,text,boolean,text,text,text,text,jsonb,text,text,text,text,uuid,text)',
    'execute'),
  'authenticated sí puede ejecutar check_in_reservation_with_guests (arity nueva)');

select ok(not has_function_privilege('anon',
    'public.walk_in_check_in_with_guests(uuid,uuid,text,text,text,text,date,text,text,boolean,integer,numeric,text,text,text,text,text,jsonb,text,text,text)',
    'execute'),
  'anon no puede ejecutar walk_in_check_in_with_guests (arity nueva)');

select ok(not has_function_privilege('anon',
    'public.add_guests_to_stay(uuid,jsonb,numeric,text,text)', 'execute'),
  'anon no puede ejecutar add_guests_to_stay (arity nueva)');

select ok(not has_function_privilege('anon',
    'public.create_bulk_reservation(jsonb,text,text,text,text,date,date,text,numeric,text)', 'execute'),
  'anon no puede ejecutar create_bulk_reservation');

select ok(not has_table_privilege('anon', 'public.occupancy_overrides', 'select'),
  'anon no tiene ni siquiera privilegio de SELECT sobre occupancy_overrides');


select * from finish();
rollback;
