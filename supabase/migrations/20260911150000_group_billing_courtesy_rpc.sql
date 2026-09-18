-- =====================================================================
-- mark_reservation_courtesy: nuevo RPC para marcar una reserva each_stay
-- como cortesía (change: group-billing, stage 6, Slice 7, branch
-- feat/booking-18-courtesy-rpc). Spec R7.1-R7.4.
--
-- No toca ninguna vista v_* de analítica: todas leen historical_stays,
-- no reservations en vivo (confirmado, R7.3).
-- =====================================================================

create or replace function public.mark_reservation_courtesy(p_reservation_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_payer_mode text;
  v_prev numeric(10,2);
  v_nights int;
begin
  if public.current_user_role() not in ('root', 'reception_admin') then
    raise exception 'No autorizado para marcar cortesía';
  end if;
  if p_reason is null or char_length(trim(p_reason)) = 0 then
    raise exception 'El motivo es obligatorio para marcar cortesía';
  end if;

  select b.payer_mode into v_payer_mode
  from public.reservations r join public.bookings b on b.id = r.booking_id
  where r.id = p_reservation_id;
  if v_payer_mode is null then
    raise exception 'Reserva no encontrada';
  end if;
  if v_payer_mode = 'client' then
    raise exception 'La cortesía de una reserva institucional se define al crear el grupo, no después';
  end if;

  select greatest(check_out_date - check_in_date, 1) into v_nights
  from public.reservations where id = p_reservation_id;
  select total_amount_bs / v_nights into v_prev
  from public.reservations where id = p_reservation_id;

  update public.reservations
    set is_courtesy = true, courtesy_reason = trim(p_reason), total_amount_bs = 0
    where id = p_reservation_id;

  insert into public.rate_overrides (reservation_id, previous_rate_bs, new_rate_bs, reason, changed_by)
  values (p_reservation_id, v_prev, 0, p_reason, auth.uid());
end;
$$;

revoke execute on function public.mark_reservation_courtesy(uuid, text) from public, anon;
grant execute on function public.mark_reservation_courtesy(uuid, text) to authenticated;
