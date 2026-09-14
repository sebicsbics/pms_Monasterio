-- =====================================================================
-- Guard de rol en 3 RPC públicas SECURITY DEFINER que nunca lo tuvieron
-- (change: group-billing, stage 6, branch fix/revoke-internal-function-grants,
-- fix posterior a la revisión de seguridad de 20260911115000).
--
-- LO QUE ENCONTRÓ LA REVISIÓN: `assignable_staff()`,
-- `check_in_reservation_with_guests(...)` y `walk_in_check_in_with_guests(...)`
-- están otorgadas a `authenticated` correctamente -- son RPC públicas
-- reales, llamadas desde src/ (src/services/tasks.ts,
-- src/services/arrivals.ts, src/services/checkin.ts) -- pero ninguna
-- valida el rol de quien llama. `handle_new_user()` le asigna 'pending'
-- a TODA cuenta recién autoregistrada (nunca lee el rol del metadata del
-- cliente, ver 20260810010000_fix_signup_role_escalation.sql), y
-- 'pending' pasa el chequeo de EXECUTE igual que cualquier otro
-- authenticated. Confirmado en vivo: una cuenta 'pending' llamando
-- assignable_staff() se trae el legajo completo de personal (nombre +
-- puesto) sin ninguna precondición.
--
-- CADA ROL SE ELIGIÓ MIRANDO QUIÉN LA USA HOY, NO INVENTANDO UNO NUEVO:
--
-- 1. assignable_staff(): ('root','accountant','reception','reception_admin',
--    'owner') -- el grupo SHARED de src/domain/auth/roleGroups.ts. Se
--    llama desde DOS pantallas, ninguna gatea la llamada por permiso de
--    escritura: MaintenanceView.tsx:82 la trae siempre al montar (tab
--    'maintenance', roles: SHARED, incluye accountant) y RoomPanel.tsx:253
--    la trae cuando la habitación está sucia (tab 'board', también SHARED).
--    Si el guard usara OPERATIONS (como list_tasks(), que sólo vive en la
--    pestaña 'tasks') un accountant viendo Mantenimiento rompería con "No
--    autorizado" apenas carga la página -- el guard tiene que mirar TODAS
--    las pantallas que llaman a la función, no calcar el de la más
--    parecida.
--
-- 2. check_in_reservation_with_guests(...) y walk_in_check_in_with_guests(...):
--    ('root','reception','reception_admin') -- exactamente la lista que
--    YA tienen sus propios delegados internos (check_in_reservation() y
--    walk_in_check_in(), ambas revocadas de authenticated en
--    20260911115000 pero con su guard propio intacto desde antes,
--    mensaje 'No autorizado para hacer check-in' en los dos). No hace
--    falta inventar nada: el wrapper hace exactamente la misma acción de
--    negocio que el delegado, así que hereda su misma frontera. 'owner'
--    NO entra aunque vea la pestaña 'arrivals'/'board' (OPERATIONS/SHARED
--    la incluyen): check-in es una escritura y canWrite() en el cliente
--    ya la inhabilita para 'owner'; el guard de la base replica esa
--    regla de negocio, no la visibilidad de pestaña.
--
-- POR QUÉ EL MENSAJE ES EL MISMO QUE EL DELEGADO: hoy, sin este fix, un
-- 'pending' que llama a estas dos RPC YA recibe "No autorizado para hacer
-- check-in" -- pero se lo tira el delegado, después de que el wrapper ya
-- hizo lecturas SECURITY DEFINER (bypasean RLS) sobre `reservations`/
-- `room_types` y, en check_in_reservation_with_guests, escrituras reales
-- sobre `people`/`guests`/`reservation_guests`/`occupancy_overrides`/
-- `reservations.guest_id` ANTES de llegar al guard. Esas escrituras no
-- sobreviven (la excepción sin capturar aborta la sentencia completa y
-- Postgres deshace todo), pero: (a) es trabajo de más sin necesidad, y
-- (b) es una capa menos -- si mañana alguien envuelve esa llamada en un
-- `exception when others then` (un patrón que YA existe en otras RPC de
-- este archivo, ver check_in_reservation_with_guests' propio manejo de
-- unique_violation en el email), esas escrituras dejarían de deshacerse
-- solas. Guardar temprano no es cosmético.
--
-- LA DEFENSA ESTRUCTURAL: supabase/tests/22_guard_public_security_definer_rpcs.sql
-- agrega una aserción general sobre TODA función pública SECURITY DEFINER
-- ejecutable por authenticated: o menciona current_user_role()/is_staff()
-- en el cuerpo, o está en una lista explícita y comentada de excepciones
-- legítimas (self-scoping por auth.uid() = propia fila: my_profile,
-- set_my_avatar, clear_password_change_flag; predicados de rol/política:
-- current_user_role, is_staff, username_to_email). Así la próxima RPC sin
-- guard no se cuela -- el test la va a nombrar.
--
-- Las 3 son `create or replace` cuerpo-completo (mismas firmas, mismo
-- tipo de retorno, mismo prosecdef/proconfig/proacl que hoy -- verificado
-- después de aplicar) tomadas de `pg_get_functiondef` en vivo, con el
-- guard como PRIMERA sentencia y el resto BYTE-IDÉNTICO. assignable_staff
-- pasa de `language sql` a `language plpgsql` porque SQL puro no admite
-- `if ... then raise`; se mantiene STABLE (el guard sólo lee, no escribe).
--
-- TRAMPA encontrada al convertir assignable_staff: `language sql` no
-- valida el tipo de columna tan estricto como `RETURN QUERY` en plpgsql.
-- `employees.job_title` es `varchar(100)`, y la firma declara `job_title
-- text` -- en `language sql` el cast implícito pasaba solo; en plpgsql,
-- `RETURN QUERY` con esa mezcla tira `42804: structure of query does not
-- match function result type`. Hace falta el cast explícito
-- `e.job_title::text`. Si otra función se convierte de sql a plpgsql más
-- adelante, revisar esto mismo.
-- =====================================================================

