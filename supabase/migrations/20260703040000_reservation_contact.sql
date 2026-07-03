-- =====================================================================
-- FASE 4b — Reserva mínima con contacto (celular/correo).
-- El perfil completo del huésped se toma en el check-in, no al reservar.
-- =====================================================================

-- Celular / teléfono de contacto (no existía). Aditivo, seguro para la web.
alter table public.people add column if not exists phone varchar(30);

-- Reemplazamos create_reservation por la versión mínima con contacto.
drop function if exists public.create_reservation(
  uuid, uuid, text, text, text, text, date, text, text, boolean, date, date, int, text
);

create or replace function public.create_reservation(
  p_room_id      uuid,
  p_room_type_id uuid,
  p_first_name   text,
  p_last_name    text,
  p_phone        text,
  p_email        text,
  p_check_in     date,
  p_check_out    date,
  p_num_guests   int,
  p_method       text
) returns uuid
language plpgsql
as $$
declare
  v_person_id      uuid;
  v_reservation_id uuid;
  v_rate           numeric(10,2);
  v_max_occ        int;
  v_nights         int;
begin
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

  -- Deduplicación por email (si lo dieron); si no, huésped nuevo.
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

  v_nights := p_check_out - p_check_in;

  insert into public.reservations (
    guest_id, room_id, room_type_id, check_in_date, check_out_date,
    reservation_method, payment_status, total_amount_bs, status, num_guests
  ) values (
    v_person_id, p_room_id, p_room_type_id, p_check_in, p_check_out,
    p_method, 'pending', v_rate * v_nights, 'confirmed', p_num_guests
  ) returning id into v_reservation_id;

  return v_reservation_id;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant execute on function public.create_reservation(uuid,uuid,text,text,text,text,date,date,int,text)
      to anon, authenticated;
  end if;
end$$;
