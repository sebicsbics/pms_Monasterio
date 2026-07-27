-- =====================================================================
-- Reembolsos -> cancelar / reprogramar (change: refunds-to-cancel-reschedule).
--
-- Decisión de negocio: el hotel NO reembolsa anticipos. Si el huésped no
-- puede venir, la reserva se REPROGRAMA (mover fechas) o se CANCELA. Al
-- cancelar, el anticipo se PIERDE (no reembolsable): la plata ya ingresó a
-- caja y NO se genera egreso.
--
-- Cambios:
--   1) Se elimina por completo refund_anticipo (RPC + estados/columna de
--      reembolso del esquema de anticipos). Producción verificada sin
--      anticipos ni reembolsos (0 filas) al momento de este cambio.
--   2) Nueva RPC cancel_reservation: solo reservas 'confirmed' -> 'cancelled',
--      con justificación obligatoria; marca los anticipos activos como
--      'forfeited'.
--   3) Nueva RPC reschedule_reservation: solo 'confirmed', re-chequea
--      disponibilidad de la MISMA habitación en las nuevas fechas y bloquea
--      si está ocupada. Recalcula el total manteniendo la tarifa por noche.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Eliminar el flujo de reembolso de anticipos.
-- ---------------------------------------------------------------------
drop function if exists public.refund_anticipo(uuid, numeric, text);

-- anticipos: quitar columna y estados de reembolso. Nuevo estado terminal
-- 'forfeited' (anticipo perdido por cancelación de la reserva).
alter table public.anticipos
  drop constraint if exists anticipos_status_check;
alter table public.anticipos
  drop column if exists refunded_amount_bs cascade;
alter table public.anticipos
  alter column status set default 'active';
alter table public.anticipos
  add constraint anticipos_status_check
  check (status in ('active', 'forfeited'));

-- anticipo_corrections: la acción 'refund' deja de existir; solo 'modify'.
alter table public.anticipo_corrections
  drop constraint if exists anticipo_corrections_action_check;
alter table public.anticipo_corrections
  add constraint anticipo_corrections_action_check
  check (action in ('modify'));

-- ---------------------------------------------------------------------
-- 2) Auditoría de cancelación / reprogramación.
-- ---------------------------------------------------------------------
alter table public.reservations
  add column if not exists cancelled_reason text,
  add column if not exists cancelled_by     uuid references public.profiles(id),
  add column if not exists cancelled_at      timestamptz;

create table if not exists public.reservation_reschedules (
  id               uuid primary key default gen_random_uuid(),
  reservation_id   uuid not null references public.reservations(id),
  prev_check_in    date not null,
  prev_check_out   date not null,
  new_check_in     date not null,
  new_check_out    date not null,
  reason           text not null check (char_length(trim(reason)) > 0),
  changed_by       uuid not null references public.profiles(id) default auth.uid(),
  changed_at       timestamptz not null default now()
);

alter table public.reservation_reschedules enable row level security;

drop policy if exists "reservation_reschedules_read" on public.reservation_reschedules;
create policy "reservation_reschedules_read" on public.reservation_reschedules
  for select using (
    public.current_user_role() in ('root', 'reception', 'reception_admin', 'accountant')
  );

-- ---------------------------------------------------------------------
-- 3) cancel_reservation: solo 'confirmed' -> 'cancelled'. El anticipo se
--    pierde (status 'forfeited'); NO se genera egreso de caja.
-- ---------------------------------------------------------------------
create or replace function public.cancel_reservation(
  p_reservation_id uuid,
  p_reason         text
) returns public.reservations
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status varchar(20);
  v_row    public.reservations;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado para cancelar reservas';
  end if;

  if p_reason is null or char_length(trim(p_reason)) = 0 then
    raise exception 'La justificación es obligatoria';
  end if;

  select status into v_status
  from public.reservations where id = p_reservation_id for update;

  if v_status is null then
    raise exception 'Reserva no encontrada';
  end if;
  if v_status <> 'confirmed' then
    raise exception 'Solo se pueden cancelar reservas confirmadas (estado: %)', v_status;
  end if;

  update public.reservations
    set status          = 'cancelled',
        cancelled_reason = trim(p_reason),
        cancelled_by     = auth.uid(),
        cancelled_at     = now()
    where id = p_reservation_id
    returning * into v_row;

  -- El anticipo se pierde: se marca perdido, sin egreso de caja.
  update public.anticipos
    set status = 'forfeited'
    where reservation_id = p_reservation_id and status = 'active';

  return v_row;
end;
$$;

