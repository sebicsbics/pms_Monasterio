-- =====================================================================
-- Contrato institucional: columnas de tarifa/cortesía + helpers internos
-- (change: group-billing, stage 6, Slice 2a).
--
-- Este slice sólo agrega DDL y dos helpers internos -- todavía NO cablea
-- create_reservation/create_bulk_reservation (eso es feat/booking-10 y
-- feat/booking-11). El objetivo acá es que el ESQUEMA por sí solo ya
-- exija las reglas de negocio del contrato congelado:
--   - rate_mode='person' sólo tiene sentido con un precio pactado
--     (agreed_unit_price_bs) y sólo para bookings 'client'.
--   - payer_mode='client' siempre necesita una cuenta por cobrar.
--   - una reserva de cortesía siempre necesita un motivo no vacío.
--
-- _resolve_receivable_account y _apply_rate_change_direct son helpers
-- INTERNOS (revocados de public/anon/authenticated, V-C): los usarán
-- create_reservation/create_bulk_reservation (feat/booking-10/11) y
-- apply_rate_change (feat/booking-13), nunca se llaman directo desde el
-- cliente. _apply_rate_change_direct es una extracción FIEL de la rama
-- "aplicar directo" de apply_rate_change (misma inserción en
-- rate_overrides, misma auto-aprobación de rate_discount_requests
-- cuando el descuento supera 20%) -- apply_rate_change en sí NO se toca
-- en este branch.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(36);

-- ---------------------------------------------------------------------
-- 0) Forma del esquema.
-- ---------------------------------------------------------------------
select has_column('public', 'bookings', 'rate_mode', 'bookings.rate_mode existe');
select col_not_null('public', 'bookings', 'rate_mode', 'rate_mode es NOT NULL');
select has_column('public', 'bookings', 'agreed_unit_price_bs', 'bookings.agreed_unit_price_bs existe');
select has_column('public', 'reservations', 'is_courtesy', 'reservations.is_courtesy existe');
select col_not_null('public', 'reservations', 'is_courtesy', 'is_courtesy es NOT NULL');
select has_column('public', 'reservations', 'courtesy_reason', 'reservations.courtesy_reason existe');

-- ---------------------------------------------------------------------
-- 1) Grants de los helpers internos: nadie autenticado los llama directo
--    (V-C) -- sólo otras funciones SECURITY DEFINER (feat/booking-10/11/13).
-- ---------------------------------------------------------------------
select ok(
  not has_function_privilege('authenticated', 'public._resolve_receivable_account(uuid,text,text,text,text)', 'execute'),
  'authenticated NO puede ejecutar _resolve_receivable_account directamente'
);
select ok(
  not has_function_privilege('anon', 'public._resolve_receivable_account(uuid,text,text,text,text)', 'execute'),
  'anon NO puede ejecutar _resolve_receivable_account directamente'
);
select ok(
  not has_function_privilege('authenticated', 'public._apply_rate_change_direct(uuid,uuid,numeric,int,numeric,text)', 'execute'),
  'authenticated NO puede ejecutar _apply_rate_change_direct directamente'
);
select ok(
  not has_function_privilege('anon', 'public._apply_rate_change_direct(uuid,uuid,numeric,int,numeric,text)', 'execute'),
  'anon NO puede ejecutar _apply_rate_change_direct directamente'
);

-- ---------------------------------------------------------------------
-- 2) Fixtures (como postgres/superusuario).
-- ---------------------------------------------------------------------
create temp table fixture as
select b.contact_person_id
from public.bookings b
limit 1;

do $$
declare
  v_account uuid;
begin
  insert into public.receivable_accounts (name, kind)
  values ('Fixture Contract DDL', 'empresa')
  returning id into v_account;

  create temp table fixture_ids as
    select v_account as account_id;
end $$;

-- ---------------------------------------------------------------------
-- 3) Constraints de bookings.
-- ---------------------------------------------------------------------

-- (a, neg) rate_mode='person' sin agreed_unit_price_bs -> rechazado.
select throws_matching(
  $$ insert into public.bookings (contact_person_id, payer_mode, rate_mode, agreed_unit_price_bs, receivable_account_id)
     select contact_person_id, 'client', 'person', null, (select account_id from fixture_ids)
     from fixture $$,
  'bookings_person_rate_requires_price',
  'rate_mode=person sin agreed_unit_price_bs es rechazado'
);

-- (b, neg) rate_mode='person' con payer_mode='each_stay' -> rechazado
-- (persona por noche sólo tiene sentido en un contrato institucional).
select throws_matching(
  $$ insert into public.bookings (contact_person_id, payer_mode, rate_mode, agreed_unit_price_bs)
     select contact_person_id, 'each_stay', 'person', 300
     from fixture $$,
  'bookings_person_rate_requires_client',
  'rate_mode=person con payer_mode=each_stay es rechazado'
);

