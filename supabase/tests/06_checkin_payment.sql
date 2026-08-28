-- =====================================================================
-- Pago al check-in: reutiliza record_anticipo sin cambios (PR 2 de
-- checkin-payment-and-agency). No hay RPC nueva ni firma nueva: este
-- archivo es 100% regresión, probando que record_anticipo se comporta
-- igual cuando se invoca justo después de un check-in que cuando se
-- invoca de forma independiente (como ya hace RecordAnticipoView).
--
-- El escenario crítico es el de caja cerrada (decisión #5): el check-in
-- debe quedar firme aunque el cobro se rechace. Por eso el assert clave
-- no es solo "record_anticipo explota", es "reservations.status sigue
-- checked_in después de que explotó".
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);

create temp table casos on commit drop as
select r.id as res_id, row_number() over (order by r.id) as n
from public.reservations r
where r.status = 'confirmed'
order by r.id
limit 2;

-- ---------- 1) Caja abierta (estado del seed): check-in + pago EFECTIVO ----------
select lives_ok(
  format(
    $$ select public.check_in_reservation_with_guests(%L, '77777777', '1990-01-01', 'BO', 'La Paz', true) $$,
    (select res_id from casos where n = 1)
  ),
  'check-in del caso 1 no explota'
);
select lives_ok(
  format(
    $$ select public.record_anticipo(%L, 100.00, 'EFECTIVO', 'Pago al check-in') $$,
    (select res_id from casos where n = 1)
  ),
  'con caja abierta, record_anticipo llamado justo después del check-in no explota (regresión)'
);
select is(
  (select status from public.reservations where id = (select res_id from casos where n = 1)),
  'checked_in',
  'la reserva queda checked_in después del pago exitoso'
);
select is(
  (select status from public.anticipos
     where reservation_id = (select res_id from casos where n = 1) and amount_bs = 100.00
     order by received_at desc limit 1),
  'active',
  'el anticipo queda activo (mismo comportamiento que un anticipo standalone)'
);

-- ---------- 2) Caja cerrada: check-in se mantiene, el pago se rechaza ----------
update public.cash_sessions set status = 'closed', closed_at = now(), counted_balance_bs = 500
where status = 'open';

select lives_ok(
  format(
    $$ select public.check_in_reservation_with_guests(%L, '88888888', '1990-01-01', 'BO', 'La Paz', true) $$,
    (select res_id from casos where n = 2)
  ),
  'check-in del caso 2 no explota aunque la caja esté cerrada (el check-in y el cobro son llamados separados)'
);
select throws_ok(
  format(
    $$ select public.record_anticipo(%L, 100.00, 'EFECTIVO', 'Pago al check-in') $$,
    (select res_id from casos where n = 2)
  ),
  'P0001',
  'No hay una caja abierta',
  'con la caja cerrada, record_anticipo rechaza el pago con el mismo mensaje de siempre (sin excepción de rol)'
);
select is(
  (select status from public.reservations where id = (select res_id from casos where n = 2)),
  'checked_in',
  'CRÍTICO: el check-in NO se revierte cuando el pago posterior falla (decisión #5, no-atomicidad segura)'
);
select is(
  (select count(*)::int from public.anticipos
     where reservation_id = (select res_id from casos where n = 2) and amount_bs = 100.00),
  0,
  'no queda ningún anticipo huérfano cuando el pago fue rechazado'
);

-- ---------- 3) DESCUBRIMIENTO: record_anticipo NO tiene la excepción de
--    payment_records_income() que sí tiene check_out_room. Llama a
--    add_cash_movement para CUALQUIER método no-MIXTO (ver
--    20260806010000_mixed_payment_split.sql líneas 260-267), y
--    add_cash_movement exige turno abierto sin importar el método (ver
--    20260805010000_payment_proof_qr_card.sql líneas 92-95). O sea: para
--    anticipos (y por lo tanto para el pago al check-in), CORTESIA
--    también requiere caja abierta — a diferencia de check_out_room.
--    Esto contradice el dato "verificado" del brief de apply (R2.9); se
--    documenta acá como comportamiento REAL observado, no se toca
--    record_anticipo (fuera de alcance de este cambio). Reportado como
--    riesgo/desviación en el resultado de esta fase.
select throws_ok(
  format(
    $$ select public.record_anticipo(%L, 50.00, 'CORTESIA', 'Cortesía al check-in') $$,
    (select res_id from casos where n = 2)
  ),
  'P0001',
  'No hay una caja abierta',
  'CORTESIA también exige caja abierta en record_anticipo (a diferencia de check_out_room) — comportamiento real, no R2.9 como estaba escrito'
);

select * from finish();
rollback;
