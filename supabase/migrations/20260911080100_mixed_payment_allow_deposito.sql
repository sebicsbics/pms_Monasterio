-- =====================================================================
-- Pago mixto: la parte electrónica también puede ser DEPOSITO.
-- (fix: mixed-payment-deposito)
--
-- El hotel también cobra por depósito bancario, pero record_mixed_income
-- sólo aceptaba QR o TARJETA para la mitad no-efectivo — el desplegable de
-- "Pago mixto" en check-out nunca ofrecía depósito porque la RPC lo
-- hubiera rechazado igual. DEPOSITO ya es un medio activo y válido para
-- pagos simples (payment_records_income lo incluye desde 20260829000000);
-- esto sólo extiende la misma validación al caso mixto.
--
-- DEPOSITO no exige comprobante ni referencia (assert_payment_proof sólo
-- pide foto para QR y código para TARJETA), así que no hace falta tocar
-- esa regla: el pago mixto reutiliza la de siempre.
--
-- Cuerpo idéntico al vigente (20260806010000_mixed_payment_split), sólo
-- cambia la lista de medios aceptados y el mensaje del error.
-- =====================================================================

create or replace function public.record_mixed_income(
  p_total             numeric,
  p_cash_bs           numeric,
  p_non_cash_bs       numeric,
  p_non_cash_method   text,
  p_category          text,
  p_concept           text,
  p_receipt_path      text default null,
  p_payment_reference text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cash_mov public.cash_movements;
  v_cash_id  uuid;
begin
  if p_non_cash_method not in ('QR', 'TARJETA', 'DEPOSITO') then
    raise exception 'La parte no-efectivo debe ser QR, TARJETA o DEPOSITO (recibido: %)',
      coalesce(p_non_cash_method, 'nada');
  end if;

  if coalesce(p_cash_bs, 0) < 0 or coalesce(p_non_cash_bs, 0) < 0 then
    raise exception 'Los montos del pago mixto no pueden ser negativos';
  end if;

  if coalesce(p_cash_bs, 0) = 0 or coalesce(p_non_cash_bs, 0) = 0 then
    raise exception 'Un pago mixto necesita monto en efectivo Y en %; si es uno solo, elegí ese medio',
      p_non_cash_method;
  end if;

  -- El desglose tiene que dar el total exacto. Tolerancia de 1 centavo por
  -- el redondeo de numeric(10,2), no por descuido.
  if abs((p_cash_bs + p_non_cash_bs) - p_total) > 0.01 then
    raise exception 'El desglose (% + % = %) no coincide con el total a cobrar (%)',
      p_cash_bs, p_non_cash_bs, p_cash_bs + p_non_cash_bs, p_total;
  end if;

  -- La parte electrónica exige su respaldo, igual que un pago simple.
  -- (DEPOSITO no pide nada; QR pide foto; TARJETA pide referencia.)
  perform public.assert_payment_proof(
    p_non_cash_method, p_payment_reference, p_receipt_path
  );

  v_cash_mov := public.add_cash_movement(
    'income', p_category, p_cash_bs,
    p_concept || ' (mixto: efectivo)', null, 'EFECTIVO', null
  );
  v_cash_id := v_cash_mov.id;

  perform public.add_cash_movement(
    'income', p_category, p_non_cash_bs,
    p_concept || ' (mixto: ' || lower(p_non_cash_method) || ')',
    p_receipt_path, p_non_cash_method, p_payment_reference
  );

  -- Devuelve el movimiento en EFECTIVO: es el que afecta el cajón y el
  -- que hay que poder rastrear desde el arqueo.
  return v_cash_id;
end;
$$;

revoke execute on function public.record_mixed_income(
  numeric, numeric, numeric, text, text, text, text, text
) from public, anon, authenticated;

comment on function public.record_mixed_income is
  'Registra un cobro mixto como DOS movimientos de caja (efectivo + '
  'QR/TARJETA/DEPOSITO). Valida que el desglose sume el total exacto. '
  'Devuelve el id del movimiento en efectivo. Sólo se llama desde otras RPC.';
