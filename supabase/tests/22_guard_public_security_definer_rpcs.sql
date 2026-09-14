-- =====================================================================
-- Guard de rol en RPC públicas SECURITY DEFINER que no lo tenían
-- (change: group-billing, stage 6, branch fix/revoke-internal-function-grants,
-- fix posterior a la revisión de seguridad del branch).
--
-- LO QUE ENCONTRÓ LA REVISIÓN: `assignable_staff()`,
-- `check_in_reservation_with_guests(...)` y `walk_in_check_in_with_guests(...)`
-- son SECURITY DEFINER, están otorgadas a `authenticated` (correctamente:
-- son RPC públicas reales, llamadas desde src/), pero NUNCA llaman a
-- `current_user_role()`/`is_staff()`. Una cuenta recién autoregistrada
-- (rol 'pending' -- `handle_new_user()` se lo asigna siempre, nunca lee
-- el rol del metadata del cliente, ver 20260810010000) puede invocarlas
-- igual que cualquier `authenticated`. Confirmado en vivo: una cuenta
-- 'pending' llamando `assignable_staff()` se trae el legajo completo de
-- personal (nombre + puesto) sin ninguna precondición.
--
-- LÍMITES DE ESTE TEST (leer antes de confiar en él):
--   * La aserción general (e) busca `current_user_role()`/`is_staff()` en
--     el texto de la función: prueba PRESENCIA, no CORRECCIÓN. Un comentario
--     que los mencione, o un guard con la lógica invertida, también pasa.
--     Cada guard nuevo necesita además su propio test con un rol no
--     autorizado.
--   * (b)/(c) ya pasaban antes del fix porque las funciones internas
--     (`check_in_reservation`/`walk_in_check_in`) tienen su propio guard.
--     Confirman el comportamiento; el respaldo ante una regresión es (e).
--
-- `check_in_reservation_with_guests` es más grave todavía: hace escrituras
-- reales (crea/actualiza `people`, `guests`, `reservation_guests`,
-- `occupancy_overrides`, `reservations.guest_id`) ANTES de llamar a
-- `check_in_reservation`, que sí tiene guard -- si el guard interno frena,
-- Postgres deshace esas escrituras porque la excepción aborta la
-- sentencia entera (no hay INSERT/UPDATE que sobreviva), pero mientras
-- tanto ya se leyó `reservations`/`room_types` sin RLS (SECURITY DEFINER
-- las bypasea) para cualquiera con un UUID de reserva.
-- `walk_in_check_in_with_guests` es más leve en la práctica (su primera
-- escritura real vive adentro de `walk_in_check_in`, que también tiene
-- guard propio), pero igual queda sin barrera propia.
--
-- LA DEFENSA: guard como primera sentencia en las 3, mismo patrón que ya
-- usa el resto del código (`current_user_role() not in (...)`, mensaje en
-- español), MÁS una aserción general sobre TODA función pública SECURITY
-- DEFINER ejecutable por authenticated: o menciona
-- current_user_role()/is_staff() en el cuerpo, o está en una lista
-- explícita y comentada de excepciones legítimas (self-scoping por
-- auth.uid(), no por rol). Así la próxima RPC sin guard no se cuela.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

-- ---------------------------------------------------------------------
-- Fixture: cuenta recién autoregistrada. Se inserta en auth.users (no en
-- profiles directo: profiles.id es FK a auth.users, y así se dispara
-- handle_new_user() exactamente como en un alta real, confirmando que el
-- rol queda 'pending' por default de la columna y NO por el metadata del
-- cliente -- mismo patrón de insert que supabase/seed.sql:34-48.
-- ---------------------------------------------------------------------
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  created_at, updated_at, raw_app_meta_data, raw_user_meta_data,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
) values (
  '99999999-9999-9999-9999-999999999999', '00000000-0000-0000-0000-000000000000',
  'authenticated', 'authenticated', 'guard.fixture@local.test',
  crypt('local1234', gen_salt('bf')), now(), now(), now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', 'Cuenta Pendiente'),
  '', '', '', '', '', '', '', ''
);

select is(
  (select role from public.profiles where id = '99999999-9999-9999-9999-999999999999'),
  'pending',
  'fixture: un alta fresca (handle_new_user) queda en pending, nunca toma rol del metadata'
);

