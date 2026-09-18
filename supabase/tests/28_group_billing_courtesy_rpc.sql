-- =====================================================================
-- mark_reservation_courtesy: nuevo RPC para marcar una reserva each_stay
-- como cortesía (change: group-billing, stage 6, Slice 7, branch
-- feat/booking-18-courtesy-rpc). Spec R7.1-R7.4.
--
-- (e) hace explícito R2.7: una reserva de un booking institucional
-- ('client') NO puede marcarse cortesía con este RPC -- esa decisión se
-- toma al crear el grupo (payer_mode/rate ya definidos), no después.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

-- ---------------------------------------------------------------------
-- Fixture: cuenta por cobrar compartida (solo para el booking 'client'
-- del caso (e)).
-- ---------------------------------------------------------------------
do $$
declare
  v_account uuid;
begin
  insert into public.receivable_accounts (name, kind)
  values ('Fixture Courtesy RPC', 'empresa')
  returning id into v_account;

  create temp table fixture_account as select v_account as account_id;
end $$;

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

-- =======================================================================
-- (a) each_stay: marcar cortesía con motivo -> total_amount_bs=0, motivo
--     guardado, rate_overrides auditado.
-- =======================================================================
do $$
declare
  v_room_id uuid; v_room_type_id uuid; v_res_id uuid;
begin
  select o.room_id, o.room_type_id into v_room_id, v_room_type_id
  from public.room_type_options o
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where not exists (
    select 1 from public.reservations x where x.room_id = o.room_id
      and x.status in ('confirmed','checked_in')
      and x.check_in_date < '2034-01-05' and '2034-01-01' < x.check_out_date
  ) limit 1;

  v_res_id := public.create_reservation(
    v_room_id, v_room_type_id, 'Cortesia', 'CasoA',
    '70000030', null, '2034-01-01', '2034-01-05', 1, 'phone'
  );

  create temp table fixture_a as select v_res_id as res_id;

  perform set_config('request.jwt.claims',
    '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true); -- reception_admin

  perform public.mark_reservation_courtesy(v_res_id, 'Cortesía de gerencia');
end $$;

select is(
  (select total_amount_bs from public.reservations where id = (select res_id from fixture_a)),
  0::numeric,
  '(a1) total_amount_bs queda en 0 tras marcar cortesía'
);
select is(
  (select is_courtesy from public.reservations where id = (select res_id from fixture_a)),
  true,
  '(a2) is_courtesy queda en true'
);
select is(
  (select courtesy_reason from public.reservations where id = (select res_id from fixture_a)),
  'Cortesía de gerencia',
  '(a3) courtesy_reason queda guardado'
);
select is(
  (select count(*)::int from public.rate_overrides where reservation_id = (select res_id from fixture_a)),
  1,
  '(a4) rate_overrides auditó el cambio'
);
select is(
  (select new_rate_bs from public.rate_overrides where reservation_id = (select res_id from fixture_a)),
  0::numeric,
  '(a5) rate_overrides.new_rate_bs = 0'
);

-- =======================================================================
-- (b, neg) motivo vacío/NULL -> rechazado.
-- =======================================================================
do $$
declare
  v_room_id uuid; v_room_type_id uuid; v_res_id uuid;
begin
  select o.room_id, o.room_type_id into v_room_id, v_room_type_id
  from public.room_type_options o
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where not exists (
    select 1 from public.reservations x where x.room_id = o.room_id
      and x.status in ('confirmed','checked_in')
      and x.check_in_date < '2034-02-05' and '2034-02-01' < x.check_out_date
  ) limit 1;

  v_res_id := public.create_reservation(
    v_room_id, v_room_type_id, 'Cortesia', 'CasoB',
    '70000031', null, '2034-02-01', '2034-02-05', 1, 'phone'
  );

  create temp table fixture_b as select v_res_id as res_id;
end $$;

select throws_ok(
  format('select public.mark_reservation_courtesy(%L, %L)', (select res_id from fixture_b), ''),
  'El motivo es obligatorio para marcar cortesía',
  '(b1) motivo vacío es rechazado'
);
select throws_ok(
  format('select public.mark_reservation_courtesy(%L, null)', (select res_id from fixture_b)),
  'El motivo es obligatorio para marcar cortesía',
  '(b2) motivo NULL es rechazado'
);
select is(
  (select is_courtesy from public.reservations where id = (select res_id from fixture_b)),
  false,
  '(b3) la reserva no quedó marcada cortesía tras el rechazo'
);

-- =======================================================================
-- (c) la habitación de una reserva marcada cortesía sigue contando como
--     ocupada (R7.2) -- su operational_status no cambia por este RPC.
-- =======================================================================
select is(
  (select rm.operational_status from public.rooms rm
    join public.reservations r on r.room_id = rm.id
    where r.id = (select res_id from fixture_a)),
  'occupied',
  '(c1) la habitación cortesía sigue "occupied" tras marcarla'
);
select is(
  (select status from public.reservations where id = (select res_id from fixture_a)),
  'confirmed',
  '(c2) la reserva cortesía sigue activa (confirmed), no se toca su status'
);

-- =======================================================================
-- (d, neg) reserva de booking institucional (payer_mode='client') no
-- puede marcarse cortesía con este RPC (R2.7).
-- =======================================================================
do $$
declare
  v_room_id uuid; v_room_type_id uuid; v_result jsonb; v_res_id uuid;
begin
  select o.room_id, o.room_type_id into v_room_id, v_room_type_id
  from public.room_type_options o
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where not exists (
    select 1 from public.reservations x where x.room_id = o.room_id
      and x.status in ('confirmed','checked_in')
      and x.check_in_date < '2034-03-05' and '2034-03-01' < x.check_out_date
  ) limit 1;

  v_result := public.create_bulk_reservation(
    jsonb_build_array(
      jsonb_build_object('room_id', v_room_id, 'room_type_id', v_room_type_id, 'num_guests', 1)
    ),
    'Institucion', 'Cortesia', '70000032', 'cortesia.institucion@fixture.test',
    '2034-03-01', '2034-03-05', 'phone', null, null,
    'client', 'room', null, (select account_id from fixture_account)
  );
  v_res_id := ((v_result->'created')->>0)::uuid;

  create temp table fixture_d as select v_res_id as res_id;
end $$;

select throws_ok(
  format('select public.mark_reservation_courtesy(%L, %L)', (select res_id from fixture_d), 'motivo cualquiera'),
  'La cortesía de una reserva institucional se define al crear el grupo, no después',
  '(d1) reserva institucional rechazada'
);

select * from finish();
rollback;
