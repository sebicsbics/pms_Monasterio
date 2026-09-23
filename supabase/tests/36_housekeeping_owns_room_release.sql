-- =====================================================================
-- Housekeeping se hace cargo de liberar la habitación (change:
-- housekeeping-owns-room-release, branch
-- feat/housekeeping-owns-room-release).
--
-- Cubre: (a) completar un turnover sobre una habitación dirty la libera;
-- (b) completar un stayover sobre una habitación occupied NO la toca
-- (trampa de correctitud: stayover = huésped adentro); (c) revertir una
-- asignación done->pending re-ensucia SOLO si sigue 'available'; (d)
-- generate_housekeeping_assignments agrega 'carryover' para una
-- habitación dirty sin reserva que la explique hoy; (e) una habitación
-- limpia sin actividad no aparece en el tablero generado.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true); -- root

-- ---------------------------------------------------------------------
-- Fixtures propios: un room_type y CUATRO habitaciones nuevas, una por
-- escenario.
-- ---------------------------------------------------------------------
do $$
declare
  v_type uuid;
  v_room_turnover uuid;   -- dirty, se libera al completar turnover
  v_room_occupied uuid;   -- occupied, stayover no debe tocarla
  v_room_revert uuid;     -- para probar la reversión done -> pending
  v_room_clean uuid;      -- available, sin actividad -> no debe aparecer
  v_room_carryover uuid;  -- dirty sin reserva -> debe aparecer como carryover
begin
  insert into public.room_types (name, base_price_bs, max_occupancy)
  values ('Fixture HK Release', 250, 2) returning id into v_type;

  insert into public.rooms (room_number, floor, room_type_id, operational_status)
  values ('9601', 9, v_type, 'dirty') returning id into v_room_turnover;
  insert into public.room_type_options (room_id, room_type_id) values (v_room_turnover, v_type);

  insert into public.rooms (room_number, floor, room_type_id, operational_status)
  values ('9602', 9, v_type, 'occupied') returning id into v_room_occupied;
  insert into public.room_type_options (room_id, room_type_id) values (v_room_occupied, v_type);

  insert into public.rooms (room_number, floor, room_type_id, operational_status)
  values ('9603', 9, v_type, 'dirty') returning id into v_room_revert;
  insert into public.room_type_options (room_id, room_type_id) values (v_room_revert, v_type);

  insert into public.rooms (room_number, floor, room_type_id, operational_status)
  values ('9604', 9, v_type, 'available') returning id into v_room_clean;
  insert into public.room_type_options (room_id, room_type_id) values (v_room_clean, v_type);

  insert into public.rooms (room_number, floor, room_type_id, operational_status)
  values ('9605', 9, v_type, 'dirty') returning id into v_room_carryover;
  insert into public.room_type_options (room_id, room_type_id) values (v_room_carryover, v_type);

  create temp table fixture_hk_release as
  select v_type as room_type_id,
    v_room_turnover as room_turnover, v_room_occupied as room_occupied,
    v_room_revert as room_revert, v_room_clean as room_clean,
    v_room_carryover as room_carryover;
end $$;

-- ---------------------------------------------------------------------
-- (a) Completar un turnover sobre una habitación dirty la libera.
-- ---------------------------------------------------------------------
do $$
declare v_id uuid;
begin
  insert into public.housekeeping_assignments (room_id, service_date, kind, status)
  values ((select room_turnover from fixture_hk_release), '2027-10-01', 'turnover', 'pending')
  returning id into v_id;

  update public.housekeeping_assignments set status = 'done' where id = v_id;

  create temp table fixture_hk_release_turnover as select v_id as assignment_id;
end $$;

select is(
  (select operational_status from public.rooms
   where id = (select room_turnover from fixture_hk_release)),
  'available',
  'completar un turnover sobre una habitación dirty la libera'
);

-- ---------------------------------------------------------------------
-- (b) Completar un stayover sobre una habitación OCCUPIED no la toca.
-- ---------------------------------------------------------------------
do $$
declare v_id uuid;
begin
  insert into public.housekeeping_assignments (room_id, service_date, kind, status)
  values ((select room_occupied from fixture_hk_release), '2027-10-01', 'stayover', 'pending')
  returning id into v_id;

  update public.housekeeping_assignments set status = 'done' where id = v_id;
end $$;

