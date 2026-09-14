-- =====================================================================
-- Contrato institucional: create_reservation soporta payer_mode,
-- rate_mode y cortesía al crear (change: group-billing, stage 6,
-- Slice 2a2, branch feat/booking-10-contract-single).
--
-- Cambia la aridad de create_reservation (13 -> 23 parámetros, 10
-- nuevos al final, todos con default = comportamiento actual). Este
-- archivo prueba TANTO la regresión each_stay (nada cambia) como el
-- camino nuevo 'client' (room/person, cortesía, cuenta por cobrar,
-- gate de rol, contrato congelado al final).
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(37);

-- ---------------------------------------------------------------------
-- Fixtures compartidos (como postgres/superusuario).
-- ---------------------------------------------------------------------

-- Cuenta activa existente, para el camino "Existente".
do $$
declare
  v_account uuid;
begin
  insert into public.receivable_accounts (name, kind)
  values ('Fixture Contract Single Activa', 'empresa')
  returning id into v_account;

  create temp table fixture_account as select v_account as account_id;
end $$;

-- Cuenta INACTIVA, para el negativo correspondiente.
do $$
declare
  v_account uuid;
begin
  insert into public.receivable_accounts (name, kind, is_active)
  values ('Fixture Contract Single Inactiva', 'empresa', false)
  returning id into v_account;

  create temp table fixture_inactive_account as select v_account as account_id;
end $$;

-- Root y reception_admin para los caminos 'client'; reception para los
-- negativos de rol y la regresión each_stay.
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true); -- root

-- ---------------------------------------------------------------------
-- (a) REGRESIÓN: each_stay sin parámetros nuevos, resultado idéntico al
--     de antes de este slice. Ningún evento en booking_balances.
-- ---------------------------------------------------------------------
do $$
declare
  v_room uuid; v_room_type uuid; v_reservation uuid; v_booking uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_room_type
  from public.room_type_options o
  join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 350
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_reservation := public.create_reservation(
    v_room, v_room_type, 'Ana', 'Cada Habitación', '70000001', 'ana.eachstay@fixture.test',
    '2027-05-01', '2027-05-03', 1, 'phone', null, null, true
  );
  select booking_id into v_booking from public.reservations where id = v_reservation;

  create temp table fixture_a as select v_reservation as reservation_id, v_booking as booking_id;
end $$;

select is(
  (select total_amount_bs from public.reservations where id = (select reservation_id from fixture_a)),
  700.00,
  'each_stay sin campos nuevos: total = tarifa x noches, igual que antes (350x2)'
);
select is(
  (select payer_mode from public.bookings where id = (select booking_id from fixture_a)),
  'each_stay',
  'each_stay sin campos nuevos: payer_mode default sigue siendo each_stay'
);
select is(
  (select count(*)::int from public.booking_balances where booking_id = (select booking_id from fixture_a)),
  0,
  'each_stay no genera ningún evento en booking_balances'
);

-- ---------------------------------------------------------------------
-- (b) client + rate_mode='room', reception_admin, sin tarifa custom ->
--     contract_agreed = total_amount_bs.
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true); -- reception_admin

do $$
declare
  v_room uuid; v_room_type uuid; v_reservation uuid; v_booking uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_room_type
  from public.room_type_options o
  join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 2 and rt.base_price_bs = 480
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_reservation := public.create_reservation(
    v_room, v_room_type, 'Hotel', 'ABC', '70000002', 'contacto.hotelabc@fixture.test',
    '2027-05-04', '2027-05-06', 2, 'phone', null, null, true,
    'client', 'room', null, (select account_id from fixture_account),
    null, null, null, null, false, null
  );
  select booking_id into v_booking from public.reservations where id = v_reservation;

  create temp table fixture_b as select v_reservation as reservation_id, v_booking as booking_id;
end $$;

