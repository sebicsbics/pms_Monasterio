-- =====================================================================
-- Check-in: confirmed_at + titular obligatorio. (change:
-- reservation-booker-vs-guest, PR2b-db, 5/8, 1 de 2).
--
-- POR QUÉ
-- PR2a dejó `guest_id` nullable y las rutas de ALTA (create_reservation,
-- create_bulk_reservation) armando booking + holder a mano. Esta migración
-- cierra el círculo del lado del CHECK-IN (la unificación de las rutas de
-- ALTA -- walk-in, create_reservation, drop de los triggers de respaldo de
-- PR1 -- va en la migración siguiente, 20260911030000, para no mezclar dos
-- cambios de comportamiento distintos en un solo commit):
--
--   1) `reservation_guests.confirmed_at`: un huésped precargado (listado
--      antes de llegar) queda con confirmed_at NULL hasta que se presenta;
--      el check-in lo confirma (set now()), nunca lo vuelve a insertar.
--   2) `check_in_reservation_with_guests` ahora EXIGE un titular resuelto:
--      si `guest_id` ya venía seteado (contacto-titular o titular
--      precargado en bulk), listo, sólo se confirma. Si no, hay que
--      indicar un huésped precargado (p_holder_person_id) o datos nuevos
--      (p_holder_first_name/p_holder_last_name); sin ninguno de los dos,
--      se rechaza el check-in.
--   3) add_reservation_companions/add_guests_to_stay: los acompañantes que
--      se registran en el check-in (nuevos o precargados) quedan con
--      role='companion', confirmed_at = now().
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) confirmed_at: NULL = precargado, aún no se presentó. Se confirma en
--    el check-in (nunca se re-inserta la fila).
-- ---------------------------------------------------------------------
alter table public.reservation_guests add column confirmed_at timestamptz;

comment on column public.reservation_guests.confirmed_at is
  'NULL = huésped precargado (listado antes de llegar), aún no se '
  'presentó. Se setea en el check-in (nunca se re-inserta la fila). Ver '
  '20260911020000.';

-- Estadías ya en curso o cerradas: se asume que todos sus huéspedes ya
-- pasaron por el check-in, aunque haya sido antes de que existiera esta
-- columna -- se backfillea a su created_at (mejor aproximación posible).
update public.reservation_guests rg
  set confirmed_at = rg.created_at
  from public.reservations r
  where r.id = rg.reservation_id
    and r.status in ('checked_in', 'checked_out')
    and rg.confirmed_at is null;

-- ---------------------------------------------------------------------
-- 2) add_reservation_companions: acompañantes registrados en el
--    check-in (nuevos o dedupeados por documento) quedan confirmados
--    ahora mismo. Misma aridad -> CREATE OR REPLACE alcanza, pero se
--    re-aplica higiene de grants (regla de la tarea, aunque no cambie de
--    firma).
-- ---------------------------------------------------------------------
create or replace function public.add_reservation_companions(
  p_reservation_id uuid,
  p_companions     jsonb
) returns void
language plpgsql
security definer
set search_path = public
as $$
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
      update public.guests set
        country_code    = coalesce(nullif(c->>'country_code', ''), country_code),
        city            = coalesce(nullif(c->>'city', ''), city),
        origin_city     = coalesce(nullif(c->>'origin_city', ''), origin_city),
        travel_purpose  = coalesce(nullif(c->>'travel_purpose', ''), travel_purpose),
        occupation      = coalesce(nullif(c->>'occupation', ''), occupation),
        transport_means = coalesce(nullif(c->>'transport_means', ''), transport_means),
        is_minor        = v_minor
      where person_id = v_person;
    else
      insert into public.people (first_name, last_name, birth_date)
      values (
        trim(c->>'first_name'), trim(c->>'last_name'),
        nullif(c->>'birth_date', '')::date
      )
      returning id into v_person;
      insert into public.guests (
        person_id, passport_number, country_code, city,
        origin_city, travel_purpose, occupation, transport_means, is_minor
      )
      values (
        v_person, v_doc,
        nullif(c->>'country_code', ''), nullif(c->>'city', ''),
        nullif(c->>'origin_city', ''), nullif(c->>'travel_purpose', ''),
        nullif(c->>'occupation', ''), nullif(c->>'transport_means', ''), v_minor
      );
    end if;

    -- role='companion': el titular NUNCA pasa por acá (lo resuelve
    -- check_in_reservation_with_guests antes de llamar a esta función).
    -- confirmed_at = now(): se está registrando porque se presentó.
    insert into public.reservation_guests (reservation_id, person_id, role, confirmed_at)
    values (p_reservation_id, v_person, 'companion', now())
    on conflict (reservation_id, person_id)
      do update set confirmed_at = now()
      where public.reservation_guests.role <> 'holder';
  end loop;
end;
$$;

revoke execute on function public.add_reservation_companions(uuid, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3) add_guests_to_stay: mismo cuerpo (delega en add_reservation_companions,
--    que ya confirma), pero nunca había sido revocada de public/anon ->
--    se corrige acá vía CREATE OR REPLACE + revoke explícito.
-- ---------------------------------------------------------------------
create or replace function public.add_guests_to_stay(
  p_room_id            uuid,
  p_companions         jsonb,
  p_extra_charge_bs    numeric default 0,
  p_charge_description text default null
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
    raise exception 'La habitación admite % huésped(es); quedarían %',
      v_max_occ, v_total;
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

revoke execute on function public.add_guests_to_stay(uuid, jsonb, numeric, text) from public, anon;
grant execute on function public.add_guests_to_stay(uuid, jsonb, numeric, text) to authenticated;

-- ---------------------------------------------------------------------
-- 4) check_in_reservation_with_guests: agrega p_holder_first_name,
--    p_holder_last_name, p_holder_person_id (todos opcionales, al final
--    -> cambia la aridad, DROP de la firma vigente primero).
--
--    Resolución del titular (en orden):
--      a) guest_id ya seteado (contacto-titular o precargado en bulk) ->
--         sólo se confirma (confirmed_at = now()), NO se reescribe.
--      b) p_holder_person_id: un huésped YA precargado para esta reserva
--         (reservation_guests sin role='holder' todavía) se promueve a
--         titular -- su propia fila, nunca la del contacto.
--      c) p_holder_first_name/p_holder_last_name: titular nuevo, se crea
--         people/guests para él.
--      Si ninguna de las 3 resuelve un titular -> rechazo.
-- ---------------------------------------------------------------------
drop function if exists public.check_in_reservation_with_guests(
  uuid, text, date, text, text, boolean, text, text, text, text, jsonb, text, text
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
  p_holder_person_id  uuid default null
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
    raise exception 'La habitación admite % huésped(es); estás registrando %',
      v_max_occ, v_total;
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
  text, text, uuid
) from public, anon;

grant execute on function public.check_in_reservation_with_guests(
  uuid, text, date, text, text, boolean, text, text, text, text, jsonb, text, text,
  text, text, uuid
) to authenticated;

