-- =====================================================================
-- Bloqueo de cambio de tarifa para reservas institucionales con
-- contrato ya congelado (change: group-billing, stage 6, Slice 3,
-- branch feat/booking-13-rate-lock).
--
-- Body-only, mismas firmas desde 20260722020000, sin DROP:
-- 1) apply_rate_change: primer chequeo nuevo -- si la booking de la
--    reserva ya tiene un evento contract_agreed, rechaza (contrato
--    congelado, cancelá y volvé a reservar). El resto de la lógica de
--    decisión (v_pct <= 20 or v_role = 'reception_admin') queda
--    IDÉNTICA, pero la rama "aplica directo" ahora delega en
--    _apply_rate_change_direct (Slice 2a) en vez de duplicar su
--    cuerpo inline -- los valores de retorno son iguales en cada rama.
-- 2) approve_rate_discount_request: mismo candado, resuelto a través
--    de la reserva de la solicitud. Defensa en profundidad -- para
--    bookings 'client' debería ser inalcanzable, ya que create_
--    reservation/create_bulk_reservation nunca dejan una solicitud
--    pendiente para ellas (decisión #339).
-- =====================================================================

create or replace function public.apply_rate_change(
  p_reservation_id uuid, p_room_type_id uuid, p_base_price_bs numeric,
  p_nights int, p_new_price_per_night numeric, p_reason text
) returns table(applied boolean, discount_pct numeric, request_id uuid)
language plpgsql security definer set search_path = public as $$
declare
  v_pct  numeric(5,2);
  v_role text;
  v_request uuid;
begin
  -- Candado de Slice 3: la booking de esta reserva ya tiene un
  -- contract_agreed -> el contrato está congelado, un cambio real
  -- requiere cancelar y volver a reservar (no hay UPDATE/DELETE sobre
  -- booking_balances, ver Slice 1).
  if exists (
    select 1 from public.reservations r
    join public.booking_balances bb on bb.booking_id = r.booking_id and bb.event_type = 'contract_agreed'
    where r.id = p_reservation_id
  ) then
    raise exception 'No se puede cambiar la tarifa de una reserva institucional; cancelá y volvé a reservar';
  end if;

  -- Resto EXACTAMENTE igual a 20260722020000: el bypass >20% de
  -- reception_admin sigue igual para CUALQUIER reserva (each_stay
  -- incluida) -- root no se agrega acá (el bypass de root para altas
  -- 'client' se resuelve en la creación del grupo vía
  -- _apply_rate_change_direct, Slice 2a2/2b), solo que ahora la rama
  -- "aplica directo" delega en el helper compartido en vez de
  -- duplicar su cuerpo.
  v_pct  := public.discount_pct(p_base_price_bs, p_new_price_per_night);
  v_role := public.current_user_role();

  if v_pct <= 20 or v_role = 'reception_admin' then
    return query select * from public._apply_rate_change_direct(
      p_reservation_id, p_room_type_id, p_base_price_bs, p_nights, p_new_price_per_night, p_reason
    );
  else
    insert into public.rate_discount_requests (
      reservation_id, room_type_id, base_price_bs, requested_price_bs,
      computed_discount_pct, reason, requested_by, status
    ) values (
      p_reservation_id, p_room_type_id, p_base_price_bs, p_new_price_per_night,
      v_pct, p_reason, auth.uid(), 'pending'
    ) returning id into v_request;
    return query select false, v_pct, v_request;
  end if;
end; $$;
-- Grants sin cambios (misma firma desde 20260722020000).

create or replace function public.approve_rate_discount_request(p_request_id uuid)
returns public.reservations
language plpgsql security definer set search_path = public as $$
declare
  v_req    public.rate_discount_requests;
  v_nights int;
  v_prev   numeric(10,2);
  v_row    public.reservations;
begin
  if public.current_user_role() not in ('root', 'reception_admin') then
    raise exception 'No autorizado para aprobar descuentos';
  end if;

  select * into v_req
  from public.rate_discount_requests
  where id = p_request_id and status = 'pending'
  for update;

  if not found then
    raise exception 'Solicitud no encontrada o ya resuelta';
  end if;

  -- Candado de Slice 3 (defensa en profundidad): para bookings
  -- 'client' debería ser INALCANZABLE, ya que Slice 2a2/2b nunca dejan
  -- una solicitud pendiente para ellas -- se mantiene como segunda
  -- línea de defensa por si algún dato llega a existir igual.
  if exists (
    select 1 from public.reservations r
    join public.booking_balances bb on bb.booking_id = r.booking_id and bb.event_type = 'contract_agreed'
    where r.id = v_req.reservation_id
  ) then
    raise exception 'No se puede cambiar la tarifa de una reserva institucional; cancelá y volvé a reservar';
  end if;

  select greatest(check_out_date - check_in_date, 1), total_amount_bs / greatest(check_out_date - check_in_date, 1)
    into v_nights, v_prev
  from public.reservations
  where id = v_req.reservation_id;

  update public.reservations
    set total_amount_bs = v_req.requested_price_bs * v_nights
    where id = v_req.reservation_id
    returning * into v_row;

  insert into public.rate_overrides (
    reservation_id, previous_rate_bs, new_rate_bs, reason, changed_by
  ) values (
    v_req.reservation_id, v_prev, v_req.requested_price_bs, v_req.reason, auth.uid()
  );

  update public.rate_discount_requests
    set status = 'approved', resolved_by = auth.uid(), resolved_at = now(), applied_at = now()
    where id = p_request_id;

  return v_row;
end; $$;
-- Grants sin cambios (misma firma desde 20260722020000).
