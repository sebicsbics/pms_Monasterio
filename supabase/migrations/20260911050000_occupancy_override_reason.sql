-- =====================================================================
-- Sobre-ocupación permitida solo con motivo obligatorio.
-- (change: reservation-booker-vs-guest, PR4, 7/8).
--
-- POR QUÉ
-- Hoy check_in_reservation_with_guests / walk_in_check_in_with_guests /
-- add_guests_to_stay rechazan de plano cualquier ocupación que supere
-- room_types.max_occupancy. La regla de negocio real es: se permite
-- exceder el máximo, pero SIEMPRE con un motivo (no hay flujo de
-- aprobación -- se registra y sigue, auditable). create_bulk_reservation
-- hoy directamente NO valida max_occupancy por habitación (solo el techo
-- de sanity de 20 personas) -- se agrega la misma regla acá.
--
--   1) occupancy_overrides: una fila por cada vez que se excedió el
--      máximo, con el motivo. RLS de solo lectura, mismo criterio que
--      rate_discount_requests_read (root/reception/reception_admin/
--      accountant) -- nunca hay policy de insert/update: solo lo escriben
--      las RPC SECURITY DEFINER de abajo.
--   2) Las 4 RPC ganan p_occupancy_reason (arity change en las 3 de
--      check-in -> DROP + CREATE; create_bulk_reservation también cambia
--      de firma). Dentro del máximo: sin cambios, no se pide motivo, no
--      se inserta fila. Por encima: sin motivo se rechaza con el mensaje
--      exacto de la tarea; con motivo, éxito inmediato + fila de auditoría.
--   3) create_bulk_reservation: el motivo va POR HABITACIÓN, dentro de
--      cada elemento de p_rooms (`occupancy_reason`) -- un solo
--      p_occupancy_reason a nivel de reserva grupal no alcanza porque
--      cada habitación puede exceder su propio máximo por una razón
--      distinta (ej. cuna extra en una, colchón adicional en otra). El
--      techo de sanity de 20 personas por habitación se mantiene sin
--      cambios (chequeo previo, no lo reemplaza el motivo).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) occupancy_overrides
-- ---------------------------------------------------------------------
create table public.occupancy_overrides (
  id                  uuid primary key default gen_random_uuid(),
  reservation_id      uuid not null references public.reservations(id),
  max_occupancy       int not null,
  resulting_occupancy int not null,
  reason              text not null check (char_length(trim(reason)) > 0),
  created_by          uuid references public.profiles(id) default auth.uid(),
  created_at          timestamptz not null default now()
);

comment on table public.occupancy_overrides is
  'Auditoría de sobre-ocupación autorizada por motivo (sin aprobación) -- '
  'ver 20260911050000.';

alter table public.occupancy_overrides enable row level security;

create policy "occupancy_overrides_read" on public.occupancy_overrides
  for select using (
    public.current_user_role() in ('root', 'reception', 'reception_admin', 'accountant')
  );

-- Sin policy de insert/update/delete: solo lo escriben las RPC
-- SECURITY DEFINER de abajo (mismo patrón que rate_discount_requests /
-- rate_overrides).

-- ---------------------------------------------------------------------
-- 2) check_in_reservation_with_guests: agrega p_occupancy_reason.
--    Cambia de aridad -> DROP de la firma vigente (20260911020000)
--    primero.
-- ---------------------------------------------------------------------
drop function if exists public.check_in_reservation_with_guests(
  uuid, text, date, text, text, boolean, text, text, text, text, jsonb, text, text,
  text, text, uuid
);

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
      -- Documento duplicado, comparado contra el titular YA resuelto
      -- (nunca contra NULL: eso dejaba pasar duplicados en silencio).
      if nullif(p_document, '') is not null and exists (
        select 1 from public.guests where passport_number = p_document
      ) then
        raise exception 'Ya existe otro huésped con el documento %', p_document;
      end if;

      insert into public.people (first_name, last_name)
      values (trim(p_holder_first_name), trim(p_holder_last_name))
      returning id into v_guest_id;
      insert into public.guests (person_id) values (v_guest_id)
        on conflict (person_id) do nothing;
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

