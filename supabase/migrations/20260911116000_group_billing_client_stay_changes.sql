-- =====================================================================
-- Cambios de estadía para reservas institucionales con contrato ya
-- congelado (change: group-billing, stage 6, Slice 3b, branch
-- feat/booking-13c-client-stay-changes).
--
-- Fecha de la migración elegida a propósito como 20260911116000 (NO
-- 20260911120000, que es la fecha planeada para
-- feat/booking-14-advance-rpc todavía sin aplicar) para no colisionar
-- con la cadena de branches locales pendientes -- ver
-- sdd/group-billing/decisions-round-5 y apply-progress.
--
-- Body-only, mismas firmas desde 20260807000000 (modify_stay_dates),
-- 20260722020000 (change_room), 20260722010000 (reschedule_reservation)
-- -- ver V-A en apply-progress para las 3 firmas exactas -- sin DROP,
-- grants sin cambios.
--
-- Regla (decisión de usuario, decisions-round-5):
--   - EXTENDER una reserva institucional con contract_agreed ya
--     insertado en booking_balances -> se rechaza (modify_stay_dates
--     con salida más tarde; reschedule_reservation que cambia la
--     cantidad de noches, sea para sumar o para restar). El mensaje
--     pide cancelar y crear una reserva nueva.
--   - ACORTAR (modify_stay_dates con salida más temprana), change_room,
--     y reschedule_reservation manteniendo la MISMA cantidad de noches
--     -> permitido. El contrato (booking_balances) nunca se toca.
--   - El total de la reserva (total_amount_bs) NO se recalcula a partir
--     de las noches/tarifa nuevas para estas operaciones permitidas: el
--     contrato ya fijó el monto al crearse. Ver el detalle de cada
--     función abajo.
--
-- FEASIBILITY GATE (apply-time, ver apply-progress): mantener
-- total_amount_bs sin cambios es COMPATIBLE con el invariante de
-- stay_segments para el caso de 1 solo tramo (el único alcanzable en
-- ACORTAR, porque EXTENDER -- la única operación que abriría un segundo
-- tramo -- ya está bloqueada arriba): el propio trigger
-- trg_sync_single_stay_segment/sync_single_stay_segment() reajusta
-- rate_bs del tramo único a total_amount_bs/noches_nuevas cada vez que
-- reservations cambia, así que sum(stay_segments) SIGUE coincidiendo
-- con total_amount_bs, sólo que a una tarifa por noche más alta (el
-- mismo monto repartido en menos noches).
--
-- Para change_room, que sí deja > 1 tramo, ese mismo trigger se
-- abstiene (su guard es "v_count > 1 -> return null, mandan las RPC"),
-- así que la suma de tramos puede NO calzar exactamente con
-- total_amount_bs para una reserva congelada que cambió de habitación.
-- Se documenta como deuda conocida en vez de inventar una regla de
-- reparto arbitraria entre el tramo viejo y el nuevo: ni un CHECK ni
-- ningún test existente exigen esa igualdad para reservas 'client', y
-- el dinero (folio, cobro de check-out) SIEMPRE lee total_amount_bs
-- directo (src/services/folio.ts:56), nunca la suma de tramos -- el
-- único efecto es que el desglose itemizado del folio (RoomPanel.tsx,
-- sólo cuando hay más de un tramo) podría no sumar exactamente el
-- "Total" mostrado para este caso específico. Se deja para cuando
-- llegue la UI dedicada de checkout institucional
-- (feat/booking-17-checkout-enforcement).
-- =====================================================================