select is(
  (select count(*)::int from public.booking_balances
    where booking_id = (select booking_id from fixture_b) and event_type = 'contract_agreed'),
  1,
  'client+room sin tarifa custom: se inserta exactamente un contract_agreed'
);
select is(
  (select bb.amount_bs from public.booking_balances bb where bb.booking_id = (select booking_id from fixture_b)),
  (select r.total_amount_bs from public.reservations r where r.id = (select reservation_id from fixture_b)),
  'client+room sin tarifa custom: contract_agreed = total_amount_bs (960)'
);

-- ---------------------------------------------------------------------
-- (c) client + rate_mode='person', root, cuenta NUEVA (prueba de
--     recorte de espacios y vínculo atómico): precio=300, 3 huéspedes,
--     2 noches -> total=1800, contract=1800.
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true); -- root

do $$
declare
  v_room uuid; v_room_type uuid; v_reservation uuid; v_booking uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_room_type
  from public.room_type_options o
  join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 3 and rt.base_price_bs = 600
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_reservation := public.create_reservation(
    v_room, v_room_type, 'Grupo', 'Persona', '70000003', 'grupo.persona@fixture.test',
    '2027-05-07', '2027-05-09', 3, 'phone', null, null, true,
    'client', 'person', 300, null,
    '  Hotel Persona SA  ', 'empresa', 'contacto@hotelpersona.test', null, false, null
  );
  select booking_id into v_booking from public.reservations where id = v_reservation;

  create temp table fixture_c as select v_reservation as reservation_id, v_booking as booking_id;
end $$;

select is(
  (select total_amount_bs from public.reservations where id = (select reservation_id from fixture_c)),
  1800.00,
  'client+person: 300 x 3 huéspedes x 2 noches = 1800 en total_amount_bs'
);
select is(
  (select amount_bs from public.booking_balances where booking_id = (select booking_id from fixture_c)),
  1800.00,
  'client+person: contract_agreed también 1800'
);
select is(
  (select count(*)::int from public.bookings b join public.receivable_accounts ra
     on ra.id = b.receivable_account_id
   where b.id = (select booking_id from fixture_c) and ra.name = 'Hotel Persona SA'),
  1,
  'cuenta nueva creada con el nombre recortado (sin espacios) y vinculada a la booking'
);

-- ---------------------------------------------------------------------
-- (d) client + cortesía al crear (room mode) -> total=0, contract=0.
-- ---------------------------------------------------------------------
do $$
declare
  v_room uuid; v_room_type uuid; v_reservation uuid; v_booking uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_room_type
  from public.room_type_options o
  join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 350
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_reservation := public.create_reservation(
    v_room, v_room_type, 'Cortesía', 'Gerencia', '70000004', 'cortesia.gerencia@fixture.test',
    '2027-05-10', '2027-05-12', 1, 'phone', null, null, true,
    'client', 'room', null, (select account_id from fixture_account),
    null, null, null, null, true, 'Cortesía de gerencia'
  );
  select booking_id into v_booking from public.reservations where id = v_reservation;

  create temp table fixture_d as select v_reservation as reservation_id, v_booking as booking_id;
end $$;

select is(
  (select total_amount_bs from public.reservations where id = (select reservation_id from fixture_d)),
  0.00,
  'client cortesía al crear: total_amount_bs=0'
);
select is(
  (select amount_bs from public.booking_balances where booking_id = (select booking_id from fixture_d)),
  0.00,
  'client cortesía al crear: contract_agreed también 0 (se inserta igual, para el audit)'
);

-- ---------------------------------------------------------------------
-- Helper de "sin efectos secundarios": una fila con los 5 conteos que
-- una llamada rechazada NUNCA debe alterar.
-- ---------------------------------------------------------------------
create or replace function pg_temp.snap() returns text language sql as $$
  select row(
    (select count(*) from public.people),
    (select count(*) from public.bookings),
    (select count(*) from public.reservations),
    (select count(*) from public.receivable_accounts),
    (select count(*) from public.booking_balances)
  )::text
