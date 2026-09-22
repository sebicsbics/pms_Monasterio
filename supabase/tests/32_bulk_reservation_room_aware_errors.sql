-- =====================================================================
-- create_bulk_reservation: los mensajes de error POR HABITACIÓN, dentro
-- del loop, nombran rooms.room_number (change:
-- fix/bulk-headcount-room-type-and-errors, DEFECT 3b). Antes usaban el
-- UUID interno de la habitación (courtesy, num_guests en modo persona)
-- o ni siquiera lo mencionaban (guests<1, guests>20, tipo no
-- corresponde, habitación ocupada). Para payer_mode='client' esto
-- importa doblemente: el `raise;` (feat/booking-12, atomicidad
-- todo-o-nada) hace que ese mensaje CRUDO sea exactamente lo que ve la
-- pantalla, sin ningún fallback de nombre de habitación (ver
-- BulkReservation.tsx, roomNumberOf sólo cubre el camino best-effort de
-- each_stay).
--
-- Ver también 20260922120000_bulk_reservation_room_aware_errors.sql:
-- reescritura de SOLO EL CUERPO (misma firma, sin DROP) -- ver 21_
-- function_grants_allowlist.sql para la cobertura de que los GRANTS no
-- cambiaron.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
select is(current_user_role(), 'root', 'fixture: sesión con rol root');

-- ---------------------------------------------------------------------
-- Fixtures propios: dos room_types NUEVOS y una habitación física NUEVA
-- con AMBOS como fichas de room_type_options (pool "aliased", el
-- corazón de DEFECT 2/3b -- una misma habitación vendible a más de un
-- precio/capacidad, como la habitación 7 real: Simple Estándar 1px vs.
-- Matrimonial 2px).
-- ---------------------------------------------------------------------
do $$
declare
  v_type_small uuid; v_type_big uuid; v_room uuid;
begin
  insert into public.room_types (name, base_price_bs, max_occupancy)
  values ('Fixture RAE Simple', 111, 1) returning id into v_type_small;
  insert into public.room_types (name, base_price_bs, max_occupancy)
  values ('Fixture RAE Matrimonial', 222, 2) returning id into v_type_big;

  insert into public.rooms (room_number, floor, room_type_id, operational_status)
  values ('RAE-1', 9, v_type_small, 'available') returning id into v_room;
  insert into public.room_type_options (room_id, room_type_id) values (v_room, v_type_small);
  insert into public.room_type_options (room_id, room_type_id) values (v_room, v_type_big);

  create temp table fixture_rae as
    select v_room as room_id, v_type_small as type_small, v_type_big as type_big;
end $$;

-- Cuenta por cobrar para los escenarios payer_mode='client'.
do $$
declare v_account uuid;
begin
  insert into public.receivable_accounts (name, kind) values ('Fixture RAE Cuenta', 'empresa')
    returning id into v_account;
  create temp table fixture_rae_account as select v_account as account_id;
end $$;

-- ---------------------------------------------------------------------
-- 1) Cortesía sin motivo -> nombra la habitación por su room_number.
-- ---------------------------------------------------------------------
do $$
declare v_room_id uuid; v_room_number text; v_account uuid; v_type_small uuid;
begin
  select room_id, type_small into v_room_id, v_type_small from fixture_rae;
  select room_number into v_room_number from public.rooms where id = v_room_id;
  select account_id into v_account from fixture_rae_account;

  begin
    perform public.create_bulk_reservation(
      p_rooms => jsonb_build_array(jsonb_build_object(
        'room_id', v_room_id, 'room_type_id', v_type_small, 'num_guests', 1,
        'is_courtesy', true
      )),
      p_first_name => 'Rae', p_last_name => 'Uno', p_phone => '70000031', p_email => null,
      p_check_in => '2034-01-01', p_check_out => '2034-01-03', p_method => 'phone',
      p_payer_mode => 'client', p_rate_mode => 'room', p_receivable_account_id => v_account
    );
    raise exception 'no debió permitir cortesía sin motivo';
  exception when others then
    if sqlerrm <> format('La cortesía requiere un motivo (habitación %s)', v_room_number) then
      raise;
    end if;
  end;