create or replace function public.assignable_staff()
returns table(person_id uuid, full_name text, job_title text)
language plpgsql
stable security definer
set search_path to 'public'
as $function$
begin
  if public.current_user_role() not in
     ('root', 'accountant', 'reception', 'reception_admin', 'owner') then
    raise exception 'No autorizado';
  end if;

  return query
  select e.person_id,
         (p.first_name || ' ' || p.last_name) as full_name,
         e.job_title::text
  from public.employees e
  join public.people p on p.id = e.person_id
  where e.status = 'active'
  order by full_name;
end;
$function$;

create or replace function public.check_in_reservation_with_guests(
  p_reservation_id uuid, p_document text, p_birth_date date, p_country_code text,
  p_city text, p_wants_offers boolean, p_origin_city text default null::text,
  p_travel_purpose text default null::text, p_occupation text default null::text,
  p_transport_means text default null::text, p_companions jsonb default '[]'::jsonb,
  p_agency_name text default null::text, p_channel_code text default null::text,
  p_holder_first_name text default null::text, p_holder_last_name text default null::text,
  p_holder_person_id uuid default null::uuid, p_occupancy_reason text default null::text,
  p_email text default null::text
)
returns void
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

create or replace function public.walk_in_check_in_with_guests(
  p_room_id uuid, p_room_type_id uuid, p_first_name text, p_last_name text,
  p_document text, p_email text, p_birth_date date, p_country_code text, p_city text,
  p_wants_offers boolean, p_nights integer, p_rate_bs numeric default null::numeric,
  p_rate_reason text default null::text, p_origin_city text default null::text,
  p_travel_purpose text default null::text, p_occupation text default null::text,
  p_transport_means text default null::text, p_companions jsonb default '[]'::jsonb,
  p_agency_name text default null::text, p_channel_code text default null::text,
  p_occupancy_reason text default null::text
)
returns uuid
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

-- ---------------------------------------------------------------------
-- AL AGREGAR UNA RPC PÚBLICA SECURITY DEFINER NUEVA: agregale el guard de
-- rol como primera sentencia (mirá a quién la va a llamar src/ antes de
-- elegir la lista, no copies la de la más parecida sin verificar), y
-- agregala a la lista blanca de 21_function_grants_allowlist.sql. Si te
-- olvidás del guard, 22_guard_public_security_definer_rpcs.sql la va a
-- nombrar.
-- ---------------------------------------------------------------------
