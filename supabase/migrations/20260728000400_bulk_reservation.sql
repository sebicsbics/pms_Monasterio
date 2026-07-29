-- =====================================================================
-- Reservas en bulk (change: bulk-reservation).
--
-- Un grupo llena varias habitaciones en las mismas fechas. En vez de crear
-- las reservas una por una, se crean todas de un saque con UN contacto de
-- grupo (organizador). Los datos de cada huésped se completan en el
-- check-in (multi-huésped ya soportado).
--
-- Best-effort por habitación: cada inserción va en su propio savepoint
-- (begin/exception), así una habitación que se ocupó en el medio se saltea
-- y se reporta, sin voltear todo el grupo. Reusa apply_rate_change para la
-- tarifa (mismo workflow de descuentos que create_reservation).
--
-- Devuelve jsonb: { created: [reservation_id...], failed: [{room_id, error}...] }.
-- =====================================================================

create or replace function public.create_bulk_reservation(
  p_rooms      jsonb,     -- [{ room_id, room_type_id }]
  p_first_name text,
  p_last_name  text,
  p_phone      text,
  p_email      text,
  p_check_in   date,
  p_check_out  date,
  p_num_guests int,
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
  v_rate           numeric(10,2);
  v_max_occ        int;
  v_reservation_id uuid;
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
    begin
      select rt.base_price_bs, rt.max_occupancy into v_rate, v_max_occ
      from public.room_type_options o
      join public.room_types rt on rt.id = o.room_type_id
      where o.room_id = v_room_id and o.room_type_id = v_room_type_id;

      if v_rate is null then
        raise exception 'El tipo seleccionado no corresponde a la habitación';
      end if;
      if v_max_occ < p_num_guests then
        raise exception 'El tipo admite hasta % personas', v_max_occ;
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
        p_method, 'pending', v_rate * v_nights, 'confirmed', p_num_guests
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

      v_created := v_created || to_jsonb(v_reservation_id::text);
    exception when others then
      v_failed := v_failed || jsonb_build_object('room_id', v_room_id, 'error', sqlerrm);
    end;
  end loop;

  return jsonb_build_object('created', v_created, 'failed', v_failed);
end;
$$;

grant execute on function public.create_bulk_reservation(
  jsonb, text, text, text, text, date, date, int, text, numeric, text
) to authenticated;
