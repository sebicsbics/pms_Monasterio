-- =====================================================================
-- FASE 5 — Walk-in: folios + funciones atómicas de check-in / check-out.
-- =====================================================================

-- Los walk-ins pueden no dar email: lo hacemos opcional (seguro para la web,
-- que igual sigue enviando email en sus reservas online).
alter table public.people alter column email drop not null;

-- ---------- FOLIOS (cuenta del huésped) ----------
create table if not exists public.folios (
  id             uuid primary key default gen_random_uuid(),
  reservation_id uuid not null unique references public.reservations(id) on delete cascade,
  opened_at      timestamptz not null default now(),
  closed_at      timestamptz
);
alter table public.folios enable row level security;
create policy "dev_all_folios" on public.folios for all using (true) with check (true);

-- =====================================================================
-- FUNCIÓN: check-in de walk-in (ATÓMICA).
-- Crea persona + huésped + reserva + folio y ocupa la habitación,
-- todo en una transacción. Bloquea la fila de la habitación (FOR UPDATE)
-- para impedir doble ocupación concurrente.
-- =====================================================================
create or replace function public.walk_in_check_in(
  p_room_id      uuid,
  p_room_type_id uuid,
  p_first_name   text,
  p_last_name    text,
  p_document     text,
  p_nights       int
) returns uuid
language plpgsql
as $$
declare
  v_person_id      uuid;
  v_reservation_id uuid;
  v_rate           numeric(10,2);
  v_status         varchar(15);
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

  -- El tipo elegido debe ser una opción válida de esa habitación.
  if not exists (
    select 1 from public.room_type_options
    where room_id = p_room_id and room_type_id = p_room_type_id
  ) then
    raise exception 'El tipo seleccionado no corresponde a esta habitación';
  end if;

  select base_price_bs into v_rate
  from public.room_types where id = p_room_type_id;

  -- Persona + huésped
  insert into public.people (first_name, last_name)
  values (p_first_name, p_last_name)
  returning id into v_person_id;

  insert into public.guests (person_id, passport_number)
  values (v_person_id, nullif(p_document, ''));

  -- Reserva ya en checked_in (el walk-in entra en el acto)
  insert into public.reservations (
    guest_id, room_id, room_type_id, check_in_date, check_out_date,
    reservation_method, payment_status, total_amount_bs, status
  ) values (
    v_person_id, p_room_id, p_room_type_id, current_date, current_date + p_nights,
    'walk-in', 'pending', v_rate * p_nights, 'checked_in'
  ) returning id into v_reservation_id;

  -- Folio abierto
  insert into public.folios (reservation_id) values (v_reservation_id);

  -- Ocupar la habitación
  update public.rooms set operational_status = 'occupied' where id = p_room_id;

  return v_reservation_id;
end;
$$;

-- =====================================================================
-- FUNCIÓN: check-out (ATÓMICA).
-- Cierra la reserva activa, cierra el folio, deja la habitación 'dirty'
-- y devuelve el total a cobrar.
-- =====================================================================
create or replace function public.check_out_room(p_room_id uuid)
returns numeric
language plpgsql
as $$
declare
  v_reservation_id uuid;
  v_total          numeric(10,2);
  v_status         varchar(15);
begin
  select operational_status into v_status
  from public.rooms where id = p_room_id for update;

  if v_status <> 'occupied' then
    raise exception 'La habitación no está ocupada (estado actual: %)', coalesce(v_status, 'inexistente');
  end if;

  select id, total_amount_bs into v_reservation_id, v_total
  from public.reservations
  where room_id = p_room_id and status = 'checked_in'
  order by check_in_date desc
  limit 1;

  if v_reservation_id is null then
    raise exception 'No hay una reserva activa para esta habitación';
  end if;

  update public.reservations set status = 'checked_out' where id = v_reservation_id;
  update public.folios set closed_at = now() where reservation_id = v_reservation_id;
  update public.rooms set operational_status = 'dirty' where id = p_room_id;

  return coalesce(v_total, 0);
end;
$$;

-- Permitir ejecutar las funciones desde el cliente (roles de Supabase).
-- Guardado: en local esos roles no existen, así que se salta sin fallar.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant execute on function public.walk_in_check_in(uuid,uuid,text,text,text,int)
      to anon, authenticated;
    grant execute on function public.check_out_room(uuid)
      to anon, authenticated;
  end if;
end$$;