$$;

-- ---------------------------------------------------------------------
-- (e, neg) client sin cuenta existente NI datos de cuenta nueva ->
--          rechazado, cero efectos secundarios.
-- ---------------------------------------------------------------------
do $$
declare v_room uuid; v_room_type uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_room_type
  from public.room_type_options o
  join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 1 and rt.base_price_bs = 350
    and o.room_id not in (select room_id from public.reservations)
  limit 1;
  create temp table fixture_e as select v_room as room_id, v_room_type as room_type_id;
end $$;

create temp table snap_e as select pg_temp.snap() as s;

select throws_matching(
  $$ select public.create_reservation(
       (select room_id from fixture_e), (select room_type_id from fixture_e),
       'Sin', 'Cuenta', '70000005', 'sin.cuenta@fixture.test',
       '2027-05-13', '2027-05-15', 1, 'phone', null, null, true,
       'client', 'room', null, null, null, null, null, null, false, null
     ) $$,
  'Elegí una cuenta existente o indicá los datos de la nueva cuenta',
  'client sin id existente ni datos de cuenta nueva es rechazado'
);
select is(pg_temp.snap(), (select s from snap_e),
  'la llamada rechazada (e) no dejó gente/bookings/reservations/cuentas/ledger nuevos');

-- ---------------------------------------------------------------------
-- (f, neg) client con id existente Y datos de cuenta nueva a la vez ->
--          rechazado, cero efectos secundarios.
-- ---------------------------------------------------------------------
create temp table snap_f as select pg_temp.snap() as s;

select throws_matching(
  $$ select public.create_reservation(
       (select room_id from fixture_e), (select room_type_id from fixture_e),
       'Ambas', 'Cuentas', '70000006', 'ambas.cuentas@fixture.test',
       '2027-05-13', '2027-05-15', 1, 'phone', null, null, true,
       'client', 'room', null, (select account_id from fixture_account),
       'Otra cuenta', 'empresa', null, null, false, null
     ) $$,
  'Elegí una cuenta existente O creá una nueva',
  'client con id existente Y datos de cuenta nueva a la vez es rechazado'
);
select is(pg_temp.snap(), (select s from snap_f),
  'la llamada rechazada (f) no dejó gente/bookings/reservations/cuentas/ledger nuevos');

-- ---------------------------------------------------------------------
-- (g, neg) client con una cuenta existente pero INACTIVA -> rechazado,
--          cero efectos secundarios.
-- ---------------------------------------------------------------------
create temp table snap_g as select pg_temp.snap() as s;

select throws_matching(
  $$ select public.create_reservation(
       (select room_id from fixture_e), (select room_type_id from fixture_e),
       'Cuenta', 'Inactiva', '70000007', 'cuenta.inactiva@fixture.test',
       '2027-05-13', '2027-05-15', 1, 'phone', null, null, true,
       'client', 'room', null, (select account_id from fixture_inactive_account),
       null, null, null, null, false, null
     ) $$,
  'Cuenta por cobrar inválida o inactiva',
  'client con una cuenta existente pero inactiva es rechazado'
);
select is(pg_temp.snap(), (select s from snap_g),
  'la llamada rechazada (g) no dejó gente/bookings/reservations/cuentas/ledger nuevos');

-- ---------------------------------------------------------------------
-- (h, neg) reception intenta payer_mode='client' -> rechazado (decisión
--          #339: sólo root/reception_admin), cero efectos secundarios.
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

create temp table snap_h as select pg_temp.snap() as s;

select throws_matching(
  $$ select public.create_reservation(
       (select room_id from fixture_e), (select room_type_id from fixture_e),
       'Reception', 'Intenta', '70000008', 'reception.intenta@fixture.test',
       '2027-05-13', '2027-05-15', 1, 'phone', null, null, true,
       'client', 'room', null, (select account_id from fixture_account),
       null, null, null, null, false, null
     ) $$,
  'Solo un administrador de recepción puede crear una reserva institucional',
  'reception intentando payer_mode=client es rechazado'
);
select is(pg_temp.snap(), (select s from snap_h),
  'la llamada rechazada (h, reception) no dejó gente/bookings/reservations/cuentas/ledger nuevos');

-- ---------------------------------------------------------------------
-- (i, neg) rate_mode='person' con num_guests=0 -> rechazado por la
--          validación existente (compartida con room mode, sin cambios).
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true); -- root