select is(
  (select operational_status from public.rooms
   where id = (select room_occupied from fixture_hk_release)),
  'occupied',
  'completar un stayover sobre una habitación occupied NO la libera (el huésped sigue adentro)'
);

-- ---------------------------------------------------------------------
-- (c) Reversión done -> pending: re-ensucia si sigue 'available'.
-- ---------------------------------------------------------------------
do $$
declare v_id uuid;
begin
  insert into public.housekeeping_assignments (room_id, service_date, kind, status)
  values ((select room_revert from fixture_hk_release), '2027-10-01', 'turnover', 'pending')
  returning id into v_id;

  update public.housekeeping_assignments set status = 'done' where id = v_id;
  create temp table fixture_hk_release_revert as select v_id as assignment_id;
end $$;

select is(
  (select operational_status from public.rooms
   where id = (select room_revert from fixture_hk_release)),
  'available',
  'fixture (c): quedó libre tras completarse, antes de revertir'
);

update public.housekeeping_assignments set status = 'pending'
  where id = (select assignment_id from fixture_hk_release_revert);

select is(
  (select operational_status from public.rooms
   where id = (select room_revert from fixture_hk_release)),
  'dirty',
  'revertir done -> pending re-ensucia la habitación si seguía available'
);

-- ---------------------------------------------------------------------
-- (c bis) Si la habitación cambió de estado independientemente (se
-- vendió) mientras la asignación seguía 'done', revertir NO la toca.
-- ---------------------------------------------------------------------
do $$
declare v_id uuid;
begin
  insert into public.housekeeping_assignments (room_id, service_date, kind, status)
  values ((select room_clean from fixture_hk_release), '2027-10-02', 'turnover', 'done')
  returning id into v_id;
  -- 'room_clean' arrancó 'available'; el trigger de INSERT no aplica
  -- (solo dispara en UPDATE), así que sigue 'available' -- lo movemos a
  -- 'occupied' a mano para simular que se vendió mientras tanto.
  update public.rooms set operational_status = 'occupied' where id = (select room_clean from fixture_hk_release);
  create temp table fixture_hk_release_sold as select v_id as assignment_id;
end $$;

update public.housekeeping_assignments set status = 'pending'
  where id = (select assignment_id from fixture_hk_release_sold);

select is(
  (select operational_status from public.rooms
   where id = (select room_clean from fixture_hk_release)),
  'occupied',
  'revertir done -> pending NO re-ensucia una habitación que ya se vendió (occupied) mientras tanto'
);

-- ---------------------------------------------------------------------
-- (d) generate_housekeeping_assignments agrega 'carryover' para una
-- habitación dirty sin reserva que la explique ese día.
-- ---------------------------------------------------------------------
select generate_housekeeping_assignments('2027-10-05');

select is(
  (select kind from public.housekeeping_assignments
   where room_id = (select room_carryover from fixture_hk_release)
     and service_date = '2027-10-05'),
  'carryover',
  'una habitación dirty sin reserva que la explique aparece como carryover en el tablero generado'
);

-- ---------------------------------------------------------------------
-- (e) Una habitación limpia (available) sin actividad NO aparece.
-- ---------------------------------------------------------------------
select is(
  (select count(*)::int from public.housekeeping_assignments
   where room_id = (select room_clean from fixture_hk_release)
     and service_date = '2027-10-05'),
  0,
  'una habitación available sin actividad no aparece en el tablero generado'
);

-- ---------------------------------------------------------------------
-- (f) El check constraint de kind acepta 'carryover' explícitamente.
-- ---------------------------------------------------------------------
select lives_ok(
  $sql$
    insert into public.housekeeping_assignments (room_id, service_date, kind, status)
    values ((select room_clean from fixture_hk_release), '2027-10-06', 'carryover', 'pending')
  $sql$,
  'el check constraint de kind acepta carryover'
);

-- ---------------------------------------------------------------------
-- (g) Re-ejecutar generate_housekeeping_assignments es idempotente: no
-- duplica la fila carryover ya generada en (d).
-- ---------------------------------------------------------------------
select generate_housekeeping_assignments('2027-10-05');

select is(
  (select count(*)::int from public.housekeeping_assignments
   where room_id = (select room_carryover from fixture_hk_release)
     and service_date = '2027-10-05'),
  1,
  'generate_housekeeping_assignments es idempotente para la fila carryover'
);

select * from finish();
rollback;
