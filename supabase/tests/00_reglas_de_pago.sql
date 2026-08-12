-- =====================================================================
-- Reglas de pago: respaldo obligatorio, qué medios entran a caja y el
-- desglose del pago mixto.
--
-- pgTAP se instala DENTRO de la transacción del test y se revierte con
-- ella: así la extensión no llega nunca al proyecto de la nube. Las
-- pruebas no dejan rastro — todo el archivo corre en un begin/rollback.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(18);

-- ---------- assert_payment_proof: la regla compartida ----------
select lives_ok(
  $$ select public.assert_payment_proof('EFECTIVO', null, null) $$,
  'efectivo no pide respaldo'
);
select lives_ok(
  $$ select public.assert_payment_proof('DEPOSITO', null, null) $$,
  'depósito no pide respaldo'
);
select throws_ok(
  $$ select public.assert_payment_proof('QR', null, null) $$,
  'P0001',
  'La foto del comprobante es obligatoria para pagos por QR',
  'QR sin foto se rechaza'
);
select lives_ok(
  $$ select public.assert_payment_proof('QR', null, '2026/foto.jpg') $$,
  'QR con foto pasa'
);
select throws_ok(
  $$ select public.assert_payment_proof('TARJETA', null, null) $$,
  'P0001',
  'El código de referencia es obligatorio para pagos con tarjeta',
  'tarjeta sin referencia se rechaza'
);
select throws_ok(
  $$ select public.assert_payment_proof('TARJETA', '   ', null) $$,
  'P0001',
  'El código de referencia es obligatorio para pagos con tarjeta',
  'una referencia en blanco no cuenta como referencia'
);
select lives_ok(
  $$ select public.assert_payment_proof('TARJETA', 'AB12345', null) $$,
  'tarjeta con referencia pasa'
);

-- ---------- payment_records_income: qué medios llegan a la caja ----------
select ok(public.payment_records_income('EFECTIVO'),      'efectivo entra a caja');
select ok(public.payment_records_income('QR'),            'QR entra a caja');
select ok(public.payment_records_income('TARJETA'),       'tarjeta entra a caja');
select ok(public.payment_records_income('DEPOSITO'),      'depósito entra a caja');
-- Deuda: la plata todavía no entró.
select ok(not public.payment_records_income('CTAS_POR_COBRAR'),
          'cuentas por cobrar NO entra a caja: es deuda, no cobro');
-- Sin flujo de dinero.
select ok(not public.payment_records_income('CORTESIA'),   'cortesía NO entra a caja');
select ok(not public.payment_records_income('INTERCAMBIO'),'intercambio NO entra a caja');
-- No se puede atribuir a un medio sin inventar el dato.
select ok(not public.payment_records_income('OTRO'),       'OTRO NO entra a caja');
-- MIXTO se maneja aparte: genera DOS movimientos, no uno.
select ok(not public.payment_records_income('MIXTO'),
          'MIXTO NO entra como un movimiento único');

-- ---------- record_mixed_income: el desglose tiene que cuadrar ----------
-- Se actúa como la recepcionista del seed, que tiene la caja abierta.
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);

select throws_ok(
  $$ select public.record_mixed_income(450, 300, 100, 'QR', 'adelanto', 'test', '2026/q.jpg', null) $$,
  'P0001',
  null,
  'un desglose que no suma el total se rechaza'
);
select throws_ok(
  $$ select public.record_mixed_income(450, 450, 0, 'QR', 'adelanto', 'test', '2026/q.jpg', null) $$,
  'P0001',
  null,
  'una mitad en cero es un pago simple, no mixto'
);

select * from finish();
rollback;