-- ---------------------------------------------------------------------
-- Fixtures de reserva/habitación para los repros de check-in.
-- ---------------------------------------------------------------------
create temp table guard_room_checkin as
select o.room_id, o.room_type_id
from public.room_type_options o join public.room_types rt on rt.id = o.room_type_id
where rt.max_occupancy = 1 and rt.base_price_bs = 350
  and o.room_id not in (select room_id from public.reservations)
limit 1;

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

create temp table guard_reservation_pending_blocked as
select public.create_reservation(
  (select room_id from guard_room_checkin), (select room_type_id from guard_room_checkin),
  'Guard', 'Bloqueado', '70000196', 'guard.bloqueado@fixture.test',
  '2027-09-10', '2027-09-12', 1, 'phone', null, null, true
) as reservation_id;
-- Se lee más abajo bajo `set local role authenticated` (pending y
-- reception): sin este grant, el SELECT de la subquery en el `format()`
-- rompe con "permission denied for table" antes de llegar siquiera a
-- invocar la RPC (misma trampa que en 21_function_grants_allowlist.sql).
grant select on guard_reservation_pending_blocked to authenticated;

-- Snapshot ANTES del intento de pending. OJO: esta función NO es
-- SECURITY DEFINER, así que corre con los privilegios (y la RLS) de
-- quien la llama -- por eso el snapshot "después" se toma también como
-- postgres (ver más abajo, tras el `reset role`), nunca mientras el rol
-- activo es `authenticated`/pending: si no, la RLS de pending (que no ve
-- nada) haría que el snapshot diera siempre "vacío" sin importar si el
-- guard nuevo funciona o no, y el test pasaría por la razón equivocada.
create or replace function pg_temp.snap_checkin(v_res uuid) returns text language sql as $$
  select row(
    (select status from public.reservations where id = v_res),
    (select count(*) from public.reservation_guests where reservation_id = v_res),
    (select count(*) from public.occupancy_overrides where reservation_id = v_res),
    (select count(*) from public.people)
  )::text
$$;

create temp table guard_snap_before as
  select pg_temp.snap_checkin((select reservation_id from guard_reservation_pending_blocked)) as s;

-- ---------------------------------------------------------------------
-- (a) assignable_staff(): pending rebota, mensaje en español, sin filas.
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"99999999-9999-9999-9999-999999999999","role":"authenticated"}', true); -- pending
set local role authenticated;

select throws_ok(
  $$ select * from public.assignable_staff() $$,
  'P0001', 'No autorizado',
  'assignable_staff: una cuenta pending rebota con No autorizado'
);

-- ---------------------------------------------------------------------
-- (b) check_in_reservation_with_guests: pending rebota, CERO efectos
--     secundarios (ni people, ni reservation_guests, ni el status de la
--     reserva cambian).
-- ---------------------------------------------------------------------
select throws_ok(
  format(
    $$ select public.check_in_reservation_with_guests(%L, '70000196', '1990-01-01', 'BO', 'La Paz', true) $$,
    (select reservation_id from guard_reservation_pending_blocked)
  ),
  'P0001', 'No autorizado para hacer check-in',
  'check_in_reservation_with_guests: pending rebota con el mismo mensaje que check_in_reservation'
);

reset role;

-- Snapshot DESPUÉS, otra vez como postgres -- comparable de verdad
-- contra el "antes" tomado también como postgres.
select is(
  (select pg_temp.snap_checkin((select reservation_id from guard_reservation_pending_blocked))),
  (select s from guard_snap_before),
  'check_in_reservation_with_guests: cero efectos secundarios -- ni people, ni reservation_guests, '
  || 'ni occupancy_overrides, ni el status de la reserva cambiaron con el intento de pending'
);

-- ---------------------------------------------------------------------
-- (c) walk_in_check_in_with_guests: pending rebota, no aparece reserva
--     nueva en la habitación.
-- ---------------------------------------------------------------------
create temp table guard_room_walkin as
select r.id as room_id, r.room_type_id
from public.rooms r
where r.operational_status = 'available'
  and r.id not in (select room_id from guard_room_checkin)
limit 1;
grant select on guard_room_walkin to authenticated;