create or replace function public.modify_stay_dates(
  p_room_id uuid, p_new_check_out date, p_rate_bs numeric DEFAULT NULL::numeric, p_reason text DEFAULT NULL::text
)
 returns numeric
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_res    public.reservations;
  v_last   public.stay_segments;
  v_frozen boolean;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado para modificar las fechas de la estadía';
  end if;

  select * into v_res
  from public.reservations
  where room_id = p_room_id and status = 'checked_in'
  order by check_in_date desc
  limit 1
  for update;

  if not found then
    raise exception 'No hay una estadía activa en esta habitación';
  end if;

  if p_new_check_out = v_res.check_out_date then
    raise exception 'La fecha de salida es la misma que la actual';
  end if;

  if p_new_check_out <= v_res.check_in_date then
    raise exception 'La salida debe ser posterior a la entrada (%)', v_res.check_in_date;
  end if;

  -- Candado group-billing Slice 3b: una reserva institucional con
  -- contrato ya congelado no puede sumar noches sin pasar por una
  -- reserva nueva. EXISTS es NULL-safe frente a booking_id nulo (mismo
  -- patrón que 20260911110000_group_billing_rate_lock.sql), aunque hoy
  -- reservations.booking_id es NOT NULL para toda la tabla.
  v_frozen := exists (
    select 1 from public.booking_balances bb
    where bb.booking_id = v_res.booking_id and bb.event_type = 'contract_agreed'
  );

  -- ---------------- EXTENDER ----------------
  if p_new_check_out > v_res.check_out_date then
    if v_frozen then
      raise exception 'Para extender una reserva institucional creá una reserva nueva';
    end if;

    if p_rate_bs is null or p_rate_bs < 0 then
      raise exception 'La tarifa de las noches nuevas es obligatoria';
    end if;

    if not public.room_is_free_between(
         p_room_id, v_res.check_out_date, p_new_check_out, v_res.id
       ) then
      raise exception 'La habitación ya está reservada por otro huésped en esas fechas';
    end if;

    select * into v_last
    from public.stay_segments
    where reservation_id = v_res.id
    order by end_date desc
    limit 1;

    -- Misma habitación y misma tarifa: se estira el tramo en vez de partir
    -- el folio en dos líneas idénticas.
    if v_last.id is not null
       and v_last.room_id = p_room_id
       and v_last.rate_bs = p_rate_bs then
      update public.stay_segments
        set end_date = p_new_check_out
        where id = v_last.id;
    else
      insert into public.stay_segments (
        reservation_id, room_id, room_type_id, rate_bs, start_date, end_date, reason
      ) values (
        v_res.id, p_room_id, coalesce(v_last.room_type_id, v_res.room_type_id), p_rate_bs,
        v_res.check_out_date, p_new_check_out,
        coalesce(nullif(trim(p_reason), ''), 'Extensión de estadía')
      );
    end if;

  -- ---------------- ACORTAR ----------------
  else
    if p_new_check_out < current_date then
      raise exception
        'No se pueden quitar noches ya dormidas: la nueva salida (%) es anterior a hoy',
        p_new_check_out;
    end if;

    -- Tramos que quedan enteros fuera de la estadía: desaparecen.
    delete from public.stay_segments
    where reservation_id = v_res.id and start_date >= p_new_check_out;

    -- El tramo que cruza la nueva salida se recorta.
    update public.stay_segments
      set end_date = p_new_check_out,
          reason = coalesce(reason, '') ||
                   case when coalesce(reason,'') = '' then '' else ' · ' end ||
                   coalesce(nullif(trim(p_reason), ''), 'Salida adelantada')
      where reservation_id = v_res.id and end_date > p_new_check_out;
  end if;

  -- Reservas institucionales congeladas: sólo se puede llegar acá por
  -- ACORTAR (EXTENDER ya rechazó arriba). El contrato ya fijó el total,
  -- así que acortar noches NO debe descontarlas -- se refrescan sólo
  -- check_in_date/check_out_date visibles (a partir de los tramos ya
  -- recortados, para disponibilidad/housekeeping); total_amount_bs
  -- queda intacto. Ver nota de FEASIBILITY GATE arriba sobre por qué
  -- sum(stay_segments) sigue coincidiendo con el total en este caso.
  if v_frozen then
    update public.reservations
      set check_in_date  = coalesce((select min(start_date) from public.stay_segments where reservation_id = v_res.id), v_res.check_in_date),
          check_out_date = coalesce((select max(end_date) from public.stay_segments where reservation_id = v_res.id), v_res.check_out_date)
      where id = v_res.id;
    return v_res.total_amount_bs;
  end if;

  return public.recalc_reservation_total(v_res.id);
