-- =====================================================================
-- DEPOSITO y TRANSFERENCIA unificados, y add_cash_movement validando
-- contra payment_records_income en vez del catálogo global.
--
-- Lo que estas pruebas cuidan no es la unificación en sí (un update de dos
-- filas), es que no vuelva a haber DOS listas de medios de caja. Por eso
-- el bloque grande es el de rechazos: hasta ahora lo único que impedía
-- registrar una CORTESIA como movimiento de caja era un filtro en el
-- desplegable de React, y un filtro de UI no es una regla de negocio.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(13);

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);

-- ---------- 1) La lista quedó en una sola, y es la correcta ----------
select ok(public.payment_records_income('DEPOSITO'),  'DEPOSITO es plata de caja');
select ok(public.payment_records_income('EFECTIVO'),  'EFECTIVO es plata de caja');
select ok(public.payment_records_income('QR'),        'QR es plata de caja');
select ok(public.payment_records_income('TARJETA'),   'TARJETA es plata de caja');
select ok(
  not public.payment_records_income('TRANSFERENCIA'),
  'TRANSFERENCIA ya no es un medio propio: se unificó en DEPOSITO'
);

-- ---------- 2) No quedaron filas apuntando al código retirado ----------
select is(
  (select count(*) from public.reservations   where payment_method = 'TRANSFERENCIA')
  + (select count(*) from public.cash_movements where payment_method = 'TRANSFERENCIA')
  + (select count(*) from public.anticipos      where payment_method = 'TRANSFERENCIA')
  + (select count(*) from public.event_payments where method         = 'TRANSFERENCIA'),
  0::bigint,
  'ninguna fila quedó con TRANSFERENCIA en las cuatro tablas que lo usaban'
);

-- ---------- 3) El código se desactiva, NO se borra ----------
-- Borrarlo rompería la FK de cualquier fila que se nos haya escapado y
-- borraría el rastro de que el código existió.
select is(
  (select is_active from public.payment_methods where code = 'TRANSFERENCIA'),
  false,
  'TRANSFERENCIA queda inactivo'
);
select isnt(
  (select code from public.payment_methods where code = 'TRANSFERENCIA'),
  null,
  'pero la fila sigue existiendo: la FK y el rastro histórico se preservan'
);

-- ---------- 4) add_cash_movement rechaza lo que no es plata de caja ----------
-- Estos tres entraban antes, porque la validación miraba el catálogo
-- global (10 códigos activos) en vez de los medios de caja.
select throws_ok(
  $$ select public.add_cash_movement('income', 'cobro_habitacion', 100, 'prueba', null, 'CORTESIA') $$,
  'Forma de pago inválida para caja: CORTESIA. En un movimiento de caja sólo entra plata de verdad (efectivo, QR, tarjeta o depósito)',
  'una cortesía no es plata: no puede ser un movimiento de caja'
);
select throws_ok(
  $$ select public.add_cash_movement('income', 'cobro_cuenta', 100, 'prueba', null, 'CTAS_POR_COBRAR') $$,
  'Forma de pago inválida para caja: CTAS_POR_COBRAR. En un movimiento de caja sólo entra plata de verdad (efectivo, QR, tarjeta o depósito)',
  'una cuenta por cobrar es deuda, no plata que entró'
);
select throws_ok(
  $$ select public.add_cash_movement('income', 'cobro_habitacion', 100, 'prueba', null, 'TRANSFERENCIA') $$,
  'Forma de pago inválida para caja: TRANSFERENCIA. En un movimiento de caja sólo entra plata de verdad (efectivo, QR, tarjeta o depósito)',
  'el código retirado tampoco entra por la RPC'
);

-- ---------- 5) Y sigue aceptando lo que sí corresponde ----------
select lives_ok(
  $$ select public.add_cash_movement('income', 'cobro_habitacion', 100, 'prueba depósito', null, 'DEPOSITO') $$,
  'DEPOSITO se registra sin problema'
);
select lives_ok(
  $$ select public.add_cash_movement('expense', 'compras', 50, 'prueba sin medio', null, null) $$,
  'el movimiento sin forma de pago sigue permitido (varios, ajustes, históricos)'
);

select * from finish();
rollback;