-- No se asume "0 reservas": una habitación operacionalmente 'available'
-- HOY puede tener una reserva confirmada a futuro (el walk-in no mira
-- fechas, sólo el estado operativo). Se compara contra este "antes",
-- no contra un 0 fijo.
create temp table guard_walkin_count_before as
  select count(*)::int as n from public.reservations
  where room_id = (select room_id from guard_room_walkin);

select set_config('request.jwt.claims',
  '{"sub":"99999999-9999-9999-9999-999999999999","role":"authenticated"}', true); -- pending
set local role authenticated;

select throws_ok(
  format(
    $$ select public.walk_in_check_in_with_guests(%L, %L, 'Guard', 'Bloqueado2', '70000195',
         'guard.bloqueado2@fixture.test', '1990-01-01', 'BO', 'La Paz', true, 1) $$,
    (select room_id from guard_room_walkin),
    (select room_type_id from guard_room_walkin)
  ),
  'P0001', 'No autorizado para hacer check-in',
  'walk_in_check_in_with_guests: pending rebota con el mismo mensaje que walk_in_check_in'
);

reset role;

-- Otra vez como postgres, comparable contra el "antes".
select is(
  (select count(*)::int from public.reservations where room_id = (select room_id from guard_room_walkin)),
  (select n from guard_walkin_count_before),
  'walk_in_check_in_with_guests: pending no logró crear ninguna reserva'
);

-- ---------------------------------------------------------------------
-- (d) un rol permitido sigue funcionando -- las 3 funciones, con roles
--     reales de la app.
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception
set local role authenticated;

select lives_ok(
  $$ select * from public.assignable_staff() $$,
  'assignable_staff: reception (OPERATIONS) sigue funcionando'
);
reset role;

select set_config('request.jwt.claims',
  '{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated"}', true); -- accountant
set local role authenticated;

select lives_ok(
  $$ select * from public.assignable_staff() $$,
  'assignable_staff: accountant también (MaintenanceView lo llama sin gatear por escritura, tab SHARED)'
);
reset role;

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception
set local role authenticated;

select lives_ok(
  format(
    $$ select public.check_in_reservation_with_guests(%L, '70000196', '1990-01-01', 'BO', 'La Paz', true) $$,
    (select reservation_id from guard_reservation_pending_blocked)
  ),
  'check_in_reservation_with_guests: reception sigue haciendo el check-in real'
);
select is(
  (select status from public.reservations where id = (select reservation_id from guard_reservation_pending_blocked)),
  'checked_in',
  '... y la reserva queda checked_in de verdad'
);

select lives_ok(
  format(
    $$ select public.walk_in_check_in_with_guests(%L, %L, 'Guard', 'Reception', '70000194',
         'guard.reception@fixture.test', '1990-01-01', 'BO', 'La Paz', true, 1) $$,
    (select room_id from guard_room_walkin),
    (select room_type_id from guard_room_walkin)
  ),
  'walk_in_check_in_with_guests: reception sigue pudiendo hacer el walk-in'
);
reset role;

-- ---------------------------------------------------------------------
-- (e) ASERCIÓN GENERAL: toda función pública SECURITY DEFINER ejecutable
--     por authenticated menciona current_user_role()/is_staff() en el
--     cuerpo, o está en la lista explícita de excepciones legítimas
--     (self-scoping por auth.uid(), no necesitan lista de roles). Si
--     mañana se agrega una RPC sin guard, este test dice cuál.
-- ---------------------------------------------------------------------
select is(
  (select string_agg(p.proname, ', ' order by p.proname)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f' and p.prosecdef
      and has_function_privilege('authenticated', p.oid, 'execute')
      and not (pg_get_functiondef(p.oid) ilike '%current_user_role()%'
               or pg_get_functiondef(p.oid) ilike '%is_staff()%')
      and p.proname not in (
        -- Predicados de rol/política: no se guardan a sí mismos.
        'current_user_role', 'is_staff', 'username_to_email',
        -- Self-scoping por auth.uid() = propia fila: cualquier authenticated
        -- (incluido pending) puede leer/tocar SU PROPIO perfil, no hay
        -- dato ajeno que filtrar.
        'my_profile', 'set_my_avatar', 'clear_password_change_flag'
      )),
  null,
  'ninguna función pública SECURITY DEFINER ejecutable por authenticated se queda sin guard de rol '
  || 'ni sin estar en la lista explícita de excepciones self-scoped'
);

select * from finish();
rollback;
