-- =====================================================================
-- Reservas en bulk: huéspedes POR habitación, con camas extras.
-- (change: bulk-guests-per-room)
--
-- Antes se pedía "personas / habitación": un solo número que se aplicaba a
-- TODAS las habitaciones del grupo y que además filtraba la búsqueda por
-- capacidad. No describe la realidad — en un grupo de 9, entran 4 en una
-- cuádruple, 3 en una triple y 2 en una matrimonial.
--
-- Ahora cada habitación del payload trae su propio `num_guests`, y el
-- total del grupo es la suma (lo calcula la UI, no hace falta mandarlo).
--
-- CAMBIO DE REGLA: la ocupación ya NO es un tope duro. El hotel habilita
-- camas extras cuando se llena, así que meter 5 personas en una cuádruple
-- es una decisión legítima de recepción, no un error a bloquear. Se
-- conserva `room_types.max_occupancy` como referencia (la UI la muestra
-- para que se vea cuándo se está excediendo), pero la RPC ya no la usa
-- para rechazar. Un tope de sanidad (20) evita el dedazo de tipear 40.
--
-- También se saca la reserva del check-in multi-huésped: el tope real
-- ahí sigue siendo max_occupancy porque es otro flujo (ver
-- 20260805000000_stay_guests_and_add_guest.sql).
-- =====================================================================

-- Cambia la aridad (se va p_num_guests, ahora viaja dentro de p_rooms):
-- hay que dropear la firma vieja o la llamada por nombre queda ambigua.
drop function if exists public.create_bulk_reservation(
  jsonb, text, text, text, text, date, date, int, text, numeric, text
);

create or replace function public.create_bulk_reservation(
  p_rooms      jsonb,     -- [{ room_id, room_type_id, num_guests }]
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
  v_nights         int;
  v_created        jsonb := '[]'::jsonb;
  v_failed         jsonb := '[]'::jsonb;
  elem             jsonb;
  v_room_id        uuid;
  v_room_type_id   uuid;
  v_guests         int;
  v_rate           numeric(10,2);
  v_reservation_id uuid;
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
  if nullif(p_email, '') is not null then
    select id into v_person_id from public.people where email = p_email;
  end if;

  if v_person_id is not null then
    update public.people set
      first_name = p_first_name,
      last_name  = p_last_name,
      phone      = coalesce(nullif(p_phone, ''), phone)
    where id = v_person_id;
    insert into public.guests (person_id) values (v_person_id)
      on conflict (person_id) do nothing;
  else
    insert into public.people (first_name, last_name, email, phone)
    values (p_first_name, p_last_name, nullif(p_email, ''), nullif(p_phone, ''))
    returning id into v_person_id;
    insert into public.guests (person_id) values (v_person_id);
  end if;

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

      insert into public.reservations (
        guest_id, room_id, room_type_id, check_in_date, check_out_date,
        reservation_method, payment_status, total_amount_bs, status, num_guests
      ) values (
        v_person_id, v_room_id, v_room_type_id, p_check_in, p_check_out,
        p_method, 'pending', v_rate * v_nights, 'confirmed', v_guests
      ) returning id into v_reservation_id;

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
      -- (20260805030000_stay_segments.sql), que corre para TODO camino que
      -- inserte una reserva — incluido apply_rate_change, que ajusta el
      -- total después de este insert.

      v_created := v_created || to_jsonb(v_reservation_id::text);
    exception when others then
      v_failed := v_failed || jsonb_build_object('room_id', v_room_id, 'error', sqlerrm);
    end;
  end loop;

  return jsonb_build_object('created', v_created, 'failed', v_failed);
end;
$$;

grant execute on function public.create_bulk_reservation(
  jsonb, text, text, text, text, date, date, text, numeric, text
) to authenticated;
