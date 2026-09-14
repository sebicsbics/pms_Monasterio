-- =====================================================================
-- Contrato institucional: create_reservation soporta payer_mode,
-- rate_mode y cortesía al crear (change: group-billing, stage 6,
-- Slice 2a2, branch feat/booking-10-contract-single).
--
-- Cambia la aridad de create_reservation (13 -> 23 parámetros: 10
-- nuevos al final, todos con default = comportamiento actual) --
-- DROP + CREATE en la misma migración (R2.8), re-grant explícito (V-B),
-- porque un DROP borra los grants existentes.
--
-- NOTA (auto-contenido, no silencioso): el diseño (sdd/group-billing/
-- design, Slice 2a2) documenta "9 parámetros nuevos / aridad 22", pero
-- la propia definición SQL que cita lista 10 parámetros nuevos
-- (payer_mode, rate_mode, agreed_unit_price_bs, receivable_account_id,
-- new_account_name/kind/contact/notes, is_courtesy, courtesy_reason) --
-- aridad real 23. Se sigue la definición SQL literal (fuente de
-- verdad); el recuento "9/22" del resumen queda documentado acá como
-- discrepancia menor, no se reescribe el artefacto de diseño (la Slice
-- 2a2 ya está completada).
--
-- Orden dentro del body (instrucción explícita de esta ronda de apply,
-- posterior al review de booking-9): (a) validaciones existentes sin
-- tocar; (b) gate de rol para payer_mode='client' ANTES de llamar a
-- _resolve_receivable_account (SECURITY DEFINER, evade la RLS de
-- receivable_accounts por sí solo -- sdd/group-billing/booking-9-fixes
-- #367 punto 4); (c) validaciones de combos rate_mode/precio/cortesía;
-- (d) insert de bookings; (e) insert de reservations; (f) cambio de
-- tarifa en modo habitación (client -> _apply_rate_change_direct nunca
-- pending; each_stay -> apply_rate_change sin cambios); (g) al final,
-- UNA fila contract_agreed = suma de total_amount_bs de las reservas de
-- la booking (reservation_id NULL, misma forma que usará el alta grupal
-- de feat/booking-11, para no duplicar lógica entre ambos slices).
-- =====================================================================

drop function if exists public.create_reservation(
  uuid, uuid, text, text, text, text, date, date, integer, text, numeric, text, boolean
);

create or replace function public.create_reservation(
  p_room_id uuid, p_room_type_id uuid, p_first_name text, p_last_name text,
  p_phone text, p_email text, p_check_in date, p_check_out date,
  p_num_guests int, p_method text, p_rate_bs numeric default null,
  p_reason text default null, p_contact_stays boolean default true,
  p_payer_mode text default 'each_stay', p_rate_mode text default 'room',
  p_agreed_unit_price_bs numeric default null, p_receivable_account_id uuid default null,
  p_new_account_name text default null, p_new_account_kind text default null,
  p_new_account_contact text default null, p_new_account_notes text default null,
  p_is_courtesy boolean default false, p_courtesy_reason text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_person_id uuid; v_booking_id uuid; v_guest_id uuid; v_reservation_id uuid;
  v_rate numeric(10,2); v_max_occ int; v_nights int;
  v_account_id uuid; v_final_total numeric(10,2);
begin
  -- (a) Validaciones existentes, SIN CAMBIOS.
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado para crear reservas';
  end if;
  if p_check_out <= p_check_in then
    raise exception 'La fecha de salida debe ser posterior a la de entrada';
  end if;
  if p_num_guests < 1 then
    raise exception 'Debe haber al menos 1 persona';
  end if;
  if nullif(trim(p_phone), '') is null and nullif(trim(p_email), '') is null then
    raise exception 'Se requiere al menos un contacto (celular o correo)';
  end if;

  select rt.base_price_bs, rt.max_occupancy into v_rate, v_max_occ
  from public.room_type_options o
  join public.room_types rt on rt.id = o.room_type_id
  where o.room_id = p_room_id and o.room_type_id = p_room_type_id;

  if v_rate is null then
    raise exception 'El tipo seleccionado no corresponde a esta habitación';
  end if;
  if v_max_occ < p_num_guests then
    raise exception 'El tipo elegido admite hasta % personas', v_max_occ;
  end if;

  perform 1 from public.rooms where id = p_room_id for update;
  if exists (
    select 1 from public.reservations r
    where r.room_id = p_room_id
      and r.status in ('confirmed', 'checked_in')
      and r.check_in_date < p_check_out
      and p_check_in < r.check_out_date
  ) then
    raise exception 'La habitación ya no está disponible para esas fechas';
  end if;

  -- (b) payer_mode + gate de rol para 'client', ANTES de tocar
  -- receivable_accounts (_resolve_receivable_account es SECURITY
  -- DEFINER y evade su RLS por su cuenta).
  if p_payer_mode not in ('client', 'each_stay') then
    raise exception 'Modalidad de pago inválida: %', p_payer_mode;
  end if;
  if p_payer_mode = 'client' and public.current_user_role() not in ('root', 'reception_admin') then
    raise exception 'Solo un administrador de recepción puede crear una reserva institucional';
  end if;

  -- (c) Combos rate_mode / precio / cortesía.
  if p_payer_mode = 'client' and p_rate_mode not in ('room', 'person') then
    raise exception 'Modalidad de tarifa inválida: %', p_rate_mode;
  end if;
  if p_rate_mode = 'person' and p_payer_mode <> 'client' then
    raise exception 'La tarifa por persona sólo aplica a reservas institucionales';
  end if;
  if p_rate_mode = 'person' and coalesce(p_agreed_unit_price_bs, 0) <= 0 then
    raise exception 'Debe indicar un precio pactado por persona positivo';
  end if;
  if p_is_courtesy and p_payer_mode <> 'client' then
    raise exception 'La cortesía al crear sólo aplica a reservas institucionales';
  end if;
  if p_is_courtesy and nullif(trim(p_courtesy_reason), '') is null then
    raise exception 'La cortesía requiere un motivo';
  end if;

  v_account_id := null;
  if p_payer_mode = 'client' then
    v_account_id := public._resolve_receivable_account(
      p_receivable_account_id, p_new_account_name, p_new_account_kind,
      p_new_account_contact, p_new_account_notes
    );
  end if;

  if nullif(p_email, '') is not null then
    select id into v_person_id from public.people where email = p_email;
  end if;
  if v_person_id is not null then
    update public.people set first_name = p_first_name, last_name = p_last_name,
      phone = coalesce(nullif(p_phone, ''), phone)
    where id = v_person_id;
  else
    insert into public.people (first_name, last_name, email, phone)
    values (p_first_name, p_last_name, nullif(p_email, ''), nullif(p_phone, ''))
    returning id into v_person_id;
  end if;

  -- (d) Insert de bookings con los campos de contrato. agreed_unit_price_bs
  -- se manda NULL fuera de rate_mode='person' -- la CHECK
  -- bookings_room_rate_has_no_unit_price ya lo exige; esto evita
  -- depender sólo de ese error genérico si el caller manda un precio
  -- "sobrante" en modo habitación.
  insert into public.bookings (
    contact_person_id, payer_mode, rate_mode, agreed_unit_price_bs, receivable_account_id
  ) values (
    v_person_id, p_payer_mode, p_rate_mode,
    case when p_rate_mode = 'person' then p_agreed_unit_price_bs else null end,
    v_account_id
  ) returning id into v_booking_id;

  if p_contact_stays then
    insert into public.guests (person_id) values (v_person_id)
      on conflict (person_id) do nothing;
    v_guest_id := v_person_id;
  else
    v_guest_id := null;
  end if;

  v_nights := p_check_out - p_check_in;

  -- (e) Insert de reservations: total 0 si cortesía, precio x personas x
  -- noches en modo persona, tarifa x noches en modo habitación (igual
  -- que antes).
  insert into public.reservations (
    guest_id, room_id, room_type_id, check_in_date, check_out_date,
    reservation_method, payment_status, total_amount_bs, status, num_guests,
    booking_id, is_courtesy, courtesy_reason
  ) values (
    v_guest_id, p_room_id, p_room_type_id, p_check_in, p_check_out,
    p_method, 'pending',
    case
      when p_is_courtesy then 0
      when p_payer_mode = 'client' and p_rate_mode = 'person' then p_agreed_unit_price_bs * p_num_guests * v_nights
      else v_rate * v_nights
    end,
    'confirmed', p_num_guests, v_booking_id, p_is_courtesy, p_courtesy_reason
  ) returning id into v_reservation_id;

  -- Titular explícito, precargado (confirmed_at NULL: recién se confirma
  -- en el check-in). SIN CAMBIOS.
  if v_guest_id is not null then
    insert into public.reservation_guests (reservation_id, person_id, role, confirmed_at)
    values (v_reservation_id, v_guest_id, 'holder', null);
  end if;

  -- (f) Cambio de tarifa en modo habitación: SIN CAMBIOS para each_stay
  -- (misma llamada a apply_rate_change de siempre); en modo persona no
  -- aplica (el precio ya es el pactado). Para client+room con tarifa
  -- distinta a la de lista, se aplica DIRECTO y se audita -- nunca
  -- genera una rate_discount_requests pendiente (decisión #339: sólo
  -- root/reception_admin llegan hasta acá).
  if p_rate_mode <> 'person' and p_rate_bs is not null and p_rate_bs <> v_rate then
    if p_reason is null or char_length(trim(p_reason)) = 0 then
      raise exception 'La justificación es obligatoria para cambiar la tarifa';
    end if;
    if p_rate_bs <= 0 then
      raise exception 'La tarifa debe ser un monto positivo';
    end if;
    if p_payer_mode = 'client' then
      perform public._apply_rate_change_direct(
        v_reservation_id, p_room_type_id, v_rate, v_nights, p_rate_bs, p_reason
      );
    else
      perform public.apply_rate_change(
        v_reservation_id, p_room_type_id, v_rate, v_nights, p_rate_bs, p_reason
      );
    end if;
  end if;

  -- (g) ÚLTIMO: contract_agreed = suma de total_amount_bs final de las
  -- reservas de la booking (hoy sólo hay una, pero se usa la misma forma
  -- "suma sobre booking_id, reservation_id NULL" que el alta grupal, para
  -- no duplicar lógica entre feat/booking-10 y feat/booking-11).
  if p_payer_mode = 'client' then
    select coalesce(sum(total_amount_bs), 0) into v_final_total
    from public.reservations where booking_id = v_booking_id;
    insert into public.booking_balances (booking_id, event_type, amount_bs, notes)
    values (v_booking_id, 'contract_agreed', v_final_total, 'Contrato al crear la reserva');
  end if;

  return v_reservation_id;
end;
$$;

revoke execute on function public.create_reservation(
  uuid, uuid, text, text, text, text, date, date, integer, text, numeric, text, boolean,
  text, text, numeric, uuid, text, text, text, text, boolean, text
) from public, anon;
grant execute on function public.create_reservation(
  uuid, uuid, text, text, text, text, date, date, integer, text, numeric, text, boolean,
  text, text, numeric, uuid, text, text, text, text, boolean, text
) to authenticated;
