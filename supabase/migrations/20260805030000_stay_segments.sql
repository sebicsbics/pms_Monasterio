-- =====================================================================
-- Tramos de estadía: extender noches y cambiar de habitación.
-- (change: stay-segments)
--
-- EL PROBLEMA DE MODELO
-- Hasta ahora la plata de una estadía es UN escalar,
-- `reservations.total_amount_bs`. Ese modelo no puede expresar
-- "3 noches en la 101 a 350 + 2 noches en la 205 a 500", que es
-- exactamente lo que hay que registrar cuando el huésped cambia de
-- habitación a mitad de estadía.
--
-- LA DECISIÓN
-- Se agrega `stay_segments`: un tramo por (habitación, tarifa, rango de
-- fechas). `total_amount_bs` NO se elimina — sigue siendo el total
-- autoritativo que leen el check-out, el folio y la analítica, pero pasa a
-- mantenerse como la SUMA de los tramos. Así el detalle nuevo no obliga a
-- reescribir media aplicación, y las reservas históricas (sin tramos)
-- siguen funcionando con el total de siempre.
--
-- Invariante: si una reserva tiene tramos, total_amount_bs = sum(noches *
-- rate_bs). Lo garantizan las RPC de abajo (recalc_reservation_total);
-- ninguna pantalla escribe tramos directo.
--
-- Rango [start_date, end_date): mismo criterio que ya usa el resto del
-- sistema para solapamiento de reservas. Noches = end - start.
-- =====================================================================

create table if not exists public.stay_segments (
  id             uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  room_id        uuid not null references public.rooms(id),
  room_type_id   uuid not null references public.room_types(id),
  rate_bs        numeric(10,2) not null check (rate_bs >= 0),
  start_date     date not null,
  end_date       date not null,
  reason         text,
  created_by     uuid references public.profiles(id) default auth.uid(),
  created_at     timestamptz not null default now(),
  check (end_date > start_date)
);

create index if not exists idx_stay_segments_reservation
  on public.stay_segments (reservation_id, start_date);

alter table public.stay_segments enable row level security;

drop policy if exists "stay_segments_read" on public.stay_segments;
create policy "stay_segments_read" on public.stay_segments
  for select using (
    public.current_user_role() in ('root', 'reception', 'reception_admin', 'accountant')
  );
-- Sin políticas de escritura: solo las RPC SECURITY DEFINER de abajo.

comment on table public.stay_segments is
  'Tramos de una estadía: cuántas noches estuvo en qué habitación y a qué '
  'tarifa. Rango [start_date, end_date). Si una reserva tiene tramos, '
  'reservations.total_amount_bs es la suma de todos.';

-- ---------------------------------------------------------------------
-- Backfill: un tramo por cada reserva ACTIVA (confirmada o con el huésped
-- adentro). Las históricas ya cerradas se dejan sin tramos a propósito —
-- su total sigue siendo válido y reconstruir tarifas por noche de años de
-- datos del ETL sería inventar información que no tenemos.
-- ---------------------------------------------------------------------
insert into public.stay_segments (
  reservation_id, room_id, room_type_id, rate_bs, start_date, end_date, reason
)
select
  r.id, r.room_id, r.room_type_id,
  round(r.total_amount_bs / greatest(r.check_out_date - r.check_in_date, 1), 2),
  r.check_in_date, r.check_out_date,
  'Tramo inicial (backfill)'
from public.reservations r
where r.status in ('confirmed', 'checked_in')
  and r.room_id is not null
  and not exists (
    select 1 from public.stay_segments s where s.reservation_id = r.id
  );

-- ---------------------------------------------------------------------
-- recalc_reservation_total: reimpone el invariante. Se llama después de
-- CUALQUIER cambio de tramos. No valida nada — es puro recálculo.
-- ---------------------------------------------------------------------
create or replace function public.recalc_reservation_total(p_reservation_id uuid)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare v_total numeric(10,2);
begin
  select coalesce(sum((end_date - start_date) * rate_bs), 0)
  into v_total
  from public.stay_segments where reservation_id = p_reservation_id;

  update public.reservations
    set total_amount_bs = v_total,
        check_in_date  = coalesce((select min(start_date) from public.stay_segments
                                   where reservation_id = p_reservation_id), check_in_date),
        check_out_date = coalesce((select max(end_date) from public.stay_segments
                                   where reservation_id = p_reservation_id), check_out_date)
    where id = p_reservation_id;

  return v_total;
end;
$$;