select throws_matching(
  $$ select public.create_reservation(
       (select room_id from fixture_e), (select room_type_id from fixture_e),
       'Cero', 'Huéspedes', '70000009', 'cero.huespedes@fixture.test',
       '2027-05-13', '2027-05-15', 0, 'phone', null, null, true,
       'client', 'person', 300, (select account_id from fixture_account),
       null, null, null, null, false, null
     ) $$,
  'Debe haber al menos 1 persona',
  'rate_mode=person con num_guests=0 es rechazado'
);

-- ---------------------------------------------------------------------
-- (j, neg) rate_mode='person' con num_guests=NULL -> rechazado. NULL no
--          dispara el `if p_num_guests < 1` existente (NULL < 1 = NULL,
--          no TRUE -- mismo patrón que el "check-constraint NULL trap",
--          esta vez en un IF plpgsql). Pre-existente, sin cambios en
--          este slice (ya pasaba antes con el parámetro NULL en modo
--          each_stay): la llamada termina abortando igual, más abajo,
--          por la columna NOT NULL de una tabla dependiente -- no hace
--          falta un mensaje específico, sólo que la llamada entera
--          aborte sin dejar nada a medio insertar (atómico por
--          statement).
-- ---------------------------------------------------------------------
select throws_matching(
  $$ select public.create_reservation(
       (select room_id from fixture_e), (select room_type_id from fixture_e),
       'Null', 'Huéspedes', '70000010', 'null.huespedes@fixture.test',
       '2027-05-13', '2027-05-15', null, 'phone', null, null, true,
       'client', 'person', 300, (select account_id from fixture_account),
       null, null, null, null, false, null
     ) $$,
  '.',
  'rate_mode=person con num_guests=NULL es rechazado'
);

-- ---------------------------------------------------------------------
-- (k, neg) rate_mode='person' con agreed_unit_price_bs=NULL -> rechazado
--          (trampa NULL de CHECK evitada: acá es un IF plpgsql con
--          coalesce, no depende del CHECK de bookings).
-- ---------------------------------------------------------------------
select throws_matching(
  $$ select public.create_reservation(
       (select room_id from fixture_e), (select room_type_id from fixture_e),
       'Precio', 'Nulo', '70000011', 'precio.nulo@fixture.test',
       '2027-05-13', '2027-05-15', 1, 'phone', null, null, true,
       'client', 'person', null, (select account_id from fixture_account),
       null, null, null, null, false, null
     ) $$,
  'Debe indicar un precio pactado por persona positivo',
  'rate_mode=person con agreed_unit_price_bs=NULL es rechazado'
);

-- ---------------------------------------------------------------------
-- (l) root crea client+room con una tarifa custom con descuento >20% ->
--     se aplica DIRECTO (nunca pending): total descontado, rate_overrides
--     auditado, una rate_discount_requests 'approved', cero 'pending',
--     contract_agreed = total descontado.
-- ---------------------------------------------------------------------
do $$
declare
  v_room uuid; v_room_type uuid; v_reservation uuid; v_booking uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_room_type
  from public.room_type_options o
  join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 2 and rt.base_price_bs = 480
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_reservation := public.create_reservation(
    v_room, v_room_type, 'Root', 'Descuento', '70000012', 'root.descuento@fixture.test',
    '2027-05-16', '2027-05-18', 2, 'phone', 300, 'Descuento institucional negociado', true,
    'client', 'room', null, (select account_id from fixture_account),
    null, null, null, null, false, null
  );
  select booking_id into v_booking from public.reservations where id = v_reservation;

  create temp table fixture_l as select v_reservation as reservation_id, v_booking as booking_id;