-- (c, neg) payer_mode='client' sin receivable_account_id -> rechazado.
select throws_matching(
  $$ insert into public.bookings (contact_person_id, payer_mode)
     select contact_person_id, 'client'
     from fixture $$,
  'bookings_client_requires_account',
  'payer_mode=client sin receivable_account_id es rechazado'
);

-- (a', positivo) combo válido: client + person + precio + cuenta -> pasa.
select lives_ok(
  $$ insert into public.bookings (contact_person_id, payer_mode, rate_mode, agreed_unit_price_bs, receivable_account_id)
     select contact_person_id, 'client', 'person', 300, (select account_id from fixture_ids)
     from fixture $$,
  'combo válido client+person+precio+cuenta es aceptado'
);

-- ---------------------------------------------------------------------
-- 3b) FIX de review (edaec2f -> sdd/group-billing/review-booking-9 #366 /
--     booking-9-fixes #367): agreed_unit_price_bs debe ser positivo en
--     rate_mode='person' (el CHECK original sólo pedía "no nulo": -50
--     pasaba) y prohibido (NULL) en rate_mode='room' (antes un precio
--     "muerto" en modo habitación pasaba sin problema, datos
--     inconsistentes sin razón de negocio).
-- ---------------------------------------------------------------------

-- (a2, neg) rate_mode='person' con agreed_unit_price_bs=0 -> rechazado.
select throws_matching(
  $$ insert into public.bookings (contact_person_id, payer_mode, rate_mode, agreed_unit_price_bs, receivable_account_id)
     select contact_person_id, 'client', 'person', 0, (select account_id from fixture_ids)
     from fixture $$,
  'bookings_person_rate_requires_price',
  'rate_mode=person con agreed_unit_price_bs=0 es rechazado'
);

-- (a3, neg) rate_mode='person' con agreed_unit_price_bs=-50 -> rechazado.
select throws_matching(
  $$ insert into public.bookings (contact_person_id, payer_mode, rate_mode, agreed_unit_price_bs, receivable_account_id)
     select contact_person_id, 'client', 'person', -50, (select account_id from fixture_ids)
     from fixture $$,
  'bookings_person_rate_requires_price',
  'rate_mode=person con agreed_unit_price_bs=-50 es rechazado'
);

-- (i, neg) rate_mode='room' con agreed_unit_price_bs=999 -> rechazado
-- (constraint NUEVA: un precio pactado no tiene sentido fuera de
-- rate_mode='person').
select throws_matching(
  $$ insert into public.bookings (contact_person_id, payer_mode, rate_mode, agreed_unit_price_bs)
     select contact_person_id, 'each_stay', 'room', 999
     from fixture $$,
  'bookings_room_rate_has_no_unit_price',
  'rate_mode=room con agreed_unit_price_bs=999 es rechazado'
);

-- (i', positivo) rate_mode='room' con agreed_unit_price_bs NULL -> aceptado
-- (comportamiento normal, sin cambios).
select lives_ok(
  $$ insert into public.bookings (contact_person_id, payer_mode, rate_mode, agreed_unit_price_bs)
     select contact_person_id, 'each_stay', 'room', null
     from fixture $$,
  'rate_mode=room con agreed_unit_price_bs NULL es aceptado'
);

-- (a4, positivo) rate_mode='person' con agreed_unit_price_bs=300 -> aceptado.
select lives_ok(
  $$ insert into public.bookings (contact_person_id, payer_mode, rate_mode, agreed_unit_price_bs, receivable_account_id)
     select contact_person_id, 'client', 'person', 300, (select account_id from fixture_ids)
     from fixture $$,
  'rate_mode=person con agreed_unit_price_bs=300 es aceptado'
);

-- (regresión) las 7 bookings each_stay/room preexistentes + la fixture
-- "room+precio NULL" insertada arriba (i', válida a propósito) siguen
-- siendo válidas tras las 6 ALTER TABLE de este slice (ninguna violó los
-- nuevos CHECK ni quedó con NULL en una columna NOT NULL nueva).
select is(
  (select count(*)::int from public.bookings where payer_mode = 'each_stay' and rate_mode = 'room'),
  8,
  'las 7 bookings each_stay preexistentes + 1 fixture nueva (room+precio NULL) quedaron válidas'
);

-- ---------------------------------------------------------------------
-- 4) Constraint de reservations (cortesía).
-- ---------------------------------------------------------------------

do $$
declare
  v_booking uuid;
  v_room uuid;
  v_room_type uuid;
begin
  select id into v_booking from public.bookings where payer_mode = 'each_stay' limit 1;
  select o.room_id, o.room_type_id into v_room, v_room_type
  from public.room_type_options o
  where o.room_id not in (select room_id from public.reservations)
  limit 1;

  create temp table fixture_courtesy as
    select v_booking as booking_id, v_room as room_id, v_room_type as room_type_id;
end $$;

-- (d, neg-1) is_courtesy=true con courtesy_reason NULL -> rechazado (el
-- CHECK usa coalesce(..., 0) para que NULL no "pase en silencio", a
-- diferencia de `not is_courtesy or char_length(trim(x)) > 0` a secas,
-- que en Postgres evalúa a NULL -- y NULL no viola un CHECK).
select throws_matching(
  $$ insert into public.reservations (
       room_id, room_type_id, check_in_date, check_out_date, num_guests,
       total_amount_bs, booking_id, is_courtesy, courtesy_reason
     )
     select room_id, room_type_id, '2027-01-01', '2027-01-03', 2,
       0, booking_id, true, null
     from fixture_courtesy $$,
  'reservations_courtesy_reason_required',
  'is_courtesy=true con courtesy_reason NULL es rechazado'
);

-- (d, neg-2) is_courtesy=true con courtesy_reason en blanco ('   ') -> rechazado.
select throws_matching(
  $$ insert into public.reservations (
       room_id, room_type_id, check_in_date, check_out_date, num_guests,
       total_amount_bs, booking_id, is_courtesy, courtesy_reason
     )
     select room_id, room_type_id, '2027-01-01', '2027-01-03', 2,
       0, booking_id, true, '   '
     from fixture_courtesy $$,
  'reservations_courtesy_reason_required',
  'is_courtesy=true con courtesy_reason en blanco es rechazado'
);

-- (d', positivo) is_courtesy=true con motivo real -> aceptado.
select lives_ok(
  $$ insert into public.reservations (
       room_id, room_type_id, check_in_date, check_out_date, num_guests,
       total_amount_bs, booking_id, is_courtesy, courtesy_reason
     )
     select room_id, room_type_id, '2027-02-01', '2027-02-03', 2,
       0, booking_id, true, 'Cortesía de gerencia'
     from fixture_courtesy $$,
  'is_courtesy=true con un motivo real es aceptado'
);

-- (regresión) las 7 reservas preexistentes (is_courtesy=false por default)
-- siguen siendo válidas.
select is(
  (select count(*)::int from public.reservations where is_courtesy = false),
  7,
  'las 7 reservas preexistentes quedaron con is_courtesy=false (default) y siguen siendo válidas'
);

-- ---------------------------------------------------------------------
-- 5) _resolve_receivable_account.
--
-- A partir de acá, los helpers insertan en columnas NOT NULL que dependen
-- de auth.uid() (rate_overrides.changed_by, rate_discount_requests.
-- requested_by/resolved_by) -- fijamos el JWT a 'root' como hace el
-- fixture de 16_group_billing_ledger_core.sql (auth.uid() sólo depende de
-- request.jwt.claims, no del rol real de Postgres de la sesión).
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);

-- (e, neg) id existente Y nombre nuevo a la vez -> rechazado.
select throws_matching(
  $$ select public._resolve_receivable_account(
       (select account_id from fixture_ids), 'Otra cuenta', 'empresa', null, null
     ) $$,
  'Elegí una cuenta existente O creá una nueva',
  '_resolve_receivable_account con id Y nombre nuevo a la vez es rechazado'
);

-- (neg) ni id ni nombre nuevo -> rechazado.
select throws_matching(
  $$ select public._resolve_receivable_account(null, null, null, null, null) $$,
  'Elegí una cuenta existente o indicá los datos de la nueva cuenta',
  '_resolve_receivable_account sin id ni nombre nuevo es rechazado'
);

-- (neg) id de una cuenta inactiva -> rechazado.
do $$
declare
  v_inactive uuid;
begin
  insert into public.receivable_accounts (name, kind, is_active)
  values ('Cuenta Inactiva Fixture', 'empresa', false)
  returning id into v_inactive;

  create temp table fixture_inactive as select v_inactive as account_id;
end $$;

select throws_matching(
  $$ select public._resolve_receivable_account((select account_id from fixture_inactive), null, null, null, null) $$,
  'Cuenta por cobrar inválida o inactiva',
  '_resolve_receivable_account con una cuenta inactiva es rechazado'
);

-- (neg) tipo de cuenta inválido al crear una nueva -> rechazado.
select throws_matching(
  $$ select public._resolve_receivable_account(null, 'Cuenta con tipo malo', 'invalido', null, null) $$,
  'Tipo de cuenta inválido',
  '_resolve_receivable_account con kind inválido es rechazado'
);

-- (f) sólo nombre nuevo -> inserta una fila en receivable_accounts y
-- devuelve su id. OJO: llamar a la función DENTRO del WHERE de un count()
-- la ejecutaría una vez por fila candidata (es VOLATILE) e insertaría de
-- más -- se captura el resultado UNA sola vez en un do block.
do $$
declare
  v_new_id uuid;
begin
  v_new_id := public._resolve_receivable_account(null, 'Hotel Fixture Nuevo', 'empresa', 'contacto@fixture.test', 'notas');
  create temp table fixture_new_account as select v_new_id as account_id;
end $$;

select is(
  (select count(*)::int from public.receivable_accounts where id = (select account_id from fixture_new_account)),
  1,
  '_resolve_receivable_account con sólo nombre nuevo inserta la cuenta y devuelve su id'
);

-- (existente) id existente, sin nombre nuevo -> devuelve el mismo id, sin
-- insertar una fila nueva.
select is(
  public._resolve_receivable_account((select account_id from fixture_ids), null, null, null, null),
  (select account_id from fixture_ids),
  '_resolve_receivable_account con un id existente devuelve el mismo id'
);

-- ---------------------------------------------------------------------
-- 6) _apply_rate_change_direct (extracción fiel de la rama directa de
--    apply_rate_change -- NO cambia apply_rate_change en este branch).
-- ---------------------------------------------------------------------