end $$;
select pass('cortesía sin motivo nombra la habitación por su room_number');

-- ---------------------------------------------------------------------
-- 2) rate_mode='person' sin num_guests -> nombra la habitación.
-- ---------------------------------------------------------------------
do $$
declare v_room_id uuid; v_room_number text; v_account uuid; v_type_small uuid;
begin
  select room_id, type_small into v_room_id, v_type_small from fixture_rae;
  select room_number into v_room_number from public.rooms where id = v_room_id;
  select account_id into v_account from fixture_rae_account;

  begin
    perform public.create_bulk_reservation(
      p_rooms => jsonb_build_array(jsonb_build_object(
        'room_id', v_room_id, 'room_type_id', v_type_small
      )),
      p_first_name => 'Rae', p_last_name => 'Dos', p_phone => '70000032', p_email => null,
      p_check_in => '2034-01-01', p_check_out => '2034-01-03', p_method => 'phone',
      p_payer_mode => 'client', p_rate_mode => 'person', p_agreed_unit_price_bs => 100,
      p_receivable_account_id => v_account
    );
    raise exception 'no debió permitir num_guests faltante en modo persona';
  exception when others then
    if sqlerrm <> format(
      'Indicá la cantidad de huéspedes de la habitación %s (tarifa por persona)', v_room_number
    ) then
      raise;
    end if;
  end;
end $$;
select pass('num_guests faltante (modo persona) nombra la habitación por su room_number');

-- ---------------------------------------------------------------------
-- 3) Sobre-ocupación real sobre el pool "aliased": 3 personas exceden
--    AMBAS fichas (Simple=1, Matrimonial=2) -> nombra la habitación, no
--    su UUID.
-- ---------------------------------------------------------------------
do $$
declare v_room_id uuid; v_room_number text; v_account uuid; v_type_big uuid;
begin
  select room_id, type_big into v_room_id, v_type_big from fixture_rae;
  select room_number into v_room_number from public.rooms where id = v_room_id;
  select account_id into v_account from fixture_rae_account;

  begin
    perform public.create_bulk_reservation(
      p_rooms => jsonb_build_array(jsonb_build_object(
        'room_id', v_room_id, 'room_type_id', v_type_big, 'num_guests', 3
      )),
      p_first_name => 'Rae', p_last_name => 'Tres', p_phone => '70000033', p_email => null,
      p_check_in => '2034-01-01', p_check_out => '2034-01-03', p_method => 'phone',
      p_payer_mode => 'client', p_rate_mode => 'room', p_receivable_account_id => v_account
    );
    raise exception 'no debió permitir sobre-ocupación sin motivo';
  exception when others then
    if sqlerrm <> format(
      'La habitación %s admite 2 huésped(es); estás registrando 3. Indique un motivo para exceder el límite.',
      v_room_number
    ) then
      raise;
    end if;
  end;
end $$;
select pass('sobre-ocupación real (pool aliased) nombra la habitación por su room_number');

-- ---------------------------------------------------------------------
-- 4) Habitación ya ocupada -> nombra la habitación.
-- ---------------------------------------------------------------------
-- payer_mode='each_stay' (default): las fallas por-habitación NO relanzan,
-- quedan en `failed[]` -- distinto del resto de los escenarios de este
-- archivo (todos 'client', que relanzan con el mensaje crudo). Cubre el
-- otro extremo: el mensaje real DEBE llegar igual de nombrado hasta
-- `failed[].error`, que es lo que BulkReservation.tsx ahora muestra tal
-- cual (DEFECT 3a).
do $$
declare
  v_room_id uuid; v_room_number text; v_type_small uuid;
  v_person uuid; v_booking uuid; v_result jsonb;
