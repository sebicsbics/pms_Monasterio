-- =====================================================================
-- Rutas de alta + guest_id nullable + arrivals() (change:
-- reservation-booker-vs-guest, PR2a-db, 2/6).
--
-- POR QUÉ
-- `reservations.guest_id` hoy es NOT NULL y siempre apunta al contacto
-- que reservó, aunque ese contacto no se aloje (el bug de origen). Esta
-- migración:
--   1) vuelve `guest_id` nullable -- "titular una vez conocido", nunca
--      un contacto que no se aloja;
--   2) reescribe `create_reservation` con el toggle `p_contact_stays`
--      (default true, para no romper la UI actual);
--   3) reescribe `create_bulk_reservation` para aceptar `occupants` por
--      habitación (el organizador ya NO es titular automático de nada);
--   4) reescribe `arrivals()` para leer el contacto desde `bookings` en
--      vez de `guests`/`people` vía guest_id, y tolerar guest_id NULL.
--
-- Ambas RPC ahora arman la booking A MANO (una por llamada), así que el
-- trigger `_create_booking_for_new_reservation` de PR1 no actúa acá (sólo
-- actúa si booking_id viene NULL -- sigue siendo necesario para
-- walk_in_check_in_with_guests, que no cambia hasta PR2b).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) guest_id nullable.
-- ---------------------------------------------------------------------
alter table public.reservations alter column guest_id drop not null;

-- ---------------------------------------------------------------------
-- 2) _create_holder_for_new_reservation: no insertar holder cuando el
--    insert directo (walk-in, seed) dejó guest_id NULL -- insertar con
--    person_id NULL violaría el NOT NULL de reservation_guests.person_id.
--    Hoy ningún camino vivo inserta guest_id NULL directo (walk-in
--    siempre lo setea), pero de acá en más es posible, así que el
--    trigger tiene que tolerarlo.
-- ---------------------------------------------------------------------
create or replace function public._create_holder_for_new_reservation()
returns trigger
language plpgsql
as $$
begin
  if new.guest_id is null then
    return new;
  end if;

  insert into public.reservation_guests (reservation_id, person_id, role)
  select new.id, new.guest_id, 'holder'
  where not exists (
    select 1 from public.reservation_guests rg
    where rg.reservation_id = new.id and rg.role = 'holder'
  );
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- 3) create_reservation: agrega p_contact_stays (default true). Cambia
--    la aridad -> hay que dropear la firma de 12 args antes de crear la
--    de 13 (mismo overload trap documentado en varias migraciones
--    previas).
-- ---------------------------------------------------------------------
drop function if exists public.create_reservation(
  uuid, uuid, text, text, text, text, date, date, int, text, numeric, text
);

