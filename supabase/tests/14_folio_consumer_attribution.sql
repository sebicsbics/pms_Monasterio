-- =====================================================================
-- Extras/incidentales atribuidos al huésped que los consumió y al
-- empleado que los cargó. (change: reservation-booker-vs-guest, PR5,
-- 8/8). Ver 20260911060000_folio_consumer_attribution.sql.
--
-- add_folio_charge/add_folio_product_charge cambian de aridad: ganan
-- p_consumer_person_id (obligatorio). El trigger
-- folio_charges_consumer_is_occupant valida -- vía BEFORE INSERT/UPDATE,
-- no CHECK, porque Postgres no permite subconsultas en CHECK -- que el
-- consumidor sea un ocupante activo de esa estadía.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(16);

select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
select is(current_user_role(), 'root', 'fixture: sesión con rol root');

-- ---------------------------------------------------------------------
-- 0) Esquema.
-- ---------------------------------------------------------------------
select has_column('folio_charges', 'consumer_person_id', 'folio_charges.consumer_person_id existe');
select has_column('folio_charges', 'created_by', 'folio_charges.created_by existe');
select col_is_null('folio_charges', 'consumer_person_id', 'consumer_person_id es nullable (filas legacy)');
select ok(
  exists (
    select 1 from pg_trigger
    where tgname = 'folio_charges_consumer_is_occupant'
      and tgrelid = 'public.folio_charges'::regclass
  ),
  'existe el trigger folio_charges_consumer_is_occupant'
);

-- ---------------------------------------------------------------------
-- 1) Cargo a un NO ocupante de la estadía -> rechazado.
-- ---------------------------------------------------------------------
do $$
declare
  v_room_id uuid; v_room_type_id uuid; v_res_id uuid; v_outsider uuid;
begin
  select o.room_id, o.room_type_id into v_room_id, v_room_type_id
  from public.room_type_options o
  join public.room_types rt on rt.id = o.room_type_id and rt.max_occupancy = 2
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where not exists (
    select 1 from public.reservations x where x.room_id = o.room_id
      and x.status in ('confirmed','checked_in')
      and x.check_in_date < '2033-05-05' and '2033-05-01' < x.check_out_date
  ) order by o.room_id limit 1;

  v_res_id := public.create_reservation(
    v_room_id, v_room_type_id, 'Folio', 'Rechazo',
    '70000030', null, '2033-05-01', '2033-05-05', 1, 'phone'
  );
  perform public.check_in_reservation_with_guests(
    p_reservation_id => v_res_id, p_document => '90000030', p_birth_date => null::date,
    p_country_code => 'BO', p_city => 'La Paz', p_wants_offers => false
  );

  -- Persona que existe en el sistema pero NO está alojada en esta estadía.
  select p.id into v_outsider
  from public.people p
  where not exists (
    select 1 from public.reservations r2 where r2.guest_id = p.id and r2.status = 'checked_in'
  ) and not exists (
    select 1 from public.reservation_guests rg2 where rg2.person_id = p.id
      and rg2.reservation_id = v_res_id
  )
  limit 1;

  begin
    perform public.add_folio_charge(v_room_id, 'Spa', 100, v_outsider);
    raise exception 'no debió permitir cargar el consumo a un no-ocupante';
  exception when others then
    if sqlerrm <> 'El huésped indicado no está alojado en esta habitación' then
      raise;
    end if;
  end;
end $$;
select pass('add_folio_charge: cargo a un no-ocupante rechazado con el mensaje exacto');

-- ---------------------------------------------------------------------
-- 2) Cargo a un ocupante ACTIVO -> éxito, consumer_person_id + created_by
--    registrados.
-- ---------------------------------------------------------------------
do $$
declare
  v_room_id uuid; v_room_type_id uuid; v_res_id uuid; v_holder uuid; v_charge_id uuid;
  v_charge record;
begin
  select o.room_id, o.room_type_id into v_room_id, v_room_type_id
  from public.room_type_options o
  join public.room_types rt on rt.id = o.room_type_id and rt.max_occupancy = 2
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where not exists (
    select 1 from public.reservations x where x.room_id = o.room_id
      and x.status in ('confirmed','checked_in')
      and x.check_in_date < '2033-05-10' and '2033-05-06' < x.check_out_date
  ) order by o.room_id limit 1;

  v_res_id := public.create_reservation(
    v_room_id, v_room_type_id, 'Folio', 'Exito',
    '70000031', null, '2033-05-06', '2033-05-10', 1, 'phone'
  );
  perform public.check_in_reservation_with_guests(
    p_reservation_id => v_res_id, p_document => '90000031', p_birth_date => null::date,
    p_country_code => 'BO', p_city => 'La Paz', p_wants_offers => false
  );

  select guest_id into v_holder from public.reservations where id = v_res_id;

  v_charge_id := public.add_folio_charge(v_room_id, 'Restaurante', 80, v_holder);

  select * into v_charge from public.folio_charges where id = v_charge_id;
  if v_charge.consumer_person_id <> v_holder then
    raise exception 'se esperaba consumer_person_id = titular';
  end if;
  if v_charge.created_by is null then
    raise exception 'se esperaba created_by seteado (auth.uid())';
  end if;
