-- =====================================================================
-- Tramos de estadía: extender, acortar y cambiar de habitación.
--
-- Es la lógica que decide cuánto paga el huésped, así que se verifica el
-- TOTAL resultante y no sólo que la función no explote.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

-- Se actúa como recepción (root/reception/reception_admin pueden).
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);

-- Estadía del seed: 3 noches a 350 = 1050, en curso.
create temp table caso on commit drop as
select r.id as res_id, r.room_id, r.check_in_date, r.check_out_date
from public.reservations r
where r.status = 'checked_in' and r.total_amount_bs = 1050.00
limit 1;

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