create or replace function public.create_reservation(
  p_room_id       uuid,
  p_room_type_id  uuid,
  p_first_name    text,
  p_last_name     text,
  p_phone         text,
  p_email         text,
  p_check_in      date,
  p_check_out     date,
  p_num_guests    int,
  p_method        text,
  p_rate_bs       numeric default null,
  p_reason        text default null,
  p_contact_stays boolean default true
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_person_id      uuid;
  v_booking_id     uuid;
  v_guest_id       uuid;
  v_reservation_id uuid;
  v_rate           numeric(10,2);
  v_max_occ        int;
  v_nights         int;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado para crear reservas';
  end if;

  if p_check_out <= p_check_in then
    raise exception 'La fecha de salida debe ser posterior a la de entrada';
  end if;
  if p_num_guests < 1 then
    raise exception 'Debe haber al menos 1 persona';
  end if;
  -- Sin contacto la reserva es inútil.
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

  -- Bloqueo pesimista + revalidación de disponibilidad (anti-overbooking).
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

  -- Contacto (quien reserva/responde): dedupe por email, igual que antes.
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

  -- Booking: 1 por llamada, contacto = quien reservó.
  insert into public.bookings (contact_person_id) values (v_person_id)
  returning id into v_booking_id;

  -- Titular: sólo si el contacto se aloja (toggle). Nunca se fuerza a
  -- alguien que no se hospeda a ser huésped.
  if p_contact_stays then
    insert into public.guests (person_id) values (v_person_id)
      on conflict (person_id) do nothing;
    v_guest_id := v_person_id;
  else
    v_guest_id := null;
  end if;

  v_nights := p_check_out - p_check_in;

  -- Insertar SIEMPRE al precio de lista; el descuento (si lo hay) se
  -- aplica después vía apply_rate_change, para que la reserva se cree
  -- igual aunque el descuento quede pendiente de aprobación.
  insert into public.reservations (
    guest_id, room_id, room_type_id, check_in_date, check_out_date,
    reservation_method, payment_status, total_amount_bs, status, num_guests,
    booking_id
  ) values (
    v_guest_id, p_room_id, p_room_type_id, p_check_in, p_check_out,
    p_method, 'pending', v_rate * v_nights, 'confirmed', p_num_guests,
    v_booking_id
  ) returning id into v_reservation_id;

  -- El holder lo inserta el trigger reservations_create_holder (PR1)
  -- automáticamente a partir de NEW.guest_id -- no hace falta insertarlo
  -- acá también (duplicaría la fila y violaría el índice de titular
  -- único). Sólo cuando guest_id queda NULL (toggle OFF) el trigger no
  -- hace nada, que es justo lo que se quiere.

  if p_rate_bs is not null and p_rate_bs <> v_rate then
    if p_reason is null or char_length(trim(p_reason)) = 0 then
      raise exception 'La justificación es obligatoria para cambiar la tarifa';
    end if;
    if p_rate_bs <= 0 then
      raise exception 'La tarifa debe ser un monto positivo';
    end if;
    perform public.apply_rate_change(
      v_reservation_id, p_room_type_id, v_rate, v_nights, p_rate_bs, p_reason
    );
  end if;

  return v_reservation_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 4) create_bulk_reservation: acepta `occupants` opcional por
--    habitación ([{first_name,last_name,document?,birth_date?}, ...],
--    el primero = titular, el resto = acompañantes). Sin occupants ->
--    guest_id NULL, sin holder. Misma aridad que antes (occupants viaja
--    DENTRO de cada elemento de p_rooms) -> CREATE OR REPLACE alcanza.
-- ---------------------------------------------------------------------
create or replace function public.create_bulk_reservation(
  p_rooms      jsonb,     -- [{ room_id, room_type_id, num_guests, occupants? }]
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

  -- Organizador del grupo: se crea/deduplica UNA vez (dedupe por email).
  -- Ya NO se convierte automáticamente en huésped/titular de nada -- eso
  -- se decide por habitación, vía `occupants`.
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

  -- Una sola booking para todo el grupo -- todas las habitaciones del
  -- llamado comparten "quién reserva/responde".
  insert into public.bookings (contact_person_id) values (v_person_id)
  returning id into v_booking_id;

  -- Una reserva por habitación, cada una en su savepoint.
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

      select rt.base_price_bs into v_rate
      from public.room_type_options o
      join public.room_types rt on rt.id = o.room_type_id
      where o.room_id = v_room_id and o.room_type_id = v_room_type_id;

      if v_rate is null then
        raise exception 'El tipo seleccionado no corresponde a la habitación';
      end if;

      -- Bloqueo + revalidación de disponibilidad (anti-overbooking).
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

      -- guest_id arranca NULL: recién se sabe si hay titular después de
      -- procesar `occupants` (el trigger de holder no hace nada con NULL).
      insert into public.reservations (
        guest_id, room_id, room_type_id, check_in_date, check_out_date,
        reservation_method, payment_status, total_amount_bs, status, num_guests,
        booking_id
      ) values (
        null, v_room_id, v_room_type_id, p_check_in, p_check_out,
        p_method, 'pending', v_rate * v_nights, 'confirmed', v_guests,
        v_booking_id
      ) returning id into v_reservation_id;

      -- Occupants precargados: el primero es el titular, el resto
      -- acompañantes. Dedupe por documento, igual que
      -- add_reservation_companions (20260727000300). Sin occupants (o
      -- array vacío), la reserva queda con guest_id NULL y sin holder.
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
          insert into public.reservation_guests (reservation_id, person_id, role)
          values (v_reservation_id, v_occ_person, 'holder')
          on conflict (reservation_id, person_id) do update set role = 'holder';
          v_is_first := false;
        else
          insert into public.reservation_guests (reservation_id, person_id, role)
          values (v_reservation_id, v_occ_person, 'companion')
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

      -- El tramo inicial lo crea el trigger sync_single_stay_segment
      -- (20260805030000_stay_segments.sql), que corre para TODO camino
      -- que inserte una reserva -- incluido apply_rate_change.

      v_created := v_created || to_jsonb(v_reservation_id::text);
    exception when others then
      v_failed := v_failed || jsonb_build_object('room_id', v_room_id, 'error', sqlerrm);
    end;
  end loop;

  return jsonb_build_object('created', v_created, 'failed', v_failed);
end;
$$;

-- ---------------------------------------------------------------------
-- 5) arrivals(): el contacto ya no sale de guests/people vía guest_id
--    (que ahora puede ser NULL) sino de bookings->people. Se agregan
--    holder_first_name/holder_last_name (nullable, LEFT JOIN sobre
--    guest_id) para que la UI pueda distinguir "quién ocupa" de "quién
--    reserva" sin otro viaje al servidor. Cambia el tipo de retorno ->
--    drop previo (misma técnica que 20260805000000:250).
-- ---------------------------------------------------------------------
drop function if exists public.arrivals(date, date);

