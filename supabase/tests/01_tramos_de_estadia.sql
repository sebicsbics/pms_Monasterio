-- =====================================================================
-- Tramos de estadía: extender, acortar y cambiar de habitación.
--
-- Es la lógica que decide cuánto paga el huésped, así que se verifica el
-- TOTAL resultante y no sólo que la función no explote.
--
-- FIXTURE PROPIA, relativa a current_date (revisión 2026-09-14, group-
-- billing stage 6 / sdd/group-billing/booking-9-fixes #367 punto 5):
-- antes este archivo leía la estadía "en curso" del seed
-- (`status='checked_in' and total_amount_bs=1050.00`), cuyas fechas
-- (`current_date - 2` .. `current_date + 1`) quedan fijas en la fila
-- desde el momento en que corrió `supabase/seed.sql`. Como el seed no se
-- re-corre en cada test run, una base local "envejecida" (varios días
-- después del seed) hace que esas fechas queden en el pasado respecto al
-- current_date REAL del momento del test -- y `modify_stay_dates` (única
-- función de este stage que valida contra `current_date`, ver
-- 20260807000000_cash_history_and_stay_dates.sql:196) empieza a rechazar
-- el escenario "acortar hasta la salida original" con "noches ya
-- dormidas". Se confirmó el problema re-produciéndolo en una base con 3
-- días de antigüedad desde el seed.
--
-- La fixture ahora arma su PROPIA reserva `checked_in` con fechas
-- calculadas desde `current_date` DENTRO de esta misma transacción
-- (mismo patrón que 08_booking_foundation.sql/16_*/17_*: insertar
-- room/room_type/booking/reservation directo, sin pasar por una RPC), así
-- que la estadía sigue "en curso hoy" sin importar cuántos días pasaron
-- desde el último seed. El trigger `trg_sync_single_stay_segment` (mismo
-- que usa el seed) crea el tramo inicial automáticamente al insertar la
-- reserva -- no hace falta insertarlo a mano. Cada assertion original
-- se mantiene con el MISMO valor esperado (3 noches x 350 = 1050, etc.).
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

-- Se actúa como recepción (root/reception/reception_admin pueden).
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);

-- Estadía propia: 3 noches a 350 = 1050, "en curso" (entró hace 2 días,
-- salida pactada para mañana) -- misma forma que tenía la fila del seed,
-- pero construida ahora mismo relativa a current_date.
do $$
declare
  v_person  uuid;
  v_booking uuid;
  v_room    uuid;
  v_room_type uuid;
  v_reservation uuid;
begin
  insert into public.people (first_name, last_name, email)
  values ('Fixture', 'Tramos de Estadía', 'fixture.tramos-de-estadia@test.local')
  returning id into v_person;

  insert into public.bookings (contact_person_id, payer_mode)
  values (v_person, 'each_stay')
  returning id into v_booking;

  -- Habitación libre: ninguna otra reserva (seed ni de otros tests) la usa.
  select o.room_id, o.room_type_id into v_room, v_room_type
  from public.room_type_options o
  where o.room_id not in (select room_id from public.reservations where room_id is not null)
  limit 1;

  insert into public.reservations (
    guest_id, room_id, room_type_id, check_in_date, check_out_date,
    num_guests, total_amount_bs, status, booking_id
  ) values (
    null, v_room, v_room_type, current_date - 2, current_date + 1,
    1, 1050.00, 'checked_in', v_booking
  ) returning id into v_reservation;

  create temp table caso on commit drop as
    select v_reservation as res_id, v_room as room_id,
           (current_date - 2)::date as check_in_date,
           (current_date + 1)::date as check_out_date;
end $$;

select is(
  (select count(*)::int from public.stay_segments s join caso c on c.res_id = s.reservation_id),
  1,
  'la reserva nace con UN tramo, creado por el trigger'
);
select is(
  (select sum((s.end_date - s.start_date) * s.rate_bs) from public.stay_segments s join caso c on c.res_id = s.reservation_id),
  1050.00::numeric,
  'el tramo inicial reproduce el total de la reserva'
);

-- ---------- EXTENDER ----------
select is(
  (select public.modify_stay_dates((select room_id from caso),
                                   (select check_out_date + 2 from caso), 400, 'se queda más')),
  1850.00::numeric,
  'extender 2 noches a 400 suma 800 al total (1050 + 800)'
);
select is(
  (select count(*)::int from public.stay_segments s join caso c on c.res_id = s.reservation_id),
  2,
  'una tarifa distinta abre un tramo nuevo en vez de estirar el anterior'
);
select is(
  (select max(s.end_date) from public.stay_segments s join caso c on c.res_id = s.reservation_id),
  (select check_out_date + 2 from caso),
  'la salida de la reserva se movió con el tramo'
);

-- Extender otra vez a la MISMA tarifa estira el tramo, no crea otro.
select is(
  (select public.modify_stay_dates((select room_id from caso),
                                   (select check_out_date + 3 from caso), 400, 'una más')),
  2250.00::numeric,
  'la noche extra al mismo precio suma 400'
);
select is(
  (select count(*)::int from public.stay_segments s join caso c on c.res_id = s.reservation_id),
  2,
  'a igual tarifa se estira el tramo: el folio no se parte en líneas repetidas'
);

-- ---------- ACORTAR ----------
select is(
  (select public.modify_stay_dates((select room_id from caso),
                                   (select check_out_date + 1 from caso), null, 'se va antes')),
  1450.00::numeric,
  'acortar deja de cobrar las noches quitadas (1050 + 400)'
);
select is(
  (select count(*)::int from public.stay_segments s join caso c on c.res_id = s.reservation_id),
  2,
  'el tramo que cruza la nueva salida se recorta, no se borra'
);

-- Acortar hasta antes de que empezara el segundo tramo lo elimina.
select is(
  (select public.modify_stay_dates((select room_id from caso),
                                   (select check_out_date from caso), null, 'vuelve al plan original')),
  1050.00::numeric,
  'volver a la salida original restaura el total inicial'
);
select is(
  (select count(*)::int from public.stay_segments s join caso c on c.res_id = s.reservation_id),
  1,
  'los tramos que quedan fuera de la estadía se eliminan'
);

-- ---------- RECHAZOS ----------
select throws_ok(
  format($$ select public.modify_stay_dates(%L, %L, null, 'x') $$,
         (select room_id from caso), (select check_out_date from caso)),
  'P0001', null,
  'mover la salida a la fecha que ya tiene se rechaza'
);
select throws_ok(
  format($$ select public.modify_stay_dates(%L, %L, null, 'x') $$,
         (select room_id from caso), (select check_in_date from caso)),
  'P0001', null,
  'la salida no puede ser anterior o igual a la entrada'
);
select throws_ok(
  format($$ select public.modify_stay_dates(%L, %L, null, 'x') $$,
         (select room_id from caso), (select check_out_date + 5 from caso)),
  'P0001', null,
  'extender sin indicar tarifa se rechaza: las noches nuevas hay que valorarlas'
);

select * from finish();
rollback;