end;
$function$;
-- Grants sin cambios (misma firma desde 20260807000000).

create or replace function public.change_room(
  p_room_id uuid, p_new_room_id uuid, p_new_room_type_id uuid, p_rate_bs numeric,
  p_from date DEFAULT NULL::date, p_reason text DEFAULT NULL::text
)
 returns numeric
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_res    public.reservations;
  v_last   public.stay_segments;
  v_from   date := coalesce(p_from, current_date);
  v_status text;
  v_frozen boolean;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado para cambiar de habitación';
  end if;

  if p_rate_bs is null or p_rate_bs < 0 then
    raise exception 'La tarifa de la habitación nueva es obligatoria';
  end if;

  if p_new_room_id = p_room_id then
    raise exception 'La habitación destino es la misma que la actual';
  end if;

  select * into v_res
  from public.reservations
  where room_id = p_room_id and status = 'checked_in'
  order by check_in_date desc
  limit 1
  for update;

  if not found then
    raise exception 'No hay una estadía activa en esta habitación';
  end if;

  -- Candado group-billing Slice 3b: change_room NO suma ni quita
  -- noches, sólo reasigna dónde duerme el huésped -- se permite incluso
  -- para una reserva institucional congelada, pero el total pactado NO
  -- se recalcula con la tarifa nueva (ver nota de FEASIBILITY GATE al
  -- principio de esta migración sobre la deuda documentada con la suma
  -- de tramos). EXISTS es NULL-safe frente a booking_id nulo.
  v_frozen := exists (
    select 1 from public.booking_balances bb
    where bb.booking_id = v_res.booking_id and bb.event_type = 'contract_agreed'
  );

  if v_from < v_res.check_in_date then v_from := v_res.check_in_date; end if;
  if v_from >= v_res.check_out_date then
    raise exception 'La fecha del cambio debe ser anterior a la salida (%)', v_res.check_out_date;
  end if;

  -- El tipo elegido tiene que ser vendible en la habitación destino.
  if not exists (
    select 1 from public.room_type_options
    where room_id = p_new_room_id and room_type_id = p_new_room_type_id
  ) then
    raise exception 'El tipo seleccionado no corresponde a la habitación destino';
  end if;

  -- Destino libre por las noches que faltan, y utilizable ahora.
  select operational_status into v_status
  from public.rooms where id = p_new_room_id for update;
  if v_status not in ('available', 'dirty') then
    raise exception 'La habitación destino no está disponible (estado: %)', coalesce(v_status, 'inexistente');
  end if;
  if not public.room_is_free_between(p_new_room_id, v_from, v_res.check_out_date, v_res.id) then
    raise exception 'La habitación destino ya está reservada en esas fechas';
  end if;

  select * into v_last
  from public.stay_segments
  where reservation_id = v_res.id
  order by end_date desc
  limit 1;

  if v_last.id is null then
    -- Reserva histórica sin tramos: se materializa el tramo original antes
    -- de partirlo, para no perder lo que ya se había cobrado.
    insert into public.stay_segments (
      reservation_id, room_id, room_type_id, rate_bs, start_date, end_date, reason
    ) values (
      v_res.id, p_room_id, v_res.room_type_id,
      round(v_res.total_amount_bs / greatest(v_res.check_out_date - v_res.check_in_date, 1), 2),
      v_res.check_in_date, v_res.check_out_date, 'Tramo inicial (materializado al mudar)'
    ) returning * into v_last;
  end if;

  if v_from <= v_last.start_date then
    -- Se muda antes de dormir una noche en la actual: el tramo no existió.
    delete from public.stay_segments where id = v_last.id;
    v_from := v_last.start_date;
  else
    update public.stay_segments set end_date = v_from where id = v_last.id;
  end if;

  insert into public.stay_segments (
    reservation_id, room_id, room_type_id, rate_bs, start_date, end_date, reason
  ) values (
    v_res.id, p_new_room_id, p_new_room_type_id, p_rate_bs,
    v_from, v_res.check_out_date,
    coalesce(nullif(trim(p_reason), ''), 'Cambio de habitación')
  );

  -- La reserva pasa a apuntar a la habitación nueva; la vieja queda sucia.
  update public.reservations
    set room_id = p_new_room_id, room_type_id = p_new_room_type_id
    where id = v_res.id;

  update public.rooms set operational_status = 'dirty'    where id = p_room_id;
  update public.rooms set operational_status = 'occupied' where id = p_new_room_id;

  if v_frozen then
    return v_res.total_amount_bs;
  end if;

  return public.recalc_reservation_total(v_res.id);
