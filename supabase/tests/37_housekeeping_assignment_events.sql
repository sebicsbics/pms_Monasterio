-- =====================================================================
-- Bitácora de eventos de housekeeping: `change_housekeeping_assignment_status`
-- (change: housekeeping-assignment-notes, branch
-- feat/housekeeping-assignment-notes).
--
-- POR QUÉ: hoy no hay forma de dejar una nota al cambiar el estado de una
-- limpieza ("encontramos la ventana rota", "faltó reponer amenities"). El
-- campo `notes` de `housekeeping_assignments` existe pero nada lo escribe.
-- Se resuelve con un log de eventos append-only (no un campo editable):
-- cada cambio de estado (o nota suelta, sin cambiar estado) queda como una
-- fila nueva, nunca se pisa la anterior.
--
-- Cubre: (a) un cambio de estado real crea un evento con la nota; (b) un
-- evento "solo nota" (mismo status) no toca timestamps/status; (c) un
-- evento "solo nota" sin nota se rechaza; (d) los timestamps siguen la
-- misma semántica que tenía `updateAssignmentStatus` en TS
-- (in_progress -> started_at, done -> completed_at, pending -> limpia
-- ambos); (e) el trigger de liberación de habitación sigue funcionando
-- (completar vía la RPC libera la habitación dirty); (f) un rol no
-- autorizado (owner) es rechazado; (g) INSERT directo en la tabla de
-- eventos es rechazado para authenticated (append-only sólo vía RPC);
-- (h) anon no puede ejecutar la RPC.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(13);

select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true); -- root

-- ---------------------------------------------------------------------
-- Fixtures: un room_type y dos habitaciones (una dirty para probar la
-- liberación al completar, otra cualquiera para el resto de los casos).
-- ---------------------------------------------------------------------
do $$
declare
  v_type uuid;
  v_room_events uuid;
  v_room_release uuid;
  v_assignment_events uuid;
  v_assignment_release uuid;
begin
  insert into public.room_types (name, base_price_bs, max_occupancy)
  values ('Fixture HK Events', 250, 2) returning id into v_type;

  insert into public.rooms (room_number, floor, room_type_id, operational_status)
  values ('9701', 9, v_type, 'available') returning id into v_room_events;
  insert into public.room_type_options (room_id, room_type_id) values (v_room_events, v_type);

  insert into public.rooms (room_number, floor, room_type_id, operational_status)
  values ('9702', 9, v_type, 'dirty') returning id into v_room_release;
  insert into public.room_type_options (room_id, room_type_id) values (v_room_release, v_type);

  insert into public.housekeeping_assignments (room_id, service_date, kind, status)
  values (v_room_events, '2027-11-01', 'turnover', 'pending')
  returning id into v_assignment_events;

  insert into public.housekeeping_assignments (room_id, service_date, kind, status)
  values (v_room_release, '2027-11-01', 'turnover', 'pending')
  returning id into v_assignment_release;

  create temp table fixture_hk_events as
  select v_room_events as room_events, v_room_release as room_release,
    v_assignment_events as assignment_events, v_assignment_release as assignment_release;
end $$;

-- ---------------------------------------------------------------------
-- (a)+(d) pending -> in_progress: crea el evento, marca started_at, no
-- toca completed_at.
-- ---------------------------------------------------------------------
select public.change_housekeeping_assignment_status(
  (select assignment_events from fixture_hk_events), 'in_progress', 'Empezando la limpieza'
);

select is(
  (select status from public.housekeeping_assignments
    where id = (select assignment_events from fixture_hk_events)),
  'in_progress',
  '(a) la RPC deja el status en in_progress'
);

select ok(
  (select started_at is not null from public.housekeeping_assignments
    where id = (select assignment_events from fixture_hk_events)),
  '(d) pending -> in_progress marca started_at'
);

select is(
  (select (from_status, to_status, note)
    from public.housekeeping_assignment_events
    where assignment_id = (select assignment_events from fixture_hk_events)
    order by created_at desc limit 1)::text,
  '(pending,in_progress,"Empezando la limpieza")',
  '(a) el evento queda con from/to/nota correctos'
);