end $$;

select is(
  (select total_amount_bs from public.reservations where id = (select reservation_id from fixture_l)),
  600.00,
  'root + client+room + tarifa 300 (vs 480 de lista) x 2 noches = 600, aplicado directo'
);
select is(
  (select count(*)::int from public.rate_overrides where reservation_id = (select reservation_id from fixture_l)),
  1,
  'la tarifa custom queda auditada en rate_overrides'
);
select is(
  (select count(*)::int from public.rate_discount_requests
    where reservation_id = (select reservation_id from fixture_l) and status = 'approved'),
  1,
  'el descuento >20% queda auditado como rate_discount_requests approved'
);
select is(
  (select count(*)::int from public.rate_discount_requests
    where reservation_id = (select reservation_id from fixture_l) and status = 'pending'),
  0,
  'el descuento >20% de root NUNCA queda pending (decisión #339)'
);
select is(
  (select amount_bs from public.booking_balances where booking_id = (select booking_id from fixture_l)),
  600.00,
  'contract_agreed usa el total YA descontado (600, no 960)'
);

-- NOTA: "apply_rate_change sobre esta misma reserva queda rechazado" es
-- un assert diferido a feat/booking-13-rate-lock -- ese branch recién
-- agrega el chequeo de contract_agreed DENTRO de apply_rate_change (hoy
-- su body sigue sin tocar, ADR#6/#11). No se agrega un assert placeholder
-- acá para no inflar el plan con un "skip" que no prueba nada todavía.

-- ---------------------------------------------------------------------
-- (m) REGRESIÓN: reception crea each_stay con una tarifa custom con
--     descuento >20% -> sigue quedando 'pending', exactamente como
--     antes de este slice (camino each_stay 100% sin tocar).
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

do $$
declare
  v_room uuid; v_room_type uuid; v_reservation uuid;
begin
  select o.room_id, o.room_type_id into v_room, v_room_type
  from public.room_type_options o
  join public.room_types rt on rt.id = o.room_type_id
  where rt.max_occupancy = 2 and rt.base_price_bs = 480
    and o.room_id not in (select room_id from public.reservations)
  limit 1;

  v_reservation := public.create_reservation(
    v_room, v_room_type, 'Reception', 'Descuento', '70000013', 'reception.descuento@fixture.test',
    '2027-05-19', '2027-05-21', 2, 'phone', 300, 'Pide descuento grande', true
  );

  create temp table fixture_m as select v_reservation as reservation_id;
end $$;

select is(
  (select total_amount_bs from public.reservations where id = (select reservation_id from fixture_m)),
  960.00,
  'reception each_stay descuento >20%: total SIGUE a precio de lista (480x2), no se aplica directo'
);
select is(
  (select count(*)::int from public.rate_discount_requests
    where reservation_id = (select reservation_id from fixture_m) and status = 'pending'),
  1,
  'reception each_stay descuento >20%: queda una solicitud pending, igual que siempre'
);
select is(
  (select count(*)::int from public.rate_overrides where reservation_id = (select reservation_id from fixture_m)),
  0,
  'reception each_stay descuento >20%: rate_overrides NO se toca hasta que se apruebe'
);

-- ---------------------------------------------------------------------
-- (n, neg, R2.4) insertar directo en reservations para una booking
--     'client' existente, bypaseando el RPC, como 'authenticated' real
--     (no postgres) -> rechazado por RLS (no hay policy de INSERT).
-- ---------------------------------------------------------------------
grant select on fixture_b to authenticated;
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true); -- root