begin
  select room_id, type_small into v_room_id, v_type_small from fixture_rae;
  select room_number into v_room_number from public.rooms where id = v_room_id;

  insert into public.people (first_name, last_name) values ('Ocupante', 'Rae') returning id into v_person;
  insert into public.guests (person_id) values (v_person);
  insert into public.bookings (contact_person_id, payer_mode, rate_mode)
    values (v_person, 'each_stay', 'room') returning id into v_booking;
  insert into public.reservations (
    guest_id, room_id, room_type_id, check_in_date, check_out_date,
    reservation_method, payment_status, total_amount_bs, status, num_guests, booking_id
  ) values (
    v_person, v_room_id, v_type_small, '2034-02-01', '2034-02-05', 'phone', 'pending', 111, 'confirmed', 1, v_booking
  );

  v_result := public.create_bulk_reservation(
    p_rooms => jsonb_build_array(jsonb_build_object(
      'room_id', v_room_id, 'room_type_id', v_type_small, 'num_guests', 1
    )),
    p_first_name => 'Rae', p_last_name => 'Cuatro', p_phone => '70000034', p_email => null,
    p_check_in => '2034-02-02', p_check_out => '2034-02-03', p_method => 'phone'
  );

  if v_result->'failed'->0->>'error' <>
     format('La habitación %s ya no está disponible para esas fechas', v_room_number) then
    raise exception 'mensaje inesperado en failed[]: %', v_result->'failed'->0->>'error';
  end if;
end $$;
select pass('habitación ya ocupada nombra la habitación por su room_number (failed[], each_stay)');

-- ---------------------------------------------------------------------
-- 5) room_type_id que no corresponde a la habitación -> nombra la
--    habitación (usamos un tipo de OTRA habitación cualquiera).
-- ---------------------------------------------------------------------
-- payer_mode='each_stay' (default): igual que el escenario 4, la falla
-- queda en failed[] en vez de relanzar.
do $$
declare v_room_id uuid; v_room_number text; v_foreign_type uuid; v_result jsonb;
begin
  select room_id into v_room_id from fixture_rae;
  select room_number into v_room_number from public.rooms where id = v_room_id;
  select id into v_foreign_type from public.room_types
    where id not in (select type_small from fixture_rae union select type_big from fixture_rae) limit 1;

  v_result := public.create_bulk_reservation(
    p_rooms => jsonb_build_array(jsonb_build_object(
      'room_id', v_room_id, 'room_type_id', v_foreign_type, 'num_guests', 1
    )),
    p_first_name => 'Rae', p_last_name => 'Cinco', p_phone => '70000035', p_email => null,
    p_check_in => '2034-03-01', p_check_out => '2034-03-03', p_method => 'phone'
  );

  if v_result->'failed'->0->>'error' <>
     format('El tipo seleccionado no corresponde a la habitación %s', v_room_number) then
    raise exception 'mensaje inesperado en failed[]: %', v_result->'failed'->0->>'error';
  end if;
end $$;
select pass('tipo que no corresponde a la habitación nombra la habitación por su room_number');

-- ---------------------------------------------------------------------
-- 6) ACL/prosecdef/proconfig de create_bulk_reservation intactos tras
--    el body-only rewrite (mismo grant que antes de este slice: postgres
--    dueño + EXECUTE a postgres/authenticated/service_role).
-- ---------------------------------------------------------------------
select ok(
  (select prosecdef from pg_proc where proname = 'create_bulk_reservation'),
  'create_bulk_reservation sigue siendo SECURITY DEFINER'
);
select is(
  (select proconfig from pg_proc where proname = 'create_bulk_reservation')::text,
  '{search_path=public}',
  'create_bulk_reservation conserva su SET search_path'
);
select ok(
  has_function_privilege('authenticated', 'public.create_bulk_reservation('
    || 'jsonb,text,text,text,text,date,date,text,numeric,text,text,text,numeric,uuid,text,text,text,text)',
    'EXECUTE'),
  'authenticated conserva EXECUTE sobre create_bulk_reservation'
);

select * from finish();
rollback;
