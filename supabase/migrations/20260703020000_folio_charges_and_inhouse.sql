-- =====================================================================
-- FASE 5c — Consumos al folio + vista de hospedados (in-house).
-- =====================================================================

-- ---------- FOLIO_CHARGES (consumos cargados a la cuenta) ----------
create table if not exists public.folio_charges (
  id          uuid primary key default gen_random_uuid(),
  folio_id    uuid not null references public.folios(id) on delete cascade,
  description text not null,           -- 'Minibar', 'Spa', 'Restaurante'
  amount_bs   numeric(10,2) not null check (amount_bs >= 0),
  created_at  timestamptz not null default now()
);
alter table public.folio_charges enable row level security;
create policy "dev_all_folio_charges"
  on public.folio_charges for all using (true) with check (true);

-- =====================================================================
-- FUNCIÓN: agregar un consumo al folio de la habitación ocupada.
-- Valida que exista una estadía activa (checked_in).
-- =====================================================================
create or replace function public.add_folio_charge(
  p_room_id     uuid,
  p_description text,
  p_amount      numeric
) returns uuid
language plpgsql
as $$
declare
  v_folio_id uuid;
  v_charge_id uuid;
begin
  if p_amount is null or p_amount < 0 then
    raise exception 'El monto debe ser mayor o igual a 0';
  end if;
  if nullif(trim(p_description), '') is null then
    raise exception 'La descripción es obligatoria';
  end if;

  select f.id into v_folio_id
  from public.folios f
  join public.reservations r on r.id = f.reservation_id
  where r.room_id = p_room_id and r.status = 'checked_in'
  order by r.check_in_date desc
  limit 1;

  if v_folio_id is null then
    raise exception 'No hay una estadía activa en esta habitación';
  end if;

  insert into public.folio_charges (folio_id, description, amount_bs)
  values (v_folio_id, trim(p_description), p_amount)
  returning id into v_charge_id;

  return v_charge_id;
end;
$$;

-- =====================================================================
-- Actualizamos el CHECK-OUT: el total ahora suma habitación + consumos.
-- =====================================================================
create or replace function public.check_out_room(p_room_id uuid)
returns numeric
language plpgsql
as $$
declare
  v_reservation_id uuid;
  v_room_total     numeric(10,2);
  v_extras         numeric(10,2);
  v_status         varchar(15);
begin
  select operational_status into v_status
  from public.rooms where id = p_room_id for update;
  if v_status <> 'occupied' then
    raise exception 'La habitación no está ocupada (estado actual: %)', coalesce(v_status, 'inexistente');
  end if;

  select id, total_amount_bs into v_reservation_id, v_room_total
  from public.reservations
  where room_id = p_room_id and status = 'checked_in'
  order by check_in_date desc
  limit 1;

  if v_reservation_id is null then
    raise exception 'No hay una reserva activa para esta habitación';
  end if;

  -- Suma de consumos del folio.
  select coalesce(sum(fc.amount_bs), 0) into v_extras
  from public.folio_charges fc
  join public.folios f on f.id = fc.folio_id
  where f.reservation_id = v_reservation_id;

  update public.reservations set status = 'checked_out' where id = v_reservation_id;
  update public.folios set closed_at = now() where reservation_id = v_reservation_id;
  update public.rooms set operational_status = 'dirty' where id = p_room_id;

  return coalesce(v_room_total, 0) + v_extras;
end;
$$;

-- =====================================================================
-- VISTA: hospedados actualmente (in-house).
-- Una VISTA es un "read model": aplana el JOIN de 4 tablas en una
-- consulta simple que el frontend usa como si fuera una tabla.
-- security_invoker => respeta las políticas RLS de las tablas base.
-- =====================================================================
create or replace view public.in_house
with (security_invoker = on) as
select
  r.id            as reservation_id,
  rm.id           as room_id,
  rm.room_number,
  rm.floor,
  rm.zone,
  rt.name         as room_type,
  p.first_name,
  p.last_name,
  p.email,
  g.country_code,
  g.city,
  r.check_in_date,
  r.check_out_date,
  r.total_amount_bs as room_total_bs
from public.reservations r
join public.rooms       rm on rm.id = r.room_id
join public.room_types  rt on rt.id = r.room_type_id
join public.guests      g  on g.person_id = r.guest_id
join public.people      p  on p.id = g.person_id
where r.status = 'checked_in';

-- Permisos (guardado para local).
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant execute on function public.add_folio_charge(uuid,text,numeric) to anon, authenticated;
    grant select on public.in_house to anon, authenticated;
  end if;
end$$;