grant execute on function public.cancel_reservation(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 4) reschedule_reservation: solo 'confirmed'. Re-chequea disponibilidad
--    de la MISMA habitación (excluyendo la propia reserva) y recalcula el
--    total conservando la tarifa por noche vigente (respeta overrides).
-- ---------------------------------------------------------------------
create or replace function public.reschedule_reservation(
  p_reservation_id uuid,
  p_check_in       date,
  p_check_out      date,
  p_reason         text
) returns public.reservations
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status     varchar(20);
  v_room_id    uuid;
  v_prev_in    date;
  v_prev_out   date;
  v_old_nights int;
  v_new_nights int;
  v_per_night  numeric(10,2);
  v_row        public.reservations;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado para reprogramar reservas';
  end if;

  if p_reason is null or char_length(trim(p_reason)) = 0 then
    raise exception 'La justificación es obligatoria';
  end if;
  if p_check_out <= p_check_in then
    raise exception 'La fecha de salida debe ser posterior a la de entrada';
  end if;

  select status, room_id, check_in_date, check_out_date
    into v_status, v_room_id, v_prev_in, v_prev_out
  from public.reservations where id = p_reservation_id for update;

  if v_status is null then
    raise exception 'Reserva no encontrada';
  end if;
  if v_status <> 'confirmed' then
    raise exception 'Solo se pueden reprogramar reservas confirmadas (estado: %)', v_status;
  end if;

  -- Bloqueo pesimista + revalidación de disponibilidad (anti-overbooking),
  -- excluyendo la propia reserva.
  perform 1 from public.rooms where id = v_room_id for update;
  if exists (
    select 1 from public.reservations r
    where r.room_id = v_room_id
      and r.id <> p_reservation_id
      and r.status in ('confirmed', 'checked_in')
      and r.check_in_date < p_check_out
      and p_check_in < r.check_out_date
  ) then
    raise exception 'La habitación no está disponible para esas fechas';
  end if;

  -- Conservar la tarifa por noche vigente (respeta overrides previos).
  v_old_nights := greatest(v_prev_out - v_prev_in, 1);
  v_new_nights := p_check_out - p_check_in;
  select total_amount_bs / v_old_nights into v_per_night
    from public.reservations where id = p_reservation_id;

  update public.reservations
    set check_in_date  = p_check_in,
        check_out_date = p_check_out,
        total_amount_bs = v_per_night * v_new_nights
    where id = p_reservation_id
    returning * into v_row;

  insert into public.reservation_reschedules (
    reservation_id, prev_check_in, prev_check_out,
    new_check_in, new_check_out, reason
  ) values (
    p_reservation_id, v_prev_in, v_prev_out, p_check_in, p_check_out, trim(p_reason)
  );

  return v_row;
end;
$$;

grant execute on function public.reschedule_reservation(uuid, date, date, text) to authenticated;

-- ---------------------------------------------------------------------
-- 5) modify_anticipo: se ajusta el mensaje del guard (ya no existe el
--    estado "reembolsado"; el único estado no-activo es 'forfeited', por
--    reserva cancelada). Restatement completo (Postgres no permite parche
--    parcial). Cuerpo idéntico a 20260723000000 salvo el texto del error.
-- ---------------------------------------------------------------------
create or replace function public.modify_anticipo(
  p_anticipo_id        uuid,
  p_new_amount_bs      numeric,
  p_new_payment_method text,
  p_reason             text
) returns public.anticipos
language plpgsql
security definer
set search_path = public
as $$
declare
  v_anticipo public.anticipos;
begin
  if public.current_user_role() <> 'reception_admin' then
    raise exception 'Solo reception_admin puede modificar anticipos';
  end if;

  if p_reason is null or char_length(trim(p_reason)) = 0 then
    raise exception 'La justificación es obligatoria';
  end if;

  select * into v_anticipo from public.anticipos where id = p_anticipo_id for update;
  if not found then
    raise exception 'Anticipo no encontrado';
  end if;

  if v_anticipo.status <> 'active' then
    raise exception 'No se puede modificar un anticipo perdido (reserva cancelada)';
  end if;

  if p_new_amount_bs is null or p_new_amount_bs <= 0 then
    raise exception 'El monto debe ser positivo';
  end if;

  if not exists (
    select 1 from public.payment_methods where code = p_new_payment_method and is_active
  ) then
    raise exception 'Forma de pago inválida: %', p_new_payment_method;
  end if;

  insert into public.anticipo_corrections (
    anticipo_id, action, previous_amount_bs, previous_payment_method,
    new_amount_bs, new_payment_method, reason
  ) values (
    p_anticipo_id, 'modify', v_anticipo.amount_bs, v_anticipo.payment_method,
    p_new_amount_bs, p_new_payment_method, p_reason
  );

  update public.anticipos
    set amount_bs = p_new_amount_bs, payment_method = p_new_payment_method
    where id = p_anticipo_id
    returning * into v_anticipo;

  return v_anticipo;
end;
$$;
