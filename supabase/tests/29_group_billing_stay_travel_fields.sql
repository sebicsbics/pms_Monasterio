-- =====================================================================
-- Travel fields (origin_city, travel_purpose, transport_means) move to
-- reservation_guests (change: group-billing, stage 6, Slice 8a, branch
-- feat/booking-19-travel-fields-ddl). Spec R8.1, R8.2.
--
-- (a) el huésped tiene esos datos en `guests` (capturados por el
--     check-in de HOY, que todavía escribe en `guests`) y, tras el
--     backfill, su estadía MÁS RECIENTE en `reservation_guests` los
--     recibe.
-- (b, neg) una estadía MÁS ANTIGUA del mismo huésped queda en NULL
--     (comportamiento "lossy" documentado a propósito, R8.2 -- no es
--     un bug).
-- (c) volver a correr el backfill es idempotente (no falla, no
--     duplica).
-- (d) el conteo de personas con algún dato de viaje coincide entre
--     `guests` y `reservation_guests` tras el backfill (V-E).
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true); -- reception

-- ---------------------------------------------------------------------
-- Fixture: un huésped repetido con DOS estadías. La más antigua se
-- crea y hace check-in primero; la más reciente después. Se capturan
-- los datos de viaje en `guests` DESPUÉS de la estadía antigua (para
-- que la estadía antigua nunca tenga esos datos "en su momento" -- solo
-- importa que su reservation_guests row exista antes del backfill y
-- reciba NULL de todos modos).
-- ---------------------------------------------------------------------
do $$
declare
  v_room_id uuid; v_room_type_id uuid;
  v_res_old uuid; v_res_new uuid;
begin
  -- estadía antigua (fecha anterior): check-in SIN datos de viaje
  -- (nunca los capturó en su momento).
  select o.room_id, o.room_type_id into v_room_id, v_room_type_id
  from public.room_type_options o
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where not exists (
    select 1 from public.reservations x where x.room_id = o.room_id
      and x.status in ('confirmed','checked_in')
      and x.check_in_date < '2034-03-05' and '2034-03-01' < x.check_out_date
  ) limit 1;

  v_res_old := public.create_reservation(
    v_room_id, v_room_type_id, 'Viajera', 'Repetida',
    '70000040', null, '2034-03-01', '2034-03-05', 1, 'phone',
    null, null, false
  );
  perform public.check_in_reservation_with_guests(
    p_reservation_id => v_res_old, p_document => '11100040', p_birth_date => '1990-01-01'::date,
    p_country_code => 'BO', p_city => 'La Paz', p_wants_offers => false,
    p_holder_first_name => 'Viajera', p_holder_last_name => 'Repetida'
  );

  -- estadía más reciente (misma persona vía mismo documento -> dedupe
  -- por documento reutiliza el mismo person_id), fecha posterior, otra
  -- habitación, esta vez SÍ captura datos de viaje en `guests` (todavía
  -- el único lugar donde `check_in_reservation_with_guests` los escribe
  -- en esta rama -- los write sites migran a reservation_guests en la
  -- Slice 8b).
  select o.room_id, o.room_type_id into v_room_id, v_room_type_id
  from public.room_type_options o
  join public.rooms rm0 on rm0.id = o.room_id and rm0.operational_status = 'available'
  where not exists (
    select 1 from public.reservations x where x.room_id = o.room_id
      and x.status in ('confirmed','checked_in')
      and x.check_in_date < '2034-04-05' and '2034-04-01' < x.check_out_date
  ) limit 1;

  v_res_new := public.create_reservation(
    v_room_id, v_room_type_id, 'Viajera', 'Repetida',
    '70000041', null, '2034-04-01', '2034-04-05', 1, 'phone',
    null, null, false
  );
  perform public.check_in_reservation_with_guests(
    p_reservation_id => v_res_new, p_document => '11100040', p_birth_date => '1990-01-01'::date,
    p_country_code => 'BO', p_city => 'La Paz', p_wants_offers => false,
    p_origin_city => 'Santa Cruz', p_travel_purpose => 'Turismo', p_transport_means => 'Bus',
    p_holder_first_name => 'Viajera', p_holder_last_name => 'Repetida'
  );

  create temp table fixture_travel as
  select v_res_old as res_old, v_res_new as res_new;
end $$;

