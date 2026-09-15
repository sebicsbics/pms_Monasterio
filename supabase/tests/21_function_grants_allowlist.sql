-- =====================================================================
-- Lista blanca de funciones ejecutables por authenticated y anon
-- (change: group-billing, stage 6, branch fix/revoke-internal-function-grants).
--
-- EL PROBLEMA: 20260811000000_explicit_table_grants.sql hace
-- `grant all on all functions in schema public to anon, authenticated,
-- service_role` y después revoca a mano una lista corta de "excepciones".
-- Esa lista es un checklist manual: si una función interna nueva no se
-- agrega, queda abierta y nadie se entera hasta que alguien la explota.
-- Así se coló `apply_rate_change`: la revocó 20260722020000, la reabrió
-- 20260811000000 sin darse cuenta, y como `p_base_price_bs` lo manda el
-- que llama, cualquier `authenticated` podía cambiarle la tarifa a
-- cualquier reserva pasando base = precio nuevo (0% de descuento,
-- sin pasar por la aprobación).
--
-- LA DEFENSA: en vez de mantener otra lista manual de "hay que revocar
-- esto", este archivo afirma la lista COMPLETA de funciones que
-- authenticated puede ejecutar. Si mañana una migración vuelve a hacer
-- un `grant all on all functions ...` sin excepción, este test lo dice
-- exactamente: qué función se coló y por qué no debería estar.
--
-- Los tests (b)-(e) confirman además que ninguna función interna
-- adivina que quedar afuera de authenticated ROMPE a quien la llama por
-- SQL: create_reservation, override_reservation_rate,
-- walk_in_check_in_with_guests y approve_rate_discount_request corren
-- SECURITY DEFINER, así que sus llamadas internas a las funciones ahora
-- revocadas se ejecutan como el dueño (postgres), no como el rol que
-- inició la sesión. El GRANT es la puerta de entrada; adentro, quien
-- manda es el dueño de la función.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

-- ---------------------------------------------------------------------
-- (a) ALLOWLIST — authenticated. Se afirma el conjunto exacto: PUBLIC_RPC
--     (todo lo que src/ llama con supabase.rpc(...)) más los dos POLICY
--     HELPER que las políticas RLS necesitan (current_user_role, is_staff;
--     username_to_email ya está en PUBLIC_RPC porque el login lo llama
--     desde src/services/auth.ts) más net_owed_bs: todavía sin caller en
--     src/ (queda para un slice de UI posterior de este mismo cambio),
--     pero NO es un descuido del grant en bloque -- se otorgó a propósito
--     en su propia migración (20260911090000), tiene su propio guard de
--     rol interno (current_user_role() not in (...)) y ya pasó una
--     revisión de seguridad dedicada (sdd/group-billing/net-owed-guard).
--     record_booking_advance se suma en esta misma línea (branch
--     feat/booking-14-advance-rpc, Slice 4): otra RPC pública real,
--     otorgada en su propia migración, con el mismo guard de rol interno.
--     Si aparece cualquier otro nombre de más, es una función interna que
--     se coló por un grant en bloque.
-- ---------------------------------------------------------------------
select is(
  (select string_agg(p.proname, ', ' order by p.proname)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f'
      and has_function_privilege('authenticated', p.oid, 'execute')),
  'add_cash_movement, add_event_payment, add_folio_charge, add_folio_product_charge, '
  || 'add_guests_to_stay, approve_rate_discount_request, arrivals, assignable_staff, '
  || 'available_rooms, cancel_receivable, cancel_reservation, cash_session_history, '
  || 'change_room, check_in_reservation_with_guests, check_out_room, '
  || 'clear_password_change_flag, clock_in, clock_out, close_cash_session, '
  || 'create_bulk_reservation, create_employee, create_reservation, create_staff_member, '
  || 'create_ticket_from_schedule, current_user_role, delete_employee, force_clock_out, '
  || 'generate_housekeeping_assignments, is_staff, list_anticipos, list_info_notes, '
  || 'list_receivables, list_reservations_brief, list_tasks, lookup_guest_by_document, '
  || 'modify_anticipo, modify_stay_dates, my_profile, net_owed_bs, open_cash_session, '
  || 'open_time_entries, override_reservation_rate, record_anticipo, '
  || 'record_booking_advance, register_stock_entry, '
  || 'reject_rate_discount_request, reschedule_reservation, resolve_info_note, '
  || 'set_my_avatar, settle_receivable, username_to_email, void_cash_movement, '
  || 'walk_in_check_in_with_guests',
  'authenticated alcanza exactamente las RPC públicas + los 2 helpers de política + '
  || 'net_owed_bs + record_booking_advance (53 funciones) -- ni una interna de más'
);

