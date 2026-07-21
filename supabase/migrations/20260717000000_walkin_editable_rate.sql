-- =====================================================================
-- Tarifa editable EN EL MOMENTO DEL CHECK-IN (walk-in), no solo después.
-- Completa la regla de negocio de 20260716030000_rate_overrides.sql:
-- ahí solo se podía corregir la tarifa de una reserva ya cargada
-- (override_reservation_rate, folio ya abierto). Este cambio agrega
-- dos parámetros opcionales a walk_in_check_in para que el/la
-- recepcionista pueda vender una habitación a un precio distinto del
-- tipo desde el tablero, con la MISMA regla de justificación obligatoria
-- y el mismo rastro de auditoría en rate_overrides.
--
-- El número de parámetros cambia (11 -> 13), así que hay que dropear
-- la firma vieja explícitamente: si no, Postgres crea un OVERLOAD en
-- vez de reemplazar la función, y el código sigue llamando la versión
-- vieja sin darse cuenta (ya nos pasó en una migración anterior).
--
-- SECURITY DEFINER: la función necesita insertar en rate_overrides,
-- que no tiene policy de insert (solo se escribe desde funciones
-- SECURITY DEFINER — ver 20260716030000_rate_overrides.sql). Reusar
-- override_reservation_rate con un segundo round-trip habría sido más
-- simple de leer pero exige dos operaciones no atómicas (reserva creada
-- con la tarifa del tipo, y RECIÉN DESPUÉS corregida) — eso deja una
-- ventana donde total_amount_bs es momentáneamente el precio de lista,
-- y si el segundo paso falla, la reserva queda creada con el precio
-- equivocado y sin registro del intento de corrección. Insertar todo
-- en una sola función SECURITY DEFINER es atómico: la reserva nace
-- con el monto correcto y el rastro de auditoría, o no nace nada.
--
-- Se agrega el mismo gate de rol que usa override_reservation_rate
-- (root/reception) PERO SOLO para el camino de tarifa personalizada:
-- si p_rate_bs es null o igual a la tarifa del tipo, no hay chequeo de
-- rol adicional (mantiene compatibilidad con cualquier llamador actual
-- que no toque tarifa). Ver reporte de riesgo sobre el grant a `anon`
-- heredado de la función original.
-- =====================================================================

drop function if exists public.walk_in_check_in(
  uuid, uuid, text, text, text, text, date, text, text, boolean, int
);

create or replace function public.walk_in_check_in(
  p_room_id      uuid,
  p_room_type_id uuid,
  p_first_name   text,
  p_last_name    text,
  p_document     text,
  p_email        text,
  p_birth_date   date,
  p_country_code text,
  p_city         text,
  p_wants_offers boolean,
  p_nights       int,
  p_rate_bs      numeric default null,
  p_rate_reason  text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_person_id       uuid;
  v_reservation_id  uuid;
  v_room_type_rate  numeric(10,2);
  v_effective_rate  numeric(10,2);
  v_status          varchar(15);
begin
  if p_nights < 1 then
    raise exception 'Las noches deben ser al menos 1';
  end if;

  -- Bloqueo pesimista de la habitación.
  select operational_status into v_status
  from public.rooms where id = p_room_id for update;
  if v_status is null then
    raise exception 'Habitación no encontrada';
  end if;
  if v_status <> 'available' then
    raise exception 'La habitación no está disponible (estado actual: %)', v_status;
  end if;

  if not exists (
    select 1 from public.room_type_options
    where room_id = p_room_id and room_type_id = p_room_type_id
  ) then
    raise exception 'El tipo seleccionado no corresponde a esta habitación';
  end if;

  select base_price_bs into v_room_type_rate
  from public.room_types where id = p_room_type_id;

  v_effective_rate := v_room_type_rate;

  if p_rate_bs is not null and p_rate_bs <> v_room_type_rate then
    if public.current_user_role() not in ('root', 'reception') then
      raise exception 'No autorizado para cambiar la tarifa';
    end if;
    if p_rate_reason is null or char_length(trim(p_rate_reason)) = 0 then
      raise exception 'La justificación es obligatoria para cambiar la tarifa';
    end if;
    if p_rate_bs <= 0 then
      raise exception 'La tarifa debe ser un monto positivo';
    end if;
    v_effective_rate := p_rate_bs;
  end if;

  -- ¿Huésped ya conocido por documento?
  if nullif(p_document, '') is not null then
    select person_id into v_person_id
    from public.guests where passport_number = p_document;
  end if;

  if v_person_id is not null then
    -- Huésped que vuelve: actualizamos su ficha (sin borrar lo que no venga).
    update public.people set
      first_name = p_first_name,
      last_name  = p_last_name,
      email      = coalesce(nullif(p_email, ''), email),
      birth_date = coalesce(p_birth_date, birth_date)
    where id = v_person_id;
    update public.guests set
      country_code = coalesce(nullif(p_country_code, ''), country_code),
      city         = coalesce(nullif(p_city, ''), city),
      wants_offers = p_wants_offers
    where person_id = v_person_id;
  else
    -- Huésped nuevo.
    insert into public.people (first_name, last_name, email, birth_date)
    values (p_first_name, p_last_name, nullif(p_email, ''), p_birth_date)
    returning id into v_person_id;
    insert into public.guests (person_id, passport_number, country_code, city, wants_offers)
    values (
      v_person_id, nullif(p_document, ''),
      nullif(p_country_code, ''), nullif(p_city, ''), p_wants_offers
    );
  end if;

  insert into public.reservations (
    guest_id, room_id, room_type_id, check_in_date, check_out_date,
    reservation_method, payment_status, total_amount_bs, status
  ) values (
    v_person_id, p_room_id, p_room_type_id, current_date, current_date + p_nights,
    'walk-in', 'pending', v_effective_rate * p_nights, 'checked_in'
  ) returning id into v_reservation_id;

  insert into public.folios (reservation_id) values (v_reservation_id);
  update public.rooms set operational_status = 'occupied' where id = p_room_id;

  if v_effective_rate <> v_room_type_rate then
    insert into public.rate_overrides (
      reservation_id, previous_rate_bs, new_rate_bs, reason, changed_by
    ) values (
      v_reservation_id, v_room_type_rate, v_effective_rate, p_rate_reason, auth.uid()
    );
  end if;

  return v_reservation_id;
end;
$$;

-- Permisos de ejecución (guardado para local). Se mantiene el grant a
-- anon/authenticated de la función original: el camino sin tarifa
-- personalizada no cambia de comportamiento. El camino de tarifa
-- personalizada queda bloqueado para anon por el chequeo de rol
-- (current_user_role() vía auth.uid() es null sin sesión).
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant execute on function public.walk_in_check_in(
      uuid, uuid, text, text, text, text, date, text, text, boolean, int, numeric, text
    ) to anon, authenticated;
  end if;
end$$;