-- Reservas frescas dedicadas (no se reutilizan las 7 preexistentes, para
-- no mutar total_amount_bs de datos que otras aserciones ya dieron por
-- válidos más arriba).
do $$
declare
  v_booking uuid;
  v_room uuid;
  v_room_type uuid;
  v_reservation uuid;
begin
  select id into v_booking from public.bookings where payer_mode = 'each_stay' limit 1;
  select o.room_id, o.room_type_id into v_room, v_room_type
  from public.room_type_options o
  where o.room_id not in (select room_id from public.reservations)
  limit 1;

  insert into public.reservations (
    room_id, room_type_id, check_in_date, check_out_date, num_guests,
    total_amount_bs, booking_id, status
  ) values (
    v_room, v_room_type, '2027-03-01', '2027-03-03', 2, 960, v_booking, 'confirmed'
  ) returning id into v_reservation;

  create temp table fixture_rate as select v_reservation as reservation_id, v_room_type as room_type_id;
end $$;

-- (g) descuento >20% -> rate_overrides + rate_discount_requests
-- auto-'approved' (nunca 'pending').
select lives_ok(
  $$ select public._apply_rate_change_direct(
       (select reservation_id from fixture_rate),
       (select room_type_id from fixture_rate),
       480, 2, 300, 'Descuento institucional de prueba'
     ) $$,
  '_apply_rate_change_direct con descuento >20% no lanza'
);