-- ---------------------------------------------------------------------
-- (b) ALLOWLIST — anon. Sin cambios respecto de 04_anon_sin_privilegios.sql;
--     se reafirma acá para que este archivo documente la política completa
--     de grants de función en un solo lugar.
-- ---------------------------------------------------------------------
select is(
  (select string_agg(p.proname, ', ' order by p.proname)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f'
      and has_function_privilege('anon', p.oid, 'execute')),
  'current_user_role, is_staff, username_to_email',
  'anon sigue alcanzando sólo las 3 de siempre: el login y los 2 predicados de RLS'
);

-- ---------------------------------------------------------------------
-- (c) REPRO — apply_rate_change ya no es ejecutable directo, ni por
--     reception ni por reception_admin (es un permiso de grant, no una
--     decisión de rol: el bypass de reception_admin vive DENTRO de la
--     función, nunca se llega a evaluar si el grant ya lo frena antes).
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

set local role authenticated;

select throws_ok(
  $$ select public.apply_rate_change(
       (select id from public.reservations limit 1),
       (select room_type_id from public.reservations limit 1),
       999999, 1, 1, 'probe'
     ) $$,
  '42501', 'permission denied for function apply_rate_change',
  'REGRESIÓN: apply_rate_change ya no es ejecutable directo por reception'
);

reset role;
select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true); -- reception_admin
set local role authenticated;

select throws_ok(
  $$ select public.apply_rate_change(
       (select id from public.reservations limit 1),
       (select room_type_id from public.reservations limit 1),
       999999, 1, 1, 'probe'
     ) $$,
  '42501', 'permission denied for function apply_rate_change',
  'ni por reception_admin: el bypass de rol vive adentro de la función, el grant frena antes'
);

reset role;

-- ---------------------------------------------------------------------
-- (d) REPRO — un helper interno cualquiera (discount_pct) y una función
--     de trigger (handle_new_user) tampoco son ejecutables directo.
-- ---------------------------------------------------------------------
set local role authenticated;

select throws_ok(
  $$ select public.discount_pct(350, 300) $$,
  '42501', 'permission denied for function discount_pct',
  'discount_pct (helper interno) queda revocada de authenticated'
);

select throws_ok(
  $$ select public.handle_new_user() $$,
  '42501', 'permission denied for function handle_new_user',
  'handle_new_user (función de trigger) queda revocada de authenticated: '
  || 'un trigger corre igual, sin importar el grant'
);

reset role;

-- ---------------------------------------------------------------------
-- (e) REGRESIÓN — los llamadores SQL de apply_rate_change/walk_in_check_in
--     siguen funcionando: son SECURITY DEFINER, así que la llamada interna
--     corre como el dueño, no como el rol que inició la sesión.
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

-- Las búsquedas de habitación libre corren como postgres (no son lo que
-- se prueba); las llamadas a las RPC, más abajo, sí corren `set local
-- role authenticated` para ejercer exactamente el límite de permisos.
create temp table grants_room as
select o.room_id, o.room_type_id
from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
where rt.max_occupancy = 1 and rt.base_price_bs = 350
  and o.room_id not in (select room_id from public.reservations)