-- ---------------------------------------------------------------------
-- 3) walk_in_check_in_with_guests: agrega p_occupancy_reason. Cambia de
--    aridad -> DROP primero.
-- ---------------------------------------------------------------------
drop function if exists public.walk_in_check_in_with_guests(
  uuid, uuid, text, text, text, text, date, text, text, boolean, integer,
  numeric, text, text, text, text, text, jsonb, text, text
);

create or replace function public.walk_in_check_in_with_guests(
  p_room_id          uuid,
  p_room_type_id     uuid,
  p_first_name       text,
  p_last_name        text,
  p_document         text,
  p_email            text,
  p_birth_date       date,
  p_country_code     text,
  p_city             text,
  p_wants_offers     boolean,
  p_nights           integer,
  p_rate_bs          numeric default null,
  p_rate_reason      text default null,
  p_origin_city      text default null,
  p_travel_purpose   text default null,
  p_occupation       text default null,
  p_transport_means  text default null,
  p_companions       jsonb default '[]'::jsonb,
  p_agency_name      text default null,
  p_channel_code     text default null,
  p_occupancy_reason text default null
) returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_companions jsonb := coalesce(p_companions, '[]'::jsonb);
  v_total      int   := jsonb_array_length(v_companions) + 1;
  v_max        int;
  v_res        uuid;
  v_guest_id   uuid;
  v_booking_id uuid;
  v_reason     text;
begin
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

  update public.guests set
    origin_city     = coalesce(nullif(p_origin_city, ''), origin_city),
    travel_purpose  = coalesce(nullif(p_travel_purpose, ''), travel_purpose),
    occupation      = coalesce(nullif(p_occupation, ''), occupation),
    transport_means = coalesce(nullif(p_transport_means, ''), transport_means)
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

revoke execute on function public.walk_in_check_in_with_guests(
  uuid, uuid, text, text, text, text, date, text, text, boolean, integer,
  numeric, text, text, text, text, text, jsonb, text, text, text
) from public, anon;

grant execute on function public.walk_in_check_in_with_guests(
  uuid, uuid, text, text, text, text, date, text, text, boolean, integer,
  numeric, text, text, text, text, text, jsonb, text, text, text
) to authenticated;

-- ---------------------------------------------------------------------
-- 4) add_guests_to_stay: agrega p_occupancy_reason. Cambia de aridad ->
--    DROP primero.
-- ---------------------------------------------------------------------
drop function if exists public.add_guests_to_stay(uuid, jsonb, numeric, text);

create or replace function public.add_guests_to_stay(
  p_room_id            uuid,
  p_companions         jsonb,
  p_extra_charge_bs    numeric default 0,
  p_charge_description text default null,
  p_occupancy_reason   text default null
) returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_companions jsonb := coalesce(p_companions, '[]'::jsonb);
  v_new        int   := jsonb_array_length(v_companions);
  v_reservation uuid;
  v_room_type   uuid;
  v_max_occ     int;
  v_current     int;
  v_total       int;
  v_desc        text;
  v_names       text;
  v_reason      text;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado para agregar huéspedes';
  end if;

  if v_new = 0 then
    raise exception 'No hay huéspedes para agregar';
  end if;

  if p_extra_charge_bs is null or p_extra_charge_bs < 0 then
    raise exception 'El incremento debe ser un monto mayor o igual a 0';
  end if;

  select r.id, r.room_type_id into v_reservation, v_room_type
  from public.reservations r
  where r.room_id = p_room_id and r.status = 'checked_in'
  order by r.check_in_date desc
  limit 1;

  if v_reservation is null then
    raise exception 'No hay una estadía activa en esta habitación';
  end if;

  select max_occupancy into v_max_occ
  from public.room_types where id = v_room_type;

  select count(*) into v_current
  from public.stay_guests where reservation_id = v_reservation;

  v_total := v_current + v_new;
  if v_max_occ is not null and v_total > v_max_occ then
    v_reason := nullif(trim(p_occupancy_reason), '');
    if v_reason is null then
      raise exception
        'La habitación admite % huésped(es); estás registrando %. Indique un motivo para exceder el límite.',
        v_max_occ, v_total;
    end if;
    insert into public.occupancy_overrides (
      reservation_id, max_occupancy, resulting_occupancy, reason
    ) values (v_reservation, v_max_occ, v_total, v_reason);
  end if;

  perform public.add_reservation_companions(v_reservation, v_companions);

  update public.reservations
    set num_guests = greatest(coalesce(num_guests, 0), v_total)
    where id = v_reservation;

  if p_extra_charge_bs > 0 then
    v_desc := nullif(trim(coalesce(p_charge_description, '')), '');
    if v_desc is null then
      select string_agg(
               trim(c->>'first_name') || ' ' || trim(c->>'last_name'), ', '
             )
      into v_names
      from jsonb_array_elements(v_companions) as t(c);
      v_desc := 'Huésped adicional: ' || coalesce(v_names, '');
    end if;
    perform public.add_folio_charge(p_room_id, v_desc, p_extra_charge_bs);
  end if;

  return v_total;
