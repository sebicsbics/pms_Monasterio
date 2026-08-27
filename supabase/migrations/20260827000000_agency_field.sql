-- =====================================================================
-- Casilla de agencia/empresa en el check-in.
-- (change: checkin-payment-and-agency, PR 1)
--
-- El pedido: poder anotar por qué canal llegó el huésped (agencia,
-- empresa, referido, etc.) con texto libre + una categoría, sin tocar
-- `guests` — el mismo huésped puede venir por canales distintos en cada
-- viaje, así que el dato es de la RESERVA, no de la persona.
--
-- `channel_code` referencia `reservation_channels`, la misma tabla que
-- ya alimenta datos históricos, para dejar la puerta abierta a revivir
-- analítica de canal más adelante sin tener que migrar texto suelto.
-- `v_channel_mix` NO se toca en este cambio: sigue leyendo solo
-- `historical_stays`.
-- =====================================================================

alter table public.reservations
  add column agency_name text,
  add column channel_code varchar references public.reservation_channels(code);

-- ---------------------------------------------------------------------
-- check_in_reservation_with_guests: agrega p_agency_name/p_channel_code
-- como parámetros finales opcionales.
--
-- Trampa de sobrecarga: CREATE OR REPLACE con una aridad distinta crea
-- una SEGUNDA función en vez de reemplazar la existente, y cualquier
-- llamado con la aridad vieja queda ambiguo (rompe el check-in que ya
-- funciona). Por eso el DROP con la firma EXACTA vigente va primero.
-- ---------------------------------------------------------------------
drop function if exists public.check_in_reservation_with_guests(
  uuid, text, date, text, text, boolean, text, text, text, text, jsonb
);

create or replace function public.check_in_reservation_with_guests(
  p_reservation_id  uuid,
  p_document        text,
  p_birth_date      date,
  p_country_code    text,
  p_city            text,
  p_wants_offers    boolean,
  p_origin_city     text default null,
  p_travel_purpose  text default null,
  p_occupation      text default null,
  p_transport_means text default null,
  p_companions      jsonb default '[]'::jsonb,
  p_agency_name     text default null,
  p_channel_code    text default null
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
begin
  -- El tope es la capacidad de la habitación, NO num_guests (que es la
  -- estimación de la reserva y suele venir en 1 o null). Antes esto
  -- impedía registrar al acompañante que sí llegó.
  select rt.max_occupancy, r.guest_id into v_max_occ, v_guest_id
  from public.reservations r
  join public.room_types rt on rt.id = r.room_type_id
  where r.id = p_reservation_id;

  if v_max_occ is not null and v_total > v_max_occ then
    raise exception 'La habitación admite % huésped(es); estás registrando %',
      v_max_occ, v_total;
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

  -- Agencia/empresa: texto libre + categoría, ambos opcionales. Texto
  -- vacío se guarda como NULL, no como cadena vacía.
  update public.reservations set
    agency_name  = nullif(trim(p_agency_name), ''),
    channel_code = nullif(p_channel_code, '')
  where id = p_reservation_id;
end;
$function$;

-- El DROP+CREATE crea la función de cero y Postgres le agrega EXECUTE a
-- PUBLIC por defecto, sin importar el `alter default privileges` de
-- 20260812010000 (no aplica de forma confiable a través de un reset).
-- Se revoca explícito, como ya hace record_mixed_income.
revoke execute on function public.check_in_reservation_with_guests(
  uuid, text, date, text, text, boolean, text, text, text, text, jsonb, text, text
) from public, anon;

grant execute on function public.check_in_reservation_with_guests(
  uuid, text, date, text, text, boolean, text, text, text, text, jsonb, text, text
) to authenticated;

-- ---------------------------------------------------------------------
-- walk_in_check_in_with_guests: mismo patrón.
-- ---------------------------------------------------------------------
drop function if exists public.walk_in_check_in_with_guests(
  uuid, uuid, text, text, text, text, date, text, text, boolean, integer,
  numeric, text, text, text, text, text, jsonb
);

create or replace function public.walk_in_check_in_with_guests(
  p_room_id         uuid,
  p_room_type_id    uuid,
  p_first_name      text,
  p_last_name       text,
  p_document        text,
  p_email           text,
  p_birth_date      date,
  p_country_code    text,
  p_city            text,
  p_wants_offers    boolean,
  p_nights          integer,
  p_rate_bs         numeric default null,
  p_rate_reason     text default null,
  p_origin_city     text default null,
  p_travel_purpose  text default null,
  p_occupation      text default null,
  p_transport_means text default null,
  p_companions      jsonb default '[]'::jsonb,
  p_agency_name     text default null,
  p_channel_code    text default null
) returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_companions jsonb := coalesce(p_companions, '[]'::jsonb);
  v_max        int;
  v_res        uuid;
  v_guest_id   uuid;
begin
  select max_occupancy into v_max
  from public.room_types where id = p_room_type_id;

  if v_max is not null and jsonb_array_length(v_companions) + 1 > v_max then
    raise exception 'El tipo elegido admite hasta % personas', v_max;
  end if;

  v_res := public.walk_in_check_in(
    p_room_id, p_room_type_id, p_first_name, p_last_name, p_document, p_email,
    p_birth_date, p_country_code, p_city, p_wants_offers, p_nights,
    p_rate_bs, p_rate_reason
  );

  select guest_id into v_guest_id from public.reservations where id = v_res;

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

  return v_res;
end;
$function$;

revoke execute on function public.walk_in_check_in_with_guests(
  uuid, uuid, text, text, text, text, date, text, text, boolean, integer,
  numeric, text, text, text, text, text, jsonb, text, text
) from public, anon;

grant execute on function public.walk_in_check_in_with_guests(
  uuid, uuid, text, text, text, text, date, text, text, boolean, integer,
  numeric, text, text, text, text, text, jsonb, text, text
) to authenticated;
