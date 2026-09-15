-- =====================================================================
-- Adelanto institucional: record_booking_advance (change: group-billing,
-- stage 6, Slice 4, branch feat/booking-14-advance-rpc).
--
-- Toda la plata que un booking 'client' recibe ANTES del cierre del
-- grupo (Slice 5, todavía no existe) pasa por acá como evento
-- 'advance_received' en booking_balances (Slice 1) -- nunca anticipos,
-- que sigue siendo exclusivo de each_stay (spec R1.3/R4.1, Global
-- Facts). Usable tanto para un pago de la institución como para el de
-- cualquier huésped que abone contra el paquete.
--
-- El despacho de caja (efectivo/QR/tarjeta/depósito/mixto) es un calco
-- del de record_anticipo (pg_get_functiondef verificado en vivo antes
-- de escribir esta migración, ver notas de apply-progress): mismo orden
-- MIXTO -> record_mixed_income / resto -> assert_payment_proof +
-- add_cash_movement. add_cash_movement ya exige caja abierta
-- ('No hay una caja abierta') y ya valida la forma de pago vía
-- payment_records_income(); no se agregó ninguna validación nueva de
-- "forma de pago activa" que record_anticipo tampoco tiene.
--
-- assert_payment_proof (vivo) sólo exige comprobante para QR (foto) y
-- TARJETA (referencia) -- DEPOSITO no exige nada, igual que en
-- record_anticipo y record_mixed_income.
--
-- Guards, en este orden (todos NULL-safe, ver
-- postgres/check-constraint-null-trap): rol -> monto -> forma de pago
-- (no nula, no CTAS_POR_COBRAR: un adelanto es plata YA recibida) ->
-- booking existe (con FOR UPDATE, para serializar con el futuro
-- trigger de cierre de grupo de feat/booking-15, que actualiza
-- reservations.status y podría correr en paralelo) -> payer_mode
-- 'client' -> el booking tiene contrato (contract_agreed: invariante
-- que debería ser imposible de romper desde la UI, pero se defiende
-- igual) -> el booking no está cerrado (group_closed). Recién ahí se
-- despacha la caja y se inserta el evento.
--
-- Devuelve el id del MOVIMIENTO DE CAJA (no el de la fila de
-- booking_balances): en pagos simples es el único movimiento; en MIXTO
-- es el de la pata EFECTIVO, que es lo que record_mixed_income ya
-- define como "el que afecta el cajón y el que hay que poder rastrear
-- desde el arqueo".
--
-- Sobrepago (adelanto mayor al saldo pendiente): permitido por diseño.
-- net_owed_bs puede quedar negativo; queda registrado para auditoría,
-- no se bloquea (spec no lo prohíbe, design tampoco). Pregunta de
-- negocio abierta para el orquestador: si alguna vez conviene
-- advertir/bloquear esto desde la UI (Slice 11) -- este RPC no lo hace.
-- =====================================================================

create or replace function public.record_booking_advance(
  p_booking_id uuid,
  p_amount_bs numeric,
  p_payment_method text,
  p_receipt_path text default null,
  p_payment_reference text default null,
  p_cash_bs numeric default null,
  p_non_cash_bs numeric default null,
  p_non_cash_method text default null,
  p_notes text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings;
  v_mov     public.cash_movements;
  v_mov_id  uuid;
  v_ref     text := nullif(trim(p_payment_reference), '');
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado para registrar adelantos';
  end if;

  if coalesce(p_amount_bs, 0) <= 0 then
    raise exception 'El monto debe ser positivo';
  end if;

  if p_payment_method is null then
    raise exception 'Debe indicar una forma de pago';
  end if;
  if p_payment_method = 'CTAS_POR_COBRAR' then
    raise exception 'Un adelanto es plata ya recibida; no puede quedar como cuenta por cobrar';
  end if;

  select * into v_booking from public.bookings where id = p_booking_id for update;
  if not found then
    raise exception 'Reserva de grupo no encontrada';
  end if;
  if v_booking.payer_mode <> 'client' then
    raise exception 'Solo las reservas institucionales reciben adelantos de grupo';
  end if;

  if not exists (
    select 1 from public.booking_balances
    where booking_id = p_booking_id and event_type = 'contract_agreed'
  ) then
    raise exception 'La reserva de grupo todavía no tiene un contrato registrado';
  end if;

  if exists (
    select 1 from public.booking_balances
    where booking_id = p_booking_id and event_type = 'group_closed'
  ) then
    raise exception 'Esta reserva de grupo ya está cerrada';
  end if;

  if p_payment_method = 'MIXTO' then
    v_mov_id := public.record_mixed_income(
      p_amount_bs, p_cash_bs, p_non_cash_bs, p_non_cash_method,
      'adelanto_grupo', 'Adelanto reserva de grupo ' || p_booking_id,
      p_receipt_path, v_ref
    );
  else
    perform public.assert_payment_proof(p_payment_method, v_ref, p_receipt_path);
    v_mov := public.add_cash_movement(
      'income', 'adelanto_grupo', p_amount_bs,
      'Adelanto reserva de grupo ' || p_booking_id, p_receipt_path, p_payment_method, v_ref
    );
    v_mov_id := v_mov.id;
  end if;

  insert into public.booking_balances (
    booking_id, event_type, amount_bs, payment_method, cash_movement_id, notes
  ) values (
    p_booking_id, 'advance_received', p_amount_bs, p_payment_method, v_mov_id, p_notes
  );

  return v_mov_id;
end;
$$;

revoke execute on function public.record_booking_advance(
  uuid, numeric, text, text, text, numeric, numeric, text, text
) from public, anon;
grant execute on function public.record_booking_advance(
  uuid, numeric, text, text, text, numeric, numeric, text, text
) to authenticated;