select is(
  (select count(*)::int from public.rate_overrides where reservation_id = (select reservation_id from fixture_rate)),
  1,
  '_apply_rate_change_direct con descuento >20% inserta exactamente una fila en rate_overrides'
);

select is(
  (select status from public.rate_discount_requests where reservation_id = (select reservation_id from fixture_rate)),
  'approved',
  '_apply_rate_change_direct con descuento >20% audita una rate_discount_requests ya approved (nunca pending)'
);

-- (h) descuento <=20% -> sólo rate_overrides, sin fila en rate_discount_requests.
do $$
declare
  v_booking uuid;
  v_room uuid;
  v_room_type uuid;
  v_reservation uuid;
begin
  select id into v_booking from public.bookings where payer_mode = 'each_stay' limit 1;
  select o.room_id, o.room_type_id into v_room, v_room_type
  from public.room_type_options o
  where o.room_id not in (select room_id from public.reservations)
  limit 1;

  insert into public.reservations (
    room_id, room_type_id, check_in_date, check_out_date, num_guests,
    total_amount_bs, booking_id, status
  ) values (
    v_room, v_room_type, '2027-04-01', '2027-04-03', 2, 960, v_booking, 'confirmed'
  ) returning id into v_reservation;

  create temp table fixture_rate_small as select v_reservation as reservation_id, v_room_type as room_type_id;
end $$;

select lives_ok(
  $$ select public._apply_rate_change_direct(
       (select reservation_id from fixture_rate_small),
       (select room_type_id from fixture_rate_small),
       480, 2, 450, 'Ajuste chico de tarifa'
     ) $$,
  '_apply_rate_change_direct con descuento <=20% no lanza'
);

select is(
  (select count(*)::int from public.rate_overrides where reservation_id = (select reservation_id from fixture_rate_small)),
  1,
  '_apply_rate_change_direct con descuento <=20% inserta exactamente una fila en rate_overrides'
);

select is(
  (select count(*)::int from public.rate_discount_requests where reservation_id = (select reservation_id from fixture_rate_small)),
  0,
  '_apply_rate_change_direct con descuento <=20% NO inserta ninguna rate_discount_requests'
);

select * from finish();
rollback;
