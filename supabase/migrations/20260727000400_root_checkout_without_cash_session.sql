-- =====================================================================
-- Check-out de root sin caja abierta (change: root-checkout-without-cash-session).
--
-- check_out_room, cuando el pago es EFECTIVO y hay total > 0, llama a
-- add_cash_movement, que exige una cash_session abierta. Esto bloquea las
-- pruebas de root cuando no hay caja chica abierta.
--
-- Relajación de MÍNIMO alcance: si quien hace el check-out es 'root' y NO
-- hay caja abierta, el check-out se completa SIN registrar el ingreso en
-- caja (no hay dónde registrarlo). Si hay caja abierta, root la alimenta
-- igual que siempre. Para reception/accountant la regla NO cambia: siguen
-- necesitando caja abierta para cobrar en efectivo.
--
-- Restatement completo (Postgres no permite parche parcial). Cuerpo
-- idéntico a 20260718000000_lock_down_reservations_folios.sql salvo la
-- condición del bloque de efectivo.
-- =====================================================================

create or replace function public.check_out_room(
  p_room_id uuid,
  p_payment_method text default 'EFECTIVO',
  p_receipt_path text default null,
  p_payment_reference text default null
)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reservation_id uuid;
  v_room_total     numeric(10,2);
  v_extras         numeric(10,2);
  v_total          numeric(10,2);
  v_status         varchar(15);
begin
  if public.current_user_role() not in ('root', 'reception', 'accountant') then
    raise exception 'No autorizado para hacer check-out';
  end if;

  if not exists (
    select 1 from public.payment_methods where code = p_payment_method and is_active
  ) then
    raise exception 'Forma de pago inválida: %', p_payment_method;
  end if;

  select operational_status into v_status
  from public.rooms where id = p_room_id for update;
  if v_status <> 'occupied' then
    raise exception 'La habitación no está ocupada (estado actual: %)', coalesce(v_status, 'inexistente');
  end if;

  select id, total_amount_bs into v_reservation_id, v_room_total
  from public.reservations
  where room_id = p_room_id and status = 'checked_in'
  order by check_in_date desc
  limit 1;

  if v_reservation_id is null then
    raise exception 'No hay una reserva activa para esta habitación';
  end if;

  select coalesce(sum(fc.amount_bs), 0) into v_extras
  from public.folio_charges fc
  join public.folios f on f.id = fc.folio_id
  where f.reservation_id = v_reservation_id;

  v_total := coalesce(v_room_total, 0) + v_extras;

  -- Registrar forma de pago, comprobante/referencia y marcar cobrada.
  update public.reservations
    set payment_method = p_payment_method,
        payment_status = 'paid',
        receipt_path = p_receipt_path,
        payment_reference = p_payment_reference
    where id = v_reservation_id;

  -- Efectivo -> alimenta la caja (requiere caja abierta; si no, revierte
  -- todo). EXCEPCIÓN: root sin caja abierta completa el check-out sin
  -- registrar el ingreso en caja (para pruebas). Con caja abierta, root la
  -- alimenta igual.
  if p_payment_method = 'EFECTIVO' and v_total > 0
     and (public.current_user_role() <> 'root'
          or exists (select 1 from public.cash_sessions where status = 'open')) then
    perform public.add_cash_movement(
      'income', 'cobro_habitacion', v_total,
      'Check-out habitación', null, p_payment_method
    );
  end if;

  update public.reservations set status = 'checked_out' where id = v_reservation_id;
  update public.folios set closed_at = now() where reservation_id = v_reservation_id;
  update public.rooms set operational_status = 'dirty' where id = p_room_id;

  return v_total;
end;
$$;

grant execute on function public.check_out_room(uuid, text, text, text) to authenticated;