end;
$function$;
-- Grants sin cambios (misma firma desde 20260722020000).

create or replace function public.reschedule_reservation(
  p_reservation_id uuid, p_check_in date, p_check_out date, p_reason text
)
 returns reservations
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_status     varchar(20);
  v_room_id    uuid;
  v_booking_id uuid;
  v_prev_in    date;
  v_prev_out   date;
  v_old_nights int;
  v_new_nights int;
  v_per_night  numeric(10,2);
  v_row        public.reservations;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado para reprogramar reservas';
  end if;

  if p_reason is null or char_length(trim(p_reason)) = 0 then
    raise exception 'La justificación es obligatoria';
  end if;
  if p_check_out <= p_check_in then
    raise exception 'La fecha de salida debe ser posterior a la de entrada';
  end if;

  select status, room_id, booking_id, check_in_date, check_out_date
    into v_status, v_room_id, v_booking_id, v_prev_in, v_prev_out
  from public.reservations where id = p_reservation_id for update;

  if v_status is null then
    raise exception 'Reserva no encontrada';
  end if;
  if v_status <> 'confirmed' then
    raise exception 'Solo se pueden reprogramar reservas confirmadas (estado: %)', v_status;
  end if;

  v_old_nights := greatest(v_prev_out - v_prev_in, 1);
  v_new_nights := p_check_out - p_check_in;

  -- Candado group-billing Slice 3b: una reserva institucional con
  -- contrato ya congelado sólo puede moverse de fecha manteniendo la
  -- misma cantidad de noches (ni suma ni quita) -- para eso está
  -- cancelar y volver a reservar. EXISTS es NULL-safe frente a
  -- booking_id nulo.
  if v_new_nights <> v_old_nights and exists (
    select 1 from public.booking_balances bb
    where bb.booking_id = v_booking_id and bb.event_type = 'contract_agreed'
  ) then
    raise exception 'Una reserva institucional solo puede moverse de fecha manteniendo la cantidad de noches';
  end if;

  -- Bloqueo pesimista + revalidación de disponibilidad (anti-overbooking),
  -- excluyendo la propia reserva.
  perform 1 from public.rooms where id = v_room_id for update;
  if exists (
    select 1 from public.reservations r
    where r.room_id = v_room_id
      and r.id <> p_reservation_id
      and r.status in ('confirmed', 'checked_in')
      and r.check_in_date < p_check_out
      and p_check_in < r.check_out_date
  ) then
    raise exception 'La habitación no está disponible para esas fechas';
  end if;

  -- Conservar la tarifa por noche vigente (respeta overrides previos).
  -- Nota: cuando v_new_nights = v_old_nights (único caso alcanzable acá
  -- para una reserva congelada), v_per_night * v_new_nights reproduce
  -- total_amount_bs EXACTO -- misma noche, misma división, sin
  -- necesidad de una rama especial para "no tocar el total".
  select total_amount_bs / v_old_nights into v_per_night
    from public.reservations where id = p_reservation_id;

  update public.reservations
    set check_in_date  = p_check_in,
        check_out_date = p_check_out,
        total_amount_bs = v_per_night * v_new_nights
    where id = p_reservation_id
    returning * into v_row;

  insert into public.reservation_reschedules (
    reservation_id, prev_check_in, prev_check_out,
    new_check_in, new_check_out, reason
  ) values (
    p_reservation_id, v_prev_in, v_prev_out, p_check_in, p_check_out, trim(p_reason)
  );

  return v_row;
end;
$function$;
-- Grants sin cambios (misma firma desde 20260722010000).