create or replace function public.arrivals(p_from date, p_to date)
returns table (
  reservation_id    uuid,
  room_id           uuid,
  room_number       text,
  room_type         text,
  first_name        text,
  last_name         text,
  phone             text,
  email             text,
  check_in_date     date,
  check_out_date    date,
  num_guests        int,
  max_occupancy     int,
  method            text,
  anticipo_total_bs numeric,
  holder_first_name text,
  holder_last_name  text
)
language sql
stable
security invoker
set search_path = public
as $$
  select
    r.id, rm.id, rm.room_number::text, rt.name::text,
    p.first_name::text, p.last_name::text, p.phone::text, p.email::text,
    r.check_in_date, r.check_out_date, r.num_guests, rt.max_occupancy,
    r.reservation_method::text,
    coalesce((
      select sum(a.amount_bs) from public.anticipos a
      where a.reservation_id = r.id and a.status = 'active'
    ), 0),
    hp.first_name::text, hp.last_name::text
  from public.reservations r
  join public.rooms      rm on rm.id = r.room_id
  join public.room_types rt on rt.id = r.room_type_id
  join public.bookings   b  on b.id = r.booking_id
  join public.people     p  on p.id = b.contact_person_id
  left join public.people hp on hp.id = r.guest_id
  where r.status = 'confirmed'
    and r.check_in_date <= p_to
    and (p_from is null or r.check_in_date >= p_from)
  order by r.check_in_date, rm.room_number::int;
$$;

-- ---------------------------------------------------------------------
-- 6) Higiene de grants -- toda función creada/re-creada acá (regla del
--    tasks artifact): revoke de public/anon, grant explícito sólo a
--    authenticated. arrivals() PERDÍA acceso de anon respecto de la
--    versión previa (20260805000000 la otorgaba condicionalmente) -- ya
--    no corresponde: expone PII de contacto/huésped, y todo el resto del
--    negocio (20260829010000) ya cerró ese acceso. Los 3 helpers
--    internos de PR1 (_run_booking_backfill,
--    _create_booking_for_new_reservation,
--    _create_holder_for_new_reservation) también se revocan de
--    authenticated: son de uso interno (migración/triggers), nunca
--    llamadas directas de la app.
-- ---------------------------------------------------------------------
revoke execute on function public.create_reservation(
  uuid, uuid, text, text, text, text, date, date, int, text, numeric, text, boolean
) from public, anon;
grant execute on function public.create_reservation(
  uuid, uuid, text, text, text, text, date, date, int, text, numeric, text, boolean
) to authenticated;

revoke execute on function public.create_bulk_reservation(
  jsonb, text, text, text, text, date, date, text, numeric, text
) from public, anon;
grant execute on function public.create_bulk_reservation(
  jsonb, text, text, text, text, date, date, text, numeric, text
) to authenticated;

revoke execute on function public.arrivals(date, date) from public, anon;
grant execute on function public.arrivals(date, date) to authenticated;

revoke execute on function public._run_booking_backfill() from public, anon, authenticated;
revoke execute on function public._create_booking_for_new_reservation() from public, anon, authenticated;
revoke execute on function public._create_holder_for_new_reservation() from public, anon, authenticated;