select throws_matching(
  $$ insert into public.reservations (
       room_id, room_type_id, check_in_date, check_out_date, num_guests,
       total_amount_bs, booking_id
     )
     select (select room_id from public.room_type_options limit 1),
       (select room_type_id from public.room_type_options limit 1),
       '2027-06-01', '2027-06-03', 1, 100, (select booking_id from fixture_b) $$,
  'row-level security',
  'insertar directo en reservations para una booking client existente es rechazado por RLS'
);
reset role;

-- ---------------------------------------------------------------------
-- (o) V-B: grants de la nueva firma de 23 parámetros; la vieja de 13
--     parámetros ya no existe.
-- ---------------------------------------------------------------------
select ok(
  has_function_privilege('authenticated',
    'public.create_reservation(uuid,uuid,text,text,text,text,date,date,integer,text,numeric,text,boolean,text,text,numeric,uuid,text,text,text,text,boolean,text)',
    'execute'),
  'authenticated puede ejecutar la nueva firma de 23 parámetros de create_reservation'
);
select ok(
  not has_function_privilege('anon',
    'public.create_reservation(uuid,uuid,text,text,text,text,date,date,integer,text,numeric,text,boolean,text,text,numeric,uuid,text,text,text,text,boolean,text)',
    'execute'),
  'anon NO puede ejecutar create_reservation'
);
select is(
  to_regprocedure('public.create_reservation(uuid,uuid,text,text,text,text,date,date,integer,text,numeric,text,boolean)'),
  null::regprocedure,
  'la firma vieja de 13 parámetros ya no existe (DROP FUNCTION de este slice)'
);

-- ---------------------------------------------------------------------
-- (p, neg, fix sdd/group-billing/review-booking-10) p_payer_mode=NULL
--          -> rechazado con el mensaje en español. Antes: `NULL not in
--          (...)` evalúa a NULL (no a TRUE), el IF nunca disparaba, y
--          la llamada fallaba más abajo con una violación NOT NULL
--          cruda en vez de con el mensaje claro (mismo patrón de #368,
--          esta vez en un IF plpgsql). Cero efectos secundarios.
-- ---------------------------------------------------------------------
create temp table snap_p as select pg_temp.snap() as s;

select throws_matching(
  $$ select public.create_reservation(
       (select room_id from fixture_e), (select room_type_id from fixture_e),
       'Payer', 'Nulo', '70000014', 'payer.nulo@fixture.test',
       '2027-05-22', '2027-05-24', 1, 'phone', null, null, true,
       null, 'room', null, null, null, null, null, null, false, null
     ) $$,
  'Modalidad de pago inválida',
  'p_payer_mode=NULL es rechazado con el mensaje en español, no con un error crudo'
);
select is(pg_temp.snap(), (select s from snap_p),
  'la llamada rechazada (p, payer_mode NULL) no dejó gente/bookings/reservations/cuentas/ledger nuevos');

-- ---------------------------------------------------------------------
-- (q, neg, fix sdd/group-billing/review-booking-10) p_rate_mode=NULL
--          (con payer_mode='client') -> rechazado con el mensaje en
--          español, mismo trap. Cero efectos secundarios.
-- ---------------------------------------------------------------------
create temp table snap_q as select pg_temp.snap() as s;

select throws_matching(
  $$ select public.create_reservation(
       (select room_id from fixture_e), (select room_type_id from fixture_e),
       'Rate', 'Nulo', '70000015', 'rate.nulo@fixture.test',
       '2027-05-22', '2027-05-24', 1, 'phone', null, null, true,
       'client', null, null, (select account_id from fixture_account),
       null, null, null, null, false, null
     ) $$,
  'Modalidad de tarifa inválida',
  'p_rate_mode=NULL es rechazado con el mensaje en español, no con un error crudo'
);
select is(pg_temp.snap(), (select s from snap_q),
  'la llamada rechazada (q, rate_mode NULL) no dejó gente/bookings/reservations/cuentas/ledger nuevos');

select * from finish();
rollback;