end $$;
select pass('add_folio_charge: cargo al titular ocupante registra consumer_person_id + created_by');

-- ---------------------------------------------------------------------
-- 3) add_folio_product_charge: mismo tratamiento (arity nueva confirma
--    el DROP+CREATE, no solo un default silencioso).
-- ---------------------------------------------------------------------
do $$
declare
  v_room_id uuid; v_room_type_id uuid; v_res_id uuid; v_holder uuid; v_product uuid;
  v_charge_id uuid; v_charge record;
begin
  select o.room_id, o.room_type_id into v_room_id, v_room_type_id
  from public.room_type_options o
  join public.room_types rt on rt.id = o.room_type_id and rt.max_occupancy = 2
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where not exists (
    select 1 from public.reservations x where x.room_id = o.room_id
      and x.status in ('confirmed','checked_in')
      and x.check_in_date < '2033-05-15' and '2033-05-11' < x.check_out_date
  ) order by o.room_id limit 1;

  v_res_id := public.create_reservation(
    v_room_id, v_room_type_id, 'Folio', 'Producto',
    '70000032', null, '2033-05-11', '2033-05-15', 1, 'phone'
  );
  perform public.check_in_reservation_with_guests(
    p_reservation_id => v_res_id, p_document => '90000032', p_birth_date => null::date,
    p_country_code => 'BO', p_city => 'La Paz', p_wants_offers => false
  );
  select guest_id into v_holder from public.reservations where id = v_res_id;
  select id into v_product from public.products where current_stock > 0 limit 1;

  v_charge_id := public.add_folio_product_charge(v_room_id, v_product, 1, v_holder);

  select * into v_charge from public.folio_charges where id = v_charge_id;
  if v_charge.consumer_person_id <> v_holder then
    raise exception 'se esperaba consumer_person_id = titular en add_folio_product_charge';
  end if;
end $$;
select pass('add_folio_product_charge: registra consumer_person_id');

-- ---------------------------------------------------------------------
-- 4) Sin consumidor -> ambas RPC lo exigen.
-- ---------------------------------------------------------------------
do $$
declare
  v_room_id uuid;
begin
  select room_id into v_room_id from public.reservations where status = 'checked_in' limit 1;
  begin
    perform public.add_folio_charge(v_room_id, 'Sin consumidor', 10, null);
    raise exception 'no debió permitir un cargo sin consumidor';
  exception when others then
    if sqlerrm <> 'Debe indicar el huésped que consume este cargo' then
      raise;
    end if;
  end;
end $$;
select pass('add_folio_charge: exige consumer_person_id');

-- ---------------------------------------------------------------------
-- 5) Filas legacy (consumer_person_id NULL, insertadas directo, no vía
--    RPC) no se ven afectadas por el trigger.
-- ---------------------------------------------------------------------
do $$
declare
  v_folio_id uuid; v_charge_id uuid;
begin
  select f.id into v_folio_id
  from public.folios f join public.reservations r on r.id = f.reservation_id
  where r.status = 'checked_in' limit 1;

  insert into public.folio_charges (folio_id, description, amount_bs)
  values (v_folio_id, 'Cargo legacy sin consumidor', 5)
  returning id into v_charge_id;

  if not exists (select 1 from public.folio_charges where id = v_charge_id and consumer_person_id is null) then
    raise exception 'una fila legacy sin consumer_person_id debía insertarse sin error';
  end if;
end $$;
select pass('trigger: no bloquea inserciones legacy con consumer_person_id NULL');

-- ---------------------------------------------------------------------
-- 6) Regresión: invariante permanente (PR1) + EXCLUDE de solapamiento
--    (PR3) siguen vigentes.
-- ---------------------------------------------------------------------
select is(
  (select count(*) from public.reservations where status = 'checked_in' and guest_id is null),
  0::bigint,
  'invariante permanente: ninguna reserva checked_in tiene guest_id NULL'
);
select ok(
  exists (
    select 1 from pg_constraint
    where conname = 'reservation_guests_no_overlap'
      and conrelid = 'public.reservation_guests'::regclass
  ),
  'regresión PR3: sigue existiendo el EXCLUDE reservation_guests_no_overlap'
);

-- ---------------------------------------------------------------------
-- 7) Higiene de grants (arity nueva).
-- ---------------------------------------------------------------------
select ok(not has_function_privilege('anon',
    'public.add_folio_charge(uuid,text,numeric,uuid)', 'execute'),
  'anon no puede ejecutar add_folio_charge (arity nueva)');
select ok(has_function_privilege('authenticated',
    'public.add_folio_charge(uuid,text,numeric,uuid)', 'execute'),
  'authenticated sí puede ejecutar add_folio_charge (arity nueva)');
select ok(not has_function_privilege('anon',
    'public.add_folio_product_charge(uuid,uuid,numeric,uuid)', 'execute'),
  'anon no puede ejecutar add_folio_product_charge (arity nueva)');
select ok(has_function_privilege('authenticated',
    'public.add_folio_product_charge(uuid,uuid,numeric,uuid)', 'execute'),
  'authenticated sí puede ejecutar add_folio_product_charge (arity nueva)');

select * from finish();
rollback;
