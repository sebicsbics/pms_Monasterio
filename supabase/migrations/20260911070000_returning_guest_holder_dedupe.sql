-- =====================================================================
-- Bug real: huésped que regresa quedaba bloqueado en el check-in.
-- (change: reservation-booker-vs-guest, PR6 fix 1/4).
--
-- POR QUÉ
-- check_in_reservation_with_guests, en la rama de titular NUEVO
-- (p_holder_first_name/p_holder_last_name), rechazaba con 'Ya existe otro
-- huésped con el documento %' apenas encontraba ese documento en
-- public.guests. Pero TODAS las demás rutas de este código
-- (add_reservation_companions, los occupants de create_bulk_reservation,
-- walk_in_check_in) dedupean por documento y reutilizan la persona -- es
-- el patrón establecido. El caso real: un huésped que ya se hospedó antes
-- vuelve; recepción tipea su nombre + documento como titular de la nueva
-- reserva -> el check-in se rechazaba en vez de reconocerlo.
--
-- Fix: misma resolución que add_reservation_companions (última definición
-- vigente, 20260911020000) -- si el documento ya existe, se reutiliza esa
-- persona (se actualizan nombre/apellido, igual que ese patrón), nunca se
-- rechaza ni se duplica.
--
-- Chequeo de seguridad que NO se duplica acá: "la persona ya es ocupante
-- ACTIVO de otra estadía" -- el EXCLUDE de solapamiento
-- (reservation_guests_no_overlap, 20260911040000) ya lo cubre al insertar
-- la fila de holder más abajo en esta misma función; agregar un chequeo
-- manual aparte sería una segunda fuente de verdad para la misma regla.
--
-- Misma aridad -> CREATE OR REPLACE alcanza, sin DROP. Grants: se
-- reafirman explícitamente (regla de higiene de la tarea).
-- =====================================================================
create or replace function public.check_in_reservation_with_guests(
  p_reservation_id    uuid,
  p_document          text,
  p_birth_date        date,
  p_country_code      text,
  p_city              text,
  p_wants_offers      boolean,
  p_origin_city       text default null,
  p_travel_purpose    text default null,
  p_occupation        text default null,
  p_transport_means   text default null,
  p_companions        jsonb default '[]'::jsonb,
  p_agency_name       text default null,
  p_channel_code      text default null,
  p_holder_first_name text default null,
  p_holder_last_name  text default null,
  p_holder_person_id  uuid default null,
  p_occupancy_reason  text default null
) returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_companions jsonb := coalesce(p_companions, '[]'::jsonb);
  v_total      int   := jsonb_array_length(v_companions) + 1;
  v_max_occ    int;
  v_guest_id   uuid;
  v_booking_id uuid;
  v_reason     text;
begin
  select rt.max_occupancy, r.guest_id, r.booking_id
    into v_max_occ, v_guest_id, v_booking_id
  from public.reservations r
  join public.room_types rt on rt.id = r.room_type_id
  where r.id = p_reservation_id;

  if v_booking_id is null then
    raise exception 'Reserva no encontrada';
  end if;

  if v_max_occ is not null and v_total > v_max_occ then
    v_reason := nullif(trim(p_occupancy_reason), '');
    if v_reason is null then
      raise exception
        'La habitación admite % huésped(es); estás registrando %. Indique un motivo para exceder el límite.',
        v_max_occ, v_total;
    end if;
    insert into public.occupancy_overrides (
      reservation_id, max_occupancy, resulting_occupancy, reason
    ) values (p_reservation_id, v_max_occ, v_total, v_reason);
  end if;

  -- Resolver titular si el alta lo dejó pendiente (toggle OFF / bulk sin
  -- occupants precargados para esta habitación).
  if v_guest_id is null then
    if p_holder_person_id is not null then
      if not exists (
        select 1 from public.reservation_guests
        where reservation_id = p_reservation_id and person_id = p_holder_person_id
      ) then
        raise exception 'El huésped indicado no está precargado en esta habitación';
      end if;
      v_guest_id := p_holder_person_id;
    elsif nullif(trim(p_holder_first_name), '') is not null
          and nullif(trim(p_holder_last_name), '') is not null then
      -- Dedupe por documento (mismo patrón que add_reservation_companions,
      -- 20260911020000): si la persona ya existe (huésped que regresa), se
      -- reutiliza -- nunca se rechaza ni se crea una segunda fila.
      v_guest_id := null;
      if nullif(p_document, '') is not null then
        select person_id into v_guest_id
        from public.guests where passport_number = p_document;
      end if;

      if v_guest_id is not null then
        update public.people set
          first_name = trim(p_holder_first_name),
          last_name  = trim(p_holder_last_name)
        where id = v_guest_id;
      else
        insert into public.people (first_name, last_name)
        values (trim(p_holder_first_name), trim(p_holder_last_name))
        returning id into v_guest_id;
        insert into public.guests (person_id) values (v_guest_id)
          on conflict (person_id) do nothing;
      end if;
    else
      raise exception 'Debe indicar un huésped titular antes del check-in';
    end if;

    update public.reservations set guest_id = v_guest_id where id = p_reservation_id;
    insert into public.reservation_guests (reservation_id, person_id, role, confirmed_at)
    values (p_reservation_id, v_guest_id, 'holder', now())
    on conflict (reservation_id, person_id)
      do update set role = 'holder', confirmed_at = now();
  else
    -- Titular ya resuelto al reservar (contacto-titular o precargado):
    -- se confirma, nunca se re-inserta ni se reasigna a otra persona.
    insert into public.reservation_guests (reservation_id, person_id, role, confirmed_at)
    values (p_reservation_id, v_guest_id, 'holder', now())
    on conflict (reservation_id, person_id)
      do update set role = 'holder', confirmed_at = now();
  end if;

  perform public.check_in_reservation(
    p_reservation_id, p_document, p_birth_date, p_country_code, p_city, p_wants_offers
  );

  -- Perfil de viaje del titular (después del check-in base).
  update public.guests set
    origin_city     = coalesce(nullif(p_origin_city, ''), origin_city),
    travel_purpose  = coalesce(nullif(p_travel_purpose, ''), travel_purpose),
    occupation      = coalesce(nullif(p_occupation, ''), occupation),
    transport_means = coalesce(nullif(p_transport_means, ''), transport_means)
  where person_id = v_guest_id;

  perform public.add_reservation_companions(p_reservation_id, v_companions);

  -- La ocupación declarada pasa a ser la real (la reserva decía 1 y
  -- llegaron 2: el registro turístico tiene que reflejar 2).
  update public.reservations
    set num_guests = greatest(coalesce(num_guests, 0), v_total)
    where id = p_reservation_id;

  -- Agencia/empresa: dual-write a reservations (compat, se retira en la
  -- etapa 7) y a bookings (dueño real del dato de canal, spec §7).
  update public.reservations set
    agency_name  = nullif(trim(p_agency_name), ''),
    channel_code = nullif(p_channel_code, '')
  where id = p_reservation_id;

  update public.bookings set
    agency_name  = coalesce(nullif(trim(p_agency_name), ''), agency_name),
    channel_code = coalesce(nullif(p_channel_code, ''), channel_code)
  where id = v_booking_id;
end;
$function$;

revoke execute on function public.check_in_reservation_with_guests(
  uuid, text, date, text, text, boolean, text, text, text, text, jsonb, text, text,
  text, text, uuid, text
) from public, anon;

grant execute on function public.check_in_reservation_with_guests(
  uuid, text, date, text, text, boolean, text, text, text, text, jsonb, text, text,
  text, text, uuid, text
) to authenticated;