limit 1;
grant select on grants_room to authenticated;

-- create_reservation each_stay con tarifa custom (>20% de descuento):
-- antes creaba una solicitud pending llamando a apply_rate_change por
-- dentro; sigue haciéndolo igual aunque apply_rate_change ya no sea
-- ejecutable por authenticated de forma directa.
set local role authenticated;
create temp table grants_reservation as
select public.create_reservation(
  (select room_id from grants_room), (select room_type_id from grants_room),
  'Grants', 'Allowlist', '70000199', 'grants.allowlist@fixture.test',
  '2027-09-10', '2027-09-12', 1, 'phone', 200, 'Prueba de allowlist: descuento grande', true
) as reservation_id;
reset role;

select is(
  (select status from public.rate_discount_requests
    where reservation_id = (select reservation_id from grants_reservation)),
  'pending',
  '(e) create_reservation each_stay con tarifa custom sigue creando la solicitud pending '
  || '(corre SECURITY DEFINER, la llamada interna a apply_rate_change no depende del grant '
  || 'de authenticated)'
);

-- override_reservation_rate (RoomPanel/ArrivalsList) sigue funcionando.
create temp table grants_room2 as
select o.room_id, o.room_type_id
from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
where rt.max_occupancy = 1 and rt.base_price_bs = 350
  and o.room_id not in (select room_id from public.reservations)
limit 1;
grant select on grants_room2 to authenticated;

set local role authenticated;
create temp table grants_reservation2 as
select public.create_reservation(
  (select room_id from grants_room2), (select room_type_id from grants_room2),
  'Grants', 'Override', '70000198', 'grants.override@fixture.test',
  '2027-09-10', '2027-09-12', 1, 'phone', null, null, true
) as reservation_id;

select lives_ok(
  $$ select public.override_reservation_rate(
       (select reservation_id from grants_reservation2), 300, 'Allowlist: llamador indirecto'
     ) $$,
  '(e) override_reservation_rate sigue funcionando (llamador indirecto de apply_rate_change)'
);
reset role;

-- walk_in_check_in_with_guests con tarifa custom sigue funcionando: por
-- dentro llama a walk_in_check_in, que ahora es interna.
create temp table grants_walkin_room as
select r.id as room_id, r.room_type_id
from public.rooms r
where r.operational_status = 'available'
limit 1;
grant select on grants_walkin_room to authenticated;

set local role authenticated;
select lives_ok(
  format(
    $$ select public.walk_in_check_in_with_guests(%L, %L, 'Grants', 'WalkIn', '70000197',
         'grants.walkin@fixture.test', '1990-01-01', 'BO', 'La Paz', true, 1,
         (select rt.base_price_bs * 0.9 from public.room_types rt where rt.id = %L),
         'Allowlist: tarifa custom en walk-in') $$,
    (select room_id from grants_walkin_room),
    (select room_type_id from grants_walkin_room),
    (select room_type_id from grants_walkin_room)
  ),
  '(e) walk_in_check_in_with_guests con tarifa custom sigue funcionando '
  || '(walk_in_check_in queda interna pero el wrapper es SECURITY DEFINER)'
);
reset role;

-- approve_rate_discount_request sobre la solicitud pending de arriba.
select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true); -- reception_admin

set local role authenticated;
select lives_ok(
  format(
    $$ select public.approve_rate_discount_request(%L) $$,
    (select id from public.rate_discount_requests
      where reservation_id = (select reservation_id from grants_reservation))
  ),
  '(e) approve_rate_discount_request sigue funcionando sobre la solicitud pending'
);
reset role;

select is(
  (select status from public.rate_discount_requests
    where reservation_id = (select reservation_id from grants_reservation)),
  'approved',
  '(e) ... y la deja approved'
);

select * from finish();
rollback;
