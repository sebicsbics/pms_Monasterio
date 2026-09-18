-- =====================================================================
-- Travel fields (origin_city, travel_purpose, transport_means): mover
-- los 3 puntos de alta que hoy escriben en `guests` para que escriban
-- en `reservation_guests` (change: group-billing, stage 6, Slice 8b).
-- Spec R8.1, R8.3. `occupation`/`country_code`/`city`/`is_minor` se
-- quedan en `guests` (a nivel persona, no a nivel estadía). Las 3
-- funciones son body-only (misma firma, sin DROP).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) check_in_reservation_with_guests (18 args, 20260911080000).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_in_reservation_with_guests(p_reservation_id uuid, p_document text, p_birth_date date, p_country_code text, p_city text, p_wants_offers boolean, p_origin_city text DEFAULT NULL::text, p_travel_purpose text DEFAULT NULL::text, p_occupation text DEFAULT NULL::text, p_transport_means text DEFAULT NULL::text, p_companions jsonb DEFAULT '[]'::jsonb, p_agency_name text DEFAULT NULL::text, p_channel_code text DEFAULT NULL::text, p_holder_first_name text DEFAULT NULL::text, p_holder_last_name text DEFAULT NULL::text, p_holder_person_id uuid DEFAULT NULL::uuid, p_occupancy_reason text DEFAULT NULL::text, p_email text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_companions jsonb := coalesce(p_companions, '[]'::jsonb);
  v_total      int   := jsonb_array_length(v_companions) + 1;
  v_max_occ    int;
  v_guest_id   uuid;
  v_booking_id uuid;
  v_reason     text;
  v_email      text;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado para hacer check-in';
  end if;

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

  -- Correo del TITULAR (v_guest_id), nunca del contacto/organizador ni de
  -- un acompañante. Blanco/NULL deja el valor existente sin tocar --
  -- tildar el checkbox no debe pisar un correo ya bueno.
  v_email := nullif(trim(p_email), '');
  if v_email is not null then
    begin
      update public.people set email = v_email where id = v_guest_id;
    exception when unique_violation then
      raise exception 'Ese correo ya está registrado para otro huésped';
    end;
  end if;

  perform public.check_in_reservation(
    p_reservation_id, p_document, p_birth_date, p_country_code, p_city, p_wants_offers
  );

  -- Perfil de viaje del titular: origin_city/travel_purpose/transport_means
  -- ahora son atributos de LA ESTADÍA (reservation_guests), no de la
  -- persona (change: group-billing, Slice 8b). occupation se queda en
  -- guests (nivel persona).
  update public.reservation_guests set
    origin_city     = coalesce(nullif(p_origin_city, ''), origin_city),
    travel_purpose  = coalesce(nullif(p_travel_purpose, ''), travel_purpose),
    transport_means = coalesce(nullif(p_transport_means, ''), transport_means)
  where reservation_id = p_reservation_id and person_id = v_guest_id;

  update public.guests set occupation = coalesce(nullif(p_occupation, ''), occupation)
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

-- ---------------------------------------------------------------------
-- 2) walk_in_check_in_with_guests (21 args, 20260911050000).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.walk_in_check_in_with_guests(p_room_id uuid, p_room_type_id uuid, p_first_name text, p_last_name text, p_document text, p_email text, p_birth_date date, p_country_code text, p_city text, p_wants_offers boolean, p_nights integer, p_rate_bs numeric DEFAULT NULL::numeric, p_rate_reason text DEFAULT NULL::text, p_origin_city text DEFAULT NULL::text, p_travel_purpose text DEFAULT NULL::text, p_occupation text DEFAULT NULL::text, p_transport_means text DEFAULT NULL::text, p_companions jsonb DEFAULT '[]'::jsonb, p_agency_name text DEFAULT NULL::text, p_channel_code text DEFAULT NULL::text, p_occupancy_reason text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_companions jsonb := coalesce(p_companions, '[]'::jsonb);
  v_total      int   := jsonb_array_length(v_companions) + 1;
  v_max        int;
  v_res        uuid;
  v_guest_id   uuid;
  v_booking_id uuid;
  v_reason     text;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado para hacer check-in';
  end if;

  select max_occupancy into v_max
  from public.room_types where id = p_room_type_id;

  if v_max is not null and v_total > v_max then
    v_reason := nullif(trim(p_occupancy_reason), '');
    if v_reason is null then
      raise exception
        'La habitación admite % huésped(es); estás registrando %. Indique un motivo para exceder el límite.',
        v_max, v_total;
    end if;
  end if;

  v_res := public.walk_in_check_in(
    p_room_id, p_room_type_id, p_first_name, p_last_name, p_document, p_email,
    p_birth_date, p_country_code, p_city, p_wants_offers, p_nights,
    p_rate_bs, p_rate_reason
  );

  if v_reason is not null then
    insert into public.occupancy_overrides (
      reservation_id, max_occupancy, resulting_occupancy, reason
    ) values (v_res, v_max, v_total, v_reason);
  end if;

  select guest_id, booking_id into v_guest_id, v_booking_id
  from public.reservations where id = v_res;

  update public.reservation_guests set
    origin_city     = coalesce(nullif(p_origin_city, ''), origin_city),
    travel_purpose  = coalesce(nullif(p_travel_purpose, ''), travel_purpose),
    transport_means = coalesce(nullif(p_transport_means, ''), transport_means)
  where reservation_id = v_res and person_id = v_guest_id;

  update public.guests set occupation = coalesce(nullif(p_occupation, ''), occupation)
  where person_id = v_guest_id;

  perform public.add_reservation_companions(v_res, v_companions);

  update public.reservations set
    agency_name  = nullif(trim(p_agency_name), ''),
    channel_code = nullif(p_channel_code, '')
  where id = v_res;

  update public.bookings set
    agency_name  = coalesce(nullif(trim(p_agency_name), ''), agency_name),
    channel_code = coalesce(nullif(p_channel_code, ''), channel_code)
  where id = v_booking_id;

  return v_res;
end;
$function$;

-- ---------------------------------------------------------------------
-- 3) add_reservation_companions (2 args, 20260911020000). Mueve las 3
--    columnas de viaje a reservation_guests; occupation/country_code/
--    city/is_minor se quedan en guests. Mantiene la revocación existente
--    (internal-only, ver V-C) tras el create or replace completo.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.add_reservation_companions(p_reservation_id uuid, p_companions jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c        jsonb;
  v_doc    text;
  v_minor  boolean;
  v_person uuid;
begin
  for c in
    select value from jsonb_array_elements(coalesce(p_companions, '[]'::jsonb)) as t(value)
  loop
    if coalesce(trim(c->>'first_name'), '') = ''
       or coalesce(trim(c->>'last_name'), '') = '' then
      raise exception 'Cada huésped requiere nombre y apellido';
    end if;

    v_doc   := nullif(trim(c->>'document'), '');
    v_minor := coalesce((c->>'is_minor')::boolean, false);

    v_person := null;
    if v_doc is not null then
      select person_id into v_person
      from public.guests where passport_number = v_doc;
    end if;

    if v_person is not null then
      update public.people set
        first_name = trim(c->>'first_name'),
        last_name  = trim(c->>'last_name'),
        birth_date = coalesce(nullif(c->>'birth_date', '')::date, birth_date)
      where id = v_person;
      -- occupation/country_code/city/is_minor SE QUEDAN en guests
      -- (sin cambios). origin_city/travel_purpose/transport_means SE
      -- MUEVEN a reservation_guests (después del upsert, ver abajo).
      update public.guests set
        country_code = coalesce(nullif(c->>'country_code', ''), country_code),
        city         = coalesce(nullif(c->>'city', ''), city),
        occupation   = coalesce(nullif(c->>'occupation', ''), occupation),
        is_minor     = v_minor
      where person_id = v_person;
    else
      insert into public.people (first_name, last_name, birth_date)
      values (
        trim(c->>'first_name'), trim(c->>'last_name'),
        nullif(c->>'birth_date', '')::date
      )
      returning id into v_person;
      insert into public.guests (person_id, passport_number, country_code, city, occupation, is_minor)
      values (
        v_person, v_doc, nullif(c->>'country_code', ''), nullif(c->>'city', ''),
        nullif(c->>'occupation', ''), v_minor
      );
    end if;

    -- role='companion': el titular NUNCA pasa por acá (lo resuelve
    -- check_in_reservation_with_guests antes de llamar a esta función).
    -- confirmed_at = now(): se está registrando porque se presentó.
    -- Campos de viaje via coalesce contra el valor existente para que
    -- una llamada posterior con nulls no blanquee lo ya capturado.
    insert into public.reservation_guests (
      reservation_id, person_id, role, confirmed_at, origin_city, travel_purpose, transport_means
    )
    values (
      p_reservation_id, v_person, 'companion', now(),
      nullif(c->>'origin_city', ''), nullif(c->>'travel_purpose', ''), nullif(c->>'transport_means', '')
    )
    on conflict (reservation_id, person_id)
      do update set confirmed_at = now(),
        origin_city = coalesce(excluded.origin_city, public.reservation_guests.origin_city),
        travel_purpose = coalesce(excluded.travel_purpose, public.reservation_guests.travel_purpose),
        transport_means = coalesce(excluded.transport_means, public.reservation_guests.transport_means)
      where public.reservation_guests.role <> 'holder';
  end loop;
end;
$function$;

revoke execute on function public.add_reservation_companions(uuid, jsonb) from public, anon, authenticated;
