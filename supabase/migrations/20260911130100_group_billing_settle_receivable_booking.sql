-- =====================================================================
-- settle_receivable: reconocer cuentas por cobrar a nivel de booking
-- (change: group-billing, stage 6, Slice 5b, branch
-- feat/booking-16-settle-receivable-booking).
--
-- V-A (verificado contra la definición LIVE con pg_get_functiondef antes
-- de escribir esta migración): el tail histórico de esta función solo
-- actualiza reservations.payment_status vía v_row.reservation_id. Desde
-- feat/booking-15-close-trigger, _close_booking_group() puede insertar
-- una cuenta por cobrar con reservation_id NULL y booking_id seteado
-- (cuenta de GRUPO) -- para esas filas, el tail viejo era un no-op
-- silencioso: la cuenta quedaba 'paid' pero ninguna reserva del grupo
-- reflejaba el cobro.
--
-- Cuerpo idéntico al vigente desde 20260806010000_mixed_payment_split.sql
-- (mismo guard de rol, misma validación de método, mismo lock de fila,
-- mismo dispatch MIXTO/simple) -- solo cambia el tail final. Firma, tipo
-- de retorno y grants NO cambian (create or replace body-only).
--
-- Decisión sobre reservas CANCELADAS del booking (evidencia, no
-- supuesto): cancel_reservation() nunca toca reservations.payment_status
-- (verificado en su cuerpo LIVE) -- una reserva cancelada de un booking
-- 'client' queda con el default 'pending' para siempre si nadie la
-- marca. El CHECK reservations_payment_status_check solo exige
-- payment_status IN ('pending','paid','failed'), sin relación con la
-- columna status -- no hay restricción que impida marcarla 'paid'. No
-- existe ninguna vista SQL (`pg_views`) ni código TS (`grep -rn
-- payment_status src/`) que lea payment_status hoy, así que no hay
-- riesgo de que un reporte interprete "cancelada + paid" como un
-- reembolso. El booking le debe el contrato completo de esa habitación
-- (spec R5.2, ya reflejado en el monto del group_closed/receivable) --
-- una vez saldada la cuenta del grupo, es consistente marcar TODAS sus
-- reservas 'paid', cancelada o no. Por eso el nuevo branch actualiza por
-- booking_id sin filtrar por status, tal como lo especifica el diseño.
--
-- cancel_receivable() (verificado también) nunca toca reservations --
-- no necesita cambios; se agrega una prueba de regresión en 26_*.
-- =====================================================================

create or replace function public.settle_receivable(
  p_id uuid, p_method text, p_receipt_path text default null, p_payment_reference text default null,
  p_cash_bs numeric default null, p_non_cash_bs numeric default null, p_non_cash_method text default null
) returns public.receivables
language plpgsql security definer set search_path = public as $$
declare
  v_row      public.receivables;
  v_movement public.cash_movements;
  v_mov_id   uuid;
  v_ref      text := nullif(trim(p_payment_reference), '');
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado';
  end if;
  if not exists (select 1 from public.payment_methods where code = p_method and is_active) then
    raise exception 'Forma de pago inválida: %', p_method;
  end if;

  select * into v_row from public.receivables where id = p_id for update;
  if not found then
    raise exception 'Cuenta por cobrar no encontrada';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'La deuda ya no está pendiente (estado: %)', v_row.status;
  end if;

  if p_method = 'MIXTO' then
    v_mov_id := public.record_mixed_income(
      v_row.amount_bs, p_cash_bs, p_non_cash_bs, p_non_cash_method,
      'cobro_cuenta', 'Cobro cuenta por cobrar', p_receipt_path, v_ref
    );
  else
    perform public.assert_payment_proof(p_method, v_ref, p_receipt_path);
    if public.payment_records_income(p_method) then
      v_movement := public.add_cash_movement(
        'income', 'cobro_cuenta', v_row.amount_bs,
        'Cobro cuenta por cobrar', p_receipt_path, p_method, v_ref
      );
      v_mov_id := v_movement.id;
    end if;
  end if;

  update public.receivables
    set status = 'paid', settled_by = auth.uid(), settled_at = now(),
        settle_method = p_method, cash_movement_id = v_mov_id,
        settle_receipt_path = p_receipt_path, settle_payment_reference = v_ref
    where id = p_id
    returning * into v_row;

  -- NEW: cuentas de grupo tienen reservation_id NULL y booking_id
  -- seteado (feat/booking-15). El tail anterior solo cubría el caso
  -- reservation_id -- ahora se bifurca: booking_id marca TODAS las
  -- reservas del grupo (cancelada o no, ver análisis arriba); el camino
  -- reservation_id (each_stay) queda intacto, sin cambios de
  -- comportamiento.
  if v_row.booking_id is not null then
    update public.reservations set payment_status = 'paid' where booking_id = v_row.booking_id;
  elsif v_row.reservation_id is not null then
    update public.reservations set payment_status = 'paid' where id = v_row.reservation_id;
  end if;

  return v_row;
end;
$$;
-- Grants sin cambios (misma firma, mismos grants que 20260806010000).