-- ---------------------------------------------------------------------
-- Verificación de fixtures previa al backfill (V-E, T19.0): confirmada
-- por el orquestador antes de esta corrida (0 filas con created_at
-- NULL en una base recién reseteada) -- no se repite acá, solo se deja
-- constancia de que la query del backfill NO necesita el guard
-- coalesce(rg.created_at, '-infinity').
--
-- El backfill de la migración es de UNA SOLA VEZ (corre al aplicar la
-- migración, antes de que existan los fixtures de este test). Para
-- probar su comportamiento sobre datos "ya existentes" lo corremos acá
-- explícitamente, IDÉNTICO al de la migración, sobre los fixtures recién
-- creados (esto es lo que hace, en los hechos, cualquier backfill: migra
-- lo que exista en ese momento).
-- ---------------------------------------------------------------------
with latest_stay as (
  select distinct on (rg.person_id) rg.id as rg_id
  from public.reservation_guests rg join public.reservations r on r.id = rg.reservation_id
  order by rg.person_id, r.check_in_date desc, rg.created_at desc
)
update public.reservation_guests rg
set origin_city = g.origin_city, travel_purpose = g.travel_purpose, transport_means = g.transport_means
from public.guests g, latest_stay ls
where g.person_id = rg.person_id and rg.id = ls.rg_id
  and (g.origin_city is not null or g.travel_purpose is not null or g.transport_means is not null);

-- =======================================================================
-- (a) la estadía MÁS RECIENTE recibe los datos de viaje tras el backfill.
-- =======================================================================
select is(
  (select origin_city from public.reservation_guests
    where reservation_id = (select res_new from fixture_travel) and role = 'holder'),
  'Santa Cruz',
  '(a1) origin_city migra a la estadía más reciente'
);
select is(
  (select travel_purpose from public.reservation_guests
    where reservation_id = (select res_new from fixture_travel) and role = 'holder'),
  'Turismo',
  '(a2) travel_purpose migra a la estadía más reciente'
);
select is(
  (select transport_means from public.reservation_guests
    where reservation_id = (select res_new from fixture_travel) and role = 'holder'),
  'Bus',
  '(a3) transport_means migra a la estadía más reciente'
);

-- =======================================================================
-- (b, neg) la estadía MÁS ANTIGUA del mismo huésped queda en NULL.
-- =======================================================================
select is(
  (select origin_city from public.reservation_guests
    where reservation_id = (select res_old from fixture_travel) and role = 'holder'),
  null,
  '(b) la estadía más antigua NO recibe los datos (comportamiento lossy, R8.2)'
);

-- =======================================================================
-- (c) volver a correr el backfill es idempotente.
-- =======================================================================
select lives_ok(
  $$
  with latest_stay as (
    select distinct on (rg.person_id) rg.id as rg_id
    from public.reservation_guests rg join public.reservations r on r.id = rg.reservation_id
    order by rg.person_id, r.check_in_date desc, rg.created_at desc
  )
  update public.reservation_guests rg
  set origin_city = g.origin_city, travel_purpose = g.travel_purpose, transport_means = g.transport_means
  from public.guests g, latest_stay ls
  where g.person_id = rg.person_id and rg.id = ls.rg_id
    and (g.origin_city is not null or g.travel_purpose is not null or g.transport_means is not null)
  $$,
  '(c) re-correr el backfill no falla (idempotente)'
);
select is(
  (select origin_city from public.reservation_guests
    where reservation_id = (select res_new from fixture_travel) and role = 'holder'),
  'Santa Cruz',
  '(c2) re-correr el backfill no altera el resultado ya migrado'
);

-- =======================================================================
-- (d) verificación V-E (T19.3), acotada al huésped fixture de este test
--     -- el conteo GLOBAL guests-vs-reservation_guests puede diferir
--     legítimamente si algún `guests` de datos semilla no tiene ninguna
--     fila en `reservation_guests` (nunca hizo check-in de ninguna
--     estadía real, así que no hay a dónde migrar); eso no es un defecto
--     del backfill. Para el huésped de ESTE fixture (que sí tiene
--     estadías reales), el conteo debe coincidir 1 a 1.
-- =======================================================================
select is(
  (select count(distinct g.person_id)::int from public.guests g
    where g.person_id = (select person_id from public.guests where passport_number = '11100040')
      and (g.origin_city is not null or g.travel_purpose is not null or g.transport_means is not null)),
  (select count(distinct rg.person_id)::int from public.reservation_guests rg
    where rg.person_id = (select person_id from public.guests where passport_number = '11100040')
      and (rg.origin_city is not null or rg.travel_purpose is not null or rg.transport_means is not null)),
  '(d) conteo de personas con datos de viaje coincide entre guests y reservation_guests (fixture)'
);

select * from finish();
rollback;