end;
$$;

revoke execute on function public.add_guests_to_stay(uuid, jsonb, numeric, text, text) from public, anon;
grant execute on function public.add_guests_to_stay(uuid, jsonb, numeric, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- 5) create_bulk_reservation: motivo POR HABITACIÓN
--    (elem->>'occupancy_reason'), no un parámetro nuevo a nivel de
--    función -- misma firma, CREATE OR REPLACE alcanza. El techo de
--    sanity de 20 personas se mantiene sin cambios.
-- ---------------------------------------------------------------------
create or replace function public.create_bulk_reservation(
  p_rooms      jsonb,
  p_first_name text,
  p_last_name  text,
  p_phone      text,
  p_email      text,
  p_check_in   date,
  p_check_out  date,
  p_method     text,
  p_rate_bs    numeric default null,
  p_reason     text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_person_id      uuid;
  v_booking_id     uuid;
  v_nights         int;
  v_created        jsonb := '[]'::jsonb;
  v_failed         jsonb := '[]'::jsonb;
  elem             jsonb;
  v_room_id        uuid;
  v_room_type_id   uuid;
  v_guests         int;
  v_rate           numeric(10,2);
  v_max_occ        int;
  v_occ_reason     text;
  v_reservation_id uuid;
  v_occupants      jsonb;
  occ              jsonb;
  v_doc            text;
  v_occ_person     uuid;
  v_is_first       boolean;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado para crear reservas';
  end if;

  if p_check_out <= p_check_in then
    raise exception 'La fecha de salida debe ser posterior a la de entrada';
  end if;
  if nullif(trim(p_phone), '') is null and nullif(trim(p_email), '') is null then
    raise exception 'Se requiere al menos un contacto (celular o correo)';
  end if;
  if jsonb_array_length(coalesce(p_rooms, '[]'::jsonb)) = 0 then
    raise exception 'Seleccioná al menos una habitación';
  end if;

  v_nights := p_check_out - p_check_in;

  if nullif(p_email, '') is not null then
    select id into v_person_id from public.people where email = p_email;
  end if;

  if v_person_id is not null then
    update public.people set
      first_name = p_first_name,
      last_name  = p_last_name,
      phone      = coalesce(nullif(p_phone, ''), phone)
    where id = v_person_id;
  else
    insert into public.people (first_name, last_name, email, phone)
    values (p_first_name, p_last_name, nullif(p_email, ''), nullif(p_phone, ''))
    returning id into v_person_id;
  end if;

  insert into public.bookings (contact_person_id) values (v_person_id)
  returning id into v_booking_id;

  for elem in select value from jsonb_array_elements(p_rooms) as t(value)
  loop
    v_room_id      := (elem->>'room_id')::uuid;
    v_room_type_id := (elem->>'room_type_id')::uuid;
    v_guests       := coalesce((elem->>'num_guests')::int, 1);
    begin
      if v_guests < 1 then
        raise exception 'Cada habitación necesita al menos 1 persona';
      end if;
      if v_guests > 20 then
        raise exception 'Ocupación implausible (% personas)', v_guests;
      end if;

      select rt.base_price_bs, rt.max_occupancy into v_rate, v_max_occ
      from public.room_type_options o
      join public.room_types rt on rt.id = o.room_type_id
      where o.room_id = v_room_id and o.room_type_id = v_room_type_id;

      if v_rate is null then
        raise exception 'El tipo seleccionado no corresponde a la habitación';
      end if;

      if v_max_occ is not null and v_guests > v_max_occ then
        v_occ_reason := nullif(trim(elem->>'occupancy_reason'), '');
        if v_occ_reason is null then
          raise exception
            'La habitación admite % huésped(es); estás registrando %. Indique un motivo para exceder el límite.',
            v_max_occ, v_guests;
        end if;
      else
        v_occ_reason := null;
      end if;

      perform 1 from public.rooms where id = v_room_id for update;
      if exists (
        select 1 from public.reservations r
        where r.room_id = v_room_id
          and r.status in ('confirmed', 'checked_in')
          and r.check_in_date < p_check_out
          and p_check_in < r.check_out_date
      ) then
        raise exception 'La habitación ya no está disponible para esas fechas';
      end if;

      insert into public.reservations (
        guest_id, room_id, room_type_id, check_in_date, check_out_date,
        reservation_method, payment_status, total_amount_bs, status, num_guests,
        booking_id
      ) values (
        null, v_room_id, v_room_type_id, p_check_in, p_check_out,
        p_method, 'pending', v_rate * v_nights, 'confirmed', v_guests,
        v_booking_id
      ) returning id into v_reservation_id;

      if v_occ_reason is not null then
        insert into public.occupancy_overrides (
          reservation_id, max_occupancy, resulting_occupancy, reason
        ) values (v_reservation_id, v_max_occ, v_guests, v_occ_reason);
      end if;

      v_occupants := coalesce(elem->'occupants', '[]'::jsonb);
      v_is_first := true;
      for occ in select value from jsonb_array_elements(v_occupants) as t(value)
      loop
        if coalesce(trim(occ->>'first_name'), '') = ''
           or coalesce(trim(occ->>'last_name'), '') = '' then
          raise exception 'Cada huésped requiere nombre y apellido';
        end if;

        v_doc := nullif(trim(occ->>'document'), '');
        v_occ_person := null;
        if v_doc is not null then
          select person_id into v_occ_person
          from public.guests where passport_number = v_doc;
        end if;

        if v_occ_person is not null then
          update public.people set
            first_name = trim(occ->>'first_name'),
            last_name  = trim(occ->>'last_name'),
            birth_date = coalesce(nullif(occ->>'birth_date', '')::date, birth_date)
          where id = v_occ_person;
        else
          insert into public.people (first_name, last_name, birth_date)
          values (
            trim(occ->>'first_name'), trim(occ->>'last_name'),
            nullif(occ->>'birth_date', '')::date
          )
          returning id into v_occ_person;
          insert into public.guests (person_id, passport_number)
          values (v_occ_person, v_doc);
        end if;

        if v_is_first then
          update public.reservations set guest_id = v_occ_person
            where id = v_reservation_id;
          insert into public.reservation_guests (reservation_id, person_id, role, confirmed_at)
          values (v_reservation_id, v_occ_person, 'holder', null)
          on conflict (reservation_id, person_id) do update set role = 'holder';
          v_is_first := false;
        else
          insert into public.reservation_guests (reservation_id, person_id, role, confirmed_at)
          values (v_reservation_id, v_occ_person, 'companion', null)
          on conflict (reservation_id, person_id) do nothing;
        end if;
      end loop;

      if p_rate_bs is not null and p_rate_bs <> v_rate then
        if p_reason is null or char_length(trim(p_reason)) = 0 then
          raise exception 'La justificación es obligatoria para cambiar la tarifa';
        end if;
        if p_rate_bs <= 0 then
          raise exception 'La tarifa debe ser un monto positivo';
        end if;
        perform public.apply_rate_change(
          v_reservation_id, v_room_type_id, v_rate, v_nights, p_rate_bs, p_reason
        );
      end if;

      v_created := v_created || to_jsonb(v_reservation_id::text);
    exception when others then
      v_failed := v_failed || jsonb_build_object('room_id', v_room_id, 'error', sqlerrm);
    end;
  end loop;

  return jsonb_build_object('created', v_created, 'failed', v_failed);
end;
$$;

revoke execute on function public.create_bulk_reservation(
  jsonb, text, text, text, text, date, date, text, numeric, text
) from public, anon;
grant execute on function public.create_bulk_reservation(
  jsonb, text, text, text, text, date, date, text, numeric, text
) to authenticated;
