-- =====================================================================
-- SEGURIDAD: dos RPC SECURITY DEFINER sin guard de rol.
-- (change: fix-privilege-escalation)
--
-- Encontrados auditando `pg_proc` en busca de funciones SECURITY DEFINER
-- ejecutables por `authenticated` cuyo cuerpo no menciona
-- `current_user_role`. Ambos verificados explotándolos en producción
-- dentro de una transacción revertida.
--
-- ---------------------------------------------------------------------
-- 1) setup_employee — ESCALADA DE PRIVILEGIOS (abierta desde 20260703100000)
--
-- Hace `update public.profiles set role = p_role` sin comprobar quién
-- llama. Cualquier usuario autenticado podía ascenderse a root con una
-- sola llamada desde las devtools:
--
--     supabase.rpc('setup_employee',
--       { p_email: '<su propio email>', p_username: 'x', p_role: 'root' })
--
-- Verificado: un usuario `owner` (solo lectura) pasó a `root`. Esto anula
-- por completo el modelo de roles — incluido el owner de solo lectura que
-- se agregó en 20260809010000.
--
-- Se le pone guard de root Y se revoca de authenticated: es un helper de
-- bootstrap pensado para el editor SQL, no para la aplicación. El alta
-- real de personal es `create_staff_member`, que sí valida.
-- ---------------------------------------------------------------------
create or replace function public.setup_employee(
  p_email text, p_username text, p_role text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if public.current_user_role() <> 'root' then
    raise exception 'No autorizado';
  end if;

  if p_role not in ('root', 'accountant', 'reception', 'reception_admin', 'owner') then
    raise exception 'Rol inválido: %', p_role;
  end if;

  select id into v_id from auth.users where email = p_email;
  if v_id is null then
    raise exception 'No existe un usuario con email % — crealo primero en el dashboard', p_email;
  end if;

  update public.profiles
    set username = p_username,
        role = p_role,
        must_change_password = true
    where id = v_id;
end;
$$;

revoke execute on function public.setup_employee(text, text, text) from public, anon, authenticated;

comment on function public.setup_employee(text, text, text) is
  'Helper de bootstrap para el editor SQL (root). Revocada de '
  'authenticated: permitía escalar a root sin ningún control. El alta de '
  'personal desde la aplicación es create_staff_member.';

-- ---------------------------------------------------------------------
-- 2) walk_in_check_in — CHECK-IN SIN CONTROL DE ROL
--
-- Su ÚNICO `current_user_role()` está dentro de la rama
-- `if p_rate_bs is not null and p_rate_bs <> v_room_type_rate`: protege el
-- CAMBIO DE TARIFA, no el check-in. Un walk-in a precio de lista no pasa
-- por ningún control.
--
-- Verificado: un usuario `owner` creó una reserva y dejó la habitación en
-- 'occupied'. El envoltorio walk_in_check_in_with_guests tampoco valida
-- (delegaba en esta función), así que el agujero llegaba hasta la API.
--
-- Se agrega el guard ARRIBA, con el mismo alcance que
-- `check_in_reservation` (root/reception/reception_admin), que es el flujo
-- equivalente y sí lo tenía desde siempre.
-- ---------------------------------------------------------------------
create or replace function public.walk_in_check_in(
  p_room_id uuid, p_room_type_id uuid, p_first_name text, p_last_name text,
  p_document text, p_email text, p_birth_date date, p_country_code text,
  p_city text, p_wants_offers boolean, p_nights integer,
  p_rate_bs numeric default null::numeric,
  p_rate_reason text default null::text
) returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_person_id       uuid;
  v_reservation_id  uuid;
  v_room_type_rate  numeric(10,2);
  v_status          varchar(15);
begin
  -- ÚNICO cambio respecto de la versión vigente (obtenida con
  -- pg_get_functiondef): este guard. El resto es idéntico.
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado para hacer check-in';
  end if;

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

  if p_rate_bs is not null and p_rate_bs <> v_room_type_rate then
    if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
      raise exception 'No autorizado para cambiar la tarifa';
    end if;
    if p_rate_reason is null or char_length(trim(p_rate_reason)) = 0 then
      raise exception 'La justificación es obligatoria para cambiar la tarifa';
    end if;
    if p_rate_bs <= 0 then
      raise exception 'La tarifa debe ser un monto positivo';
    end if;
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

  -- Insertar SIEMPRE al precio de lista del tipo de habitación.
  insert into public.reservations (
    guest_id, room_id, room_type_id, check_in_date, check_out_date,
    reservation_method, payment_status, total_amount_bs, status
  ) values (
    v_person_id, p_room_id, p_room_type_id, current_date, current_date + p_nights,
    'walk-in', 'pending', v_room_type_rate * p_nights, 'checked_in'
  ) returning id into v_reservation_id;

  insert into public.folios (reservation_id) values (v_reservation_id);
  update public.rooms set operational_status = 'occupied' where id = p_room_id;

  if p_rate_bs is not null and p_rate_bs <> v_room_type_rate then
    perform public.apply_rate_change(
      v_reservation_id, p_room_type_id, v_room_type_rate, p_nights, p_rate_bs, p_rate_reason
    );
  end if;

  return v_reservation_id;
end;
$function$;

grant execute on function public.walk_in_check_in(
  uuid, uuid, text, text, text, text, date, text, text, boolean, integer, numeric, text
) to authenticated;