-- ---------------------------------------------------------------------
-- (b) evento "solo nota" (mismo status): no toca started_at/status, sólo
-- agrega un evento nuevo.
-- ---------------------------------------------------------------------
select public.change_housekeeping_assignment_status(
  (select assignment_events from fixture_hk_events), 'in_progress', 'Encontramos la ventana rota'
);

select is(
  (select status from public.housekeeping_assignments
    where id = (select assignment_events from fixture_hk_events)),
  'in_progress',
  '(b) una nota sin cambiar estado no altera el status'
);

select is(
  (select count(*)::int from public.housekeeping_assignment_events
    where assignment_id = (select assignment_events from fixture_hk_events)),
  2,
  '(b) el evento "solo nota" se agrega a la bitácora (van 2 en total)'
);

-- ---------------------------------------------------------------------
-- (c) evento "solo nota" sin nota (o en blanco) se rechaza.
-- ---------------------------------------------------------------------
select throws_ok(
  format(
    $$ select public.change_housekeeping_assignment_status(%L, 'in_progress', '   ') $$,
    (select assignment_events from fixture_hk_events)
  ),
  'P0001', 'La nota no puede estar vacía',
  '(c) una nota en blanco sin cambio de estado se rechaza'
);

-- ---------------------------------------------------------------------
-- (d) in_progress -> done: marca completed_at.
-- ---------------------------------------------------------------------
select public.change_housekeeping_assignment_status(
  (select assignment_events from fixture_hk_events), 'done', null
);

select ok(
  (select completed_at is not null from public.housekeeping_assignments
    where id = (select assignment_events from fixture_hk_events)),
  '(d) in_progress -> done marca completed_at'
);

-- ---------------------------------------------------------------------
-- (d) done -> pending: limpia ambos timestamps.
-- ---------------------------------------------------------------------
select public.change_housekeeping_assignment_status(
  (select assignment_events from fixture_hk_events), 'pending', null
);

select is(
  (select (started_at is null and completed_at is null)
    from public.housekeeping_assignments
    where id = (select assignment_events from fixture_hk_events)),
  true,
  '(d) done -> pending limpia started_at y completed_at'
);

-- ---------------------------------------------------------------------
-- (e) El trigger de liberación sigue funcionando: completar vía la RPC
-- libera una habitación dirty.
-- ---------------------------------------------------------------------
select public.change_housekeeping_assignment_status(
  (select assignment_release from fixture_hk_events), 'done', null
);

select is(
  (select operational_status from public.rooms
    where id = (select room_release from fixture_hk_events)),
  'available',
  '(e) completar la limpieza vía la RPC sigue liberando la habitación (trigger intacto)'
);

-- ---------------------------------------------------------------------
-- (f) Un rol no autorizado (owner) es rechazado.
-- ---------------------------------------------------------------------
reset role;
select set_config('request.jwt.claims',
  '{"sub":"55555555-5555-5555-5555-555555555555","role":"authenticated"}', true); -- owner
set local role authenticated;

select throws_ok(
  format(
    $$ select public.change_housekeeping_assignment_status(%L, 'done', null) $$,
    (select assignment_events from fixture_hk_events)
  ),
  'P0001', 'No autorizado',
  '(f) owner no puede cambiar el estado de una limpieza'
);
reset role;

-- ---------------------------------------------------------------------
-- (g) INSERT directo en la tabla de eventos se rechaza para authenticated
-- (append-only, sólo vía la RPC).
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception
set local role authenticated;

select throws_ok(
  format(
    $$ insert into public.housekeeping_assignment_events (assignment_id, from_status, to_status, note)
       values (%L, 'pending', 'pending', 'colado directo') $$,
    (select assignment_events from fixture_hk_events)
  ),
  '42501', null,
  '(g) INSERT directo en housekeeping_assignment_events se rechaza para authenticated'
);
reset role;

-- ---------------------------------------------------------------------
-- (h) anon no puede ejecutar la RPC.
-- ---------------------------------------------------------------------
set local role anon;

select throws_ok(
  format(
    $$ select public.change_housekeeping_assignment_status(%L, 'done', null) $$,
    (select assignment_events from fixture_hk_events)
  ),
  '42501', null,
  '(h) anon no puede ejecutar change_housekeeping_assignment_status'
);
reset role;

select * from finish();
rollback;