revoke execute on function public.recalc_reservation_total(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- room_is_free_between: ¿la habitación está libre en [from, to) para
-- alguien que NO sea esta reserva? Extraído porque extender noches y
-- cambiar de habitación necesitan exactamente la misma pregunta.
-- ---------------------------------------------------------------------
create or replace function public.room_is_free_between(
  p_room_id        uuid,
  p_from           date,
  p_to             date,
  p_except_reservation uuid default null
) returns boolean
language sql
stable
set search_path = public
as $$
  select not exists (
    select 1 from public.reservations r
    where r.room_id = p_room_id
      and r.status in ('confirmed', 'checked_in')
      and (p_except_reservation is null or r.id <> p_except_reservation)
      and r.check_in_date < p_to
      and p_from < r.check_out_date
  );
$$;

grant execute on function public.room_is_free_between(uuid, date, date, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- extend_stay: el huésped se queda más noches.
--
-- Las noches nuevas se cobran a `p_rate_bs` (recepción la escribe; ver
-- change stay-rate-manual). Si coincide con la tarifa del último tramo se
-- ESTIRA ese tramo en vez de crear uno nuevo: partir la estadía en dos
-- líneas idénticas sólo ensucia el folio.
-- ---------------------------------------------------------------------
create or replace function public.extend_stay(
  p_room_id       uuid,
  p_new_check_out date,
  p_rate_bs       numeric,
  p_reason        text default null
) returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_res      public.reservations;
  v_last     public.stay_segments;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado para extender la estadía';
  end if;

  if p_rate_bs is null or p_rate_bs < 0 then
    raise exception 'La tarifa de las noches nuevas es obligatoria';
  end if;

  select * into v_res
  from public.reservations
  where room_id = p_room_id and status = 'checked_in'
  order by check_in_date desc
  limit 1
  for update;

  if not found then
    raise exception 'No hay una estadía activa en esta habitación';
  end if;

  if p_new_check_out <= v_res.check_out_date then
    raise exception 'La nueva salida (%) debe ser posterior a la actual (%)',
      p_new_check_out, v_res.check_out_date;
  end if;

  -- La habitación tiene que seguir libre en las noches que se agregan.
  if not public.room_is_free_between(
       p_room_id, v_res.check_out_date, p_new_check_out, v_res.id
     ) then
    raise exception 'La habitación ya está reservada por otro huésped en esas fechas';
  end if;

  select * into v_last
  from public.stay_segments
  where reservation_id = v_res.id
  order by end_date desc
  limit 1;

  if v_last.id is not null
     and v_last.room_id = p_room_id
     and v_last.rate_bs = p_rate_bs then
    update public.stay_segments
      set end_date = p_new_check_out
      where id = v_last.id;
  else
    insert into public.stay_segments (
      reservation_id, room_id, room_type_id, rate_bs, start_date, end_date, reason
    ) values (
      v_res.id, p_room_id, coalesce(v_last.room_type_id, v_res.room_type_id), p_rate_bs,
      v_res.check_out_date, p_new_check_out,
      coalesce(nullif(trim(p_reason), ''), 'Extensión de estadía')
    );
  end if;

  return public.recalc_reservation_total(v_res.id);
end;
$$;

grant execute on function public.extend_stay(uuid, date, numeric, text) to authenticated;

-- ---------------------------------------------------------------------
-- change_room: el huésped se muda a otra habitación.
--
-- Cierra el tramo vigente en `p_from` (por defecto hoy) y abre uno nuevo
-- en la habitación destino a la tarifa nueva. Queda registrado cuántas
-- noches estuvo en cada una y a qué precio, que es el requisito.
--
-- Caso borde real: si se muda el mismo día que entró, el tramo original
-- quedaría de cero noches — no se cierra, se REEMPLAZA, porque un tramo
-- de cero noches viola el check (end_date > start_date) y además no
-- describe nada.
-- ---------------------------------------------------------------------
create or replace function public.change_room(
  p_room_id         uuid,   -- habitación actual
  p_new_room_id     uuid,
  p_new_room_type_id uuid,
  p_rate_bs         numeric,
  p_from            date default null,
  p_reason          text default null
) returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_res    public.reservations;
  v_last   public.stay_segments;
  v_from   date := coalesce(p_from, current_date);
  v_status text;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado para cambiar de habitación';
  end if;

  if p_rate_bs is null or p_rate_bs < 0 then
    raise exception 'La tarifa de la habitación nueva es obligatoria';
  end if;

  if p_new_room_id = p_room_id then
    raise exception 'La habitación destino es la misma que la actual';
  end if;

  select * into v_res
  from public.reservations
  where room_id = p_room_id and status = 'checked_in'
  order by check_in_date desc
  limit 1
  for update;

  if not found then
    raise exception 'No hay una estadía activa en esta habitación';
  end if;

  if v_from < v_res.check_in_date then v_from := v_res.check_in_date; end if;
  if v_from >= v_res.check_out_date then
    raise exception 'La fecha del cambio debe ser anterior a la salida (%)', v_res.check_out_date;
  end if;

  -- El tipo elegido tiene que ser vendible en la habitación destino.
  if not exists (
    select 1 from public.room_type_options
    where room_id = p_new_room_id and room_type_id = p_new_room_type_id
  ) then
    raise exception 'El tipo seleccionado no corresponde a la habitación destino';
  end if;

  -- Destino libre por las noches que faltan, y utilizable ahora.
  select operational_status into v_status
  from public.rooms where id = p_new_room_id for update;
  if v_status not in ('available', 'dirty') then
    raise exception 'La habitación destino no está disponible (estado: %)', coalesce(v_status, 'inexistente');
  end if;
  if not public.room_is_free_between(p_new_room_id, v_from, v_res.check_out_date, v_res.id) then
    raise exception 'La habitación destino ya está reservada en esas fechas';
  end if;

  select * into v_last
  from public.stay_segments
  where reservation_id = v_res.id
  order by end_date desc
  limit 1;

  if v_last.id is null then
    -- Reserva histórica sin tramos: se materializa el tramo original antes
    -- de partirlo, para no perder lo que ya se había cobrado.
    insert into public.stay_segments (
      reservation_id, room_id, room_type_id, rate_bs, start_date, end_date, reason
    ) values (
      v_res.id, p_room_id, v_res.room_type_id,
      round(v_res.total_amount_bs / greatest(v_res.check_out_date - v_res.check_in_date, 1), 2),
      v_res.check_in_date, v_res.check_out_date, 'Tramo inicial (materializado al mudar)'
    ) returning * into v_last;
  end if;

  if v_from <= v_last.start_date then
    -- Se muda antes de dormir una noche en la actual: el tramo no existió.
    delete from public.stay_segments where id = v_last.id;
    v_from := v_last.start_date;
  else
    update public.stay_segments set end_date = v_from where id = v_last.id;
  end if;

  insert into public.stay_segments (
    reservation_id, room_id, room_type_id, rate_bs, start_date, end_date, reason
  ) values (
    v_res.id, p_new_room_id, p_new_room_type_id, p_rate_bs,
    v_from, v_res.check_out_date,
    coalesce(nullif(trim(p_reason), ''), 'Cambio de habitación')
  );

  -- La reserva pasa a apuntar a la habitación nueva; la vieja queda sucia.
  update public.reservations
    set room_id = p_new_room_id, room_type_id = p_new_room_type_id
    where id = v_res.id;

  update public.rooms set operational_status = 'dirty'    where id = p_room_id;
  update public.rooms set operational_status = 'occupied' where id = p_new_room_id;

  return public.recalc_reservation_total(v_res.id);
end;
$$;

grant execute on function public.change_room(uuid, uuid, uuid, numeric, date, text) to authenticated;

-- ---------------------------------------------------------------------
-- sync_single_stay_segment: toda reserva nace con su tramo, sin tocar
-- ninguna de las tres RPC que crean reservas (create_reservation,
-- walk_in_check_in, create_bulk_reservation) ni el ajuste posterior de
-- apply_rate_change.
--
-- Se REPLIEGA en cuanto la estadía tiene 2+ tramos: a partir de ahí la
-- verdad la escriben extend_stay / change_room y el trigger no puede
-- reconstruir un desglose de varias tarifas desde un único total.
-- ---------------------------------------------------------------------
create or replace function public.sync_single_stay_segment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count  int;
  v_nights int;
begin
  if new.status not in ('confirmed', 'checked_in') or new.room_id is null then
    return null;
  end if;

  select count(*) into v_count
  from public.stay_segments where reservation_id = new.id;

  -- Estadía ya partida en tramos: mandan las RPC, no este trigger.
  if v_count > 1 then
    return null;
  end if;

  v_nights := greatest(new.check_out_date - new.check_in_date, 1);

  if v_count = 0 then
    insert into public.stay_segments (
      reservation_id, room_id, room_type_id, rate_bs, start_date, end_date, reason
    ) values (
      new.id, new.room_id, new.room_type_id,
      round(new.total_amount_bs / v_nights, 2),
      new.check_in_date, new.check_out_date, 'Tramo inicial'
    );
  else
    update public.stay_segments set
      room_id      = new.room_id,
      room_type_id = new.room_type_id,
      rate_bs      = round(new.total_amount_bs / v_nights, 2),
      start_date   = new.check_in_date,
      end_date     = new.check_out_date
    where reservation_id = new.id;
  end if;

  return null;
end;
$$;

drop trigger if exists trg_sync_single_stay_segment on public.reservations;
create trigger trg_sync_single_stay_segment
  after insert or update of
    total_amount_bs, check_in_date, check_out_date, room_id, room_type_id, status
  on public.reservations
  for each row
  execute function public.sync_single_stay_segment();
