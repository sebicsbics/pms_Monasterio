-- =====================================================================
-- Discount approval workflow (change: discount-approval-workflow).
--
-- Cap descuentos no controlados sobre la tarifa de una reserva. Recepción
-- ingresa un precio absoluto (Bs) en cualquier punto de entrada de tarifa;
-- el sistema calcula el descuento implícito contra
-- `room_types.base_price_bs`. Descuentos <=20% se aplican de inmediato.
-- Descuentos >20% requieren aprobación de `reception_admin` mediante una
-- solicitud pendiente, salvo que quien lo aplique YA sea `reception_admin`
-- (puede aplicar directo, con auditoría obligatoria).
--
-- SCOPE (ver diseño, corrección de alcance confirmada): de los 4 puntos de
-- entrada nombrados en la propuesta, `check_in_reservation` NO tiene hoy
-- capacidad de fijar tarifa (nunca toca total_amount_bs) — queda FUERA de
-- alcance, sin cambios. Los 3 gates reales son: create_reservation
-- (se le agregan p_rate_bs/p_reason, nuevos), walk_in_check_in y
-- override_reservation_rate (ya existentes).
--
-- Todas las funciones PL/pgSQL tocadas se restatean COMPLETAS (Postgres no
-- permite parches parciales) — convención ya usada en
-- 20260718000000_lock_down_reservations_folios.sql y
-- 20260722010000_reception_admin_role.sql.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) discount_pct: función pura, espejo EXACTO de
--    src/domain/pricing/discount.ts (discountPct). Cualquier cambio acá
--    debe replicarse ahí y viceversa (riesgo #3 del diseño).
-- ---------------------------------------------------------------------
create or replace function public.discount_pct(p_base numeric, p_price numeric)
returns numeric
language sql
immutable
as $$
  select case
    when p_base is null or p_base <= 0 then 0
    else round(
      least(100, greatest(0, (p_base - p_price) / p_base * 100)),
      2
    )
  end
$$;

-- ---------------------------------------------------------------------
-- 2) rate_discount_requests: solicitudes pendientes de aprobación cuando
--    el descuento implícito supera el 20% y quien lo pide NO es
--    reception_admin. Sin política de insert/update/delete: solo se
--    escribe desde las RPC SECURITY DEFINER de abajo (mismo patrón que
--    rate_overrides).
-- ---------------------------------------------------------------------
create table if not exists public.rate_discount_requests (
  id                    uuid primary key default gen_random_uuid(),
  reservation_id        uuid not null references public.reservations(id),
  room_type_id          uuid not null references public.room_types(id),
  base_price_bs         numeric(10,2) not null,
  requested_price_bs    numeric(10,2) not null,
  computed_discount_pct numeric(5,2) not null,
  reason                text not null check (char_length(trim(reason)) > 0),
  requested_by          uuid not null references public.profiles(id),
  status                text not null default 'pending'
                          check (status in ('pending', 'approved', 'rejected')),
  resolved_by           uuid references public.profiles(id),
  resolved_at           timestamptz,
  applied_at            timestamptz,
  created_at            timestamptz not null default now()
);

alter table public.rate_discount_requests enable row level security;

drop policy if exists "rate_discount_requests_read" on public.rate_discount_requests;
create policy "rate_discount_requests_read" on public.rate_discount_requests
  for select using (
    public.current_user_role() in ('root', 'reception', 'reception_admin', 'accountant')
  );

-- ---------------------------------------------------------------------
-- 3) apply_rate_change: helper interno compartido por los 3 puntos de
--    entrada. NO se otorga a anon/authenticated — se llama solo desde
--    dentro de otras RPC SECURITY DEFINER (precedente: check_out_room
--    llama a add_cash_movement, 20260718000000_lock_down_reservations_
--    folios.sql / restated en 20260722010000_reception_admin_role.sql).
--    Unidad SIEMPRE por-noche (p_new_price_per_night) tanto para
--    previous_rate_bs como new_rate_bs — evita reintroducir el bug de
--    unidades mixtas (total vs. por-noche) ya presente en
--    override_reservation_rate histórico (ver riesgo #2 del diseño).
-- ---------------------------------------------------------------------
create or replace function public.apply_rate_change(
  p_reservation_id       uuid,
  p_room_type_id         uuid,
  p_base_price_bs        numeric,
  p_nights               int,
  p_new_price_per_night  numeric,
  p_reason               text
) returns table(applied boolean, discount_pct numeric, request_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pct       numeric(5,2);
  v_role      text;
  v_prev      numeric(10,2);
  v_request   uuid;
begin
  v_pct  := public.discount_pct(p_base_price_bs, p_new_price_per_night);
  v_role := public.current_user_role();

  select total_amount_bs / greatest(p_nights, 1) into v_prev
  from public.reservations where id = p_reservation_id;

  if v_pct <= 20 or v_role = 'reception_admin' then
    update public.reservations
      set total_amount_bs = p_new_price_per_night * p_nights
      where id = p_reservation_id;

    insert into public.rate_overrides (
      reservation_id, previous_rate_bs, new_rate_bs, reason, changed_by
    ) values (
      p_reservation_id, v_prev, p_new_price_per_night, p_reason, auth.uid()
    );

    if v_pct > 20 then
      -- reception_admin aplicando un descuento grande directo: igual se
      -- audita como solicitud auto-aprobada (REQ-4 del spec).
      insert into public.rate_discount_requests (
        reservation_id, room_type_id, base_price_bs, requested_price_bs,
        computed_discount_pct, reason, requested_by,
        status, resolved_by, resolved_at, applied_at
      ) values (
        p_reservation_id, p_room_type_id, p_base_price_bs, p_new_price_per_night,
        v_pct, p_reason, auth.uid(),
        'approved', auth.uid(), now(), now()
      ) returning id into v_request;
    end if;

    return query select true, v_pct, v_request;
  else
    insert into public.rate_discount_requests (
      reservation_id, room_type_id, base_price_bs, requested_price_bs,
      computed_discount_pct, reason, requested_by, status
    ) values (
      p_reservation_id, p_room_type_id, p_base_price_bs, p_new_price_per_night,
      v_pct, p_reason, auth.uid(), 'pending'
    ) returning id into v_request;

    return query select false, v_pct, v_request;
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 4) create_reservation: se agregan p_rate_bs/p_reason opcionales
--    (mismo patrón que walk_in_check_in). Dropear el overload de 10
--    argumentos antes de crear el de 12 (mismo overload trap documentado
--    en 20260717000000_walkin_editable_rate.sql:11-14).
-- ---------------------------------------------------------------------
drop function if exists public.create_reservation(
  uuid, uuid, text, text, text, text, date, date, int, text
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
  p_method       text,
  p_rate_bs      numeric default null,
  p_reason       text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_person_id      uuid;
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

  -- Insertar SIEMPRE al precio de lista; el descuento (si lo hay) se
  -- aplica después vía apply_rate_change, para que la reserva se cree
  -- igual aunque el descuento quede pendiente de aprobación.
  insert into public.reservations (
    guest_id, room_id, room_type_id, check_in_date, check_out_date,
    reservation_method, payment_status, total_amount_bs, status, num_guests
  ) values (
    v_person_id, p_room_id, p_room_type_id, p_check_in, p_check_out,
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
      v_reservation_id, p_room_type_id, v_rate, v_nights, p_rate_bs, p_reason
    );
  end if;

  return v_reservation_id;
end;
$$;

-- Grants: idénticos a la versión previa (20260718000000_lock_down_
-- reservations_folios.sql:333-339) — el guard de rol al inicio de la
-- función ya bloquea a anon antes de llegar a la rama de tarifa.
grant execute on function public.create_reservation(
  uuid, uuid, text, text, text, text, date, date, int, text, numeric, text
) to authenticated;

-- ---------------------------------------------------------------------
-- 5) walk_in_check_in: se inserta SIEMPRE al precio de lista; se
--    reemplaza el insert directo a rate_overrides por apply_rate_change.
--    Guard de rol/justificación/monto positivo (líneas 493-503 de
--    20260722010000_reception_admin_role.sql) se mantiene IGUAL como el
--    gate de "puede tocar la tarifa"; el efecto cambia.
-- ---------------------------------------------------------------------
create or replace function public.walk_in_check_in(
  p_room_id      uuid,
  p_room_type_id uuid,
  p_first_name   text,
  p_last_name    text,
  p_document     text,
  p_email        text,
  p_birth_date   date,
  p_country_code text,
  p_city         text,
  p_wants_offers boolean,
  p_nights       int,
  p_rate_bs      numeric default null,
  p_rate_reason  text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_person_id       uuid;
  v_reservation_id  uuid;
  v_room_type_rate  numeric(10,2);
  v_status          varchar(15);
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

  if not exists (
    select 1 from public.room_type_options
    where room_id = p_room_id and room_type_id = p_room_type_id
  ) then
    raise exception 'El tipo seleccionado no corresponde a esta habitación';
  end if;

  select base_price_bs into v_room_type_rate
  from public.room_types where id = p_room_type_id;

  if p_rate_bs is not null and p_rate_bs <> v_room_type_rate then
    if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
      raise exception 'No autorizado para cambiar la tarifa';
    end if;
    if p_rate_reason is null or char_length(trim(p_rate_reason)) = 0 then
      raise exception 'La justificación es obligatoria para cambiar la tarifa';
    end if;
    if p_rate_bs <= 0 then
      raise exception 'La tarifa debe ser un monto positivo';
    end if;
  end if;

  -- ¿Huésped ya conocido por documento?
  if nullif(p_document, '') is not null then
    select person_id into v_person_id
    from public.guests where passport_number = p_document;
  end if;

  if v_person_id is not null then
    -- Huésped que vuelve: actualizamos su ficha (sin borrar lo que no venga).
    update public.people set
      first_name = p_first_name,
      last_name  = p_last_name,
      email      = coalesce(nullif(p_email, ''), email),
      birth_date = coalesce(p_birth_date, birth_date)
    where id = v_person_id;
    update public.guests set
      country_code = coalesce(nullif(p_country_code, ''), country_code),
      city         = coalesce(nullif(p_city, ''), city),
      wants_offers = p_wants_offers
    where person_id = v_person_id;
  else
    -- Huésped nuevo.
    insert into public.people (first_name, last_name, email, birth_date)
    values (p_first_name, p_last_name, nullif(p_email, ''), p_birth_date)
    returning id into v_person_id;
    insert into public.guests (person_id, passport_number, country_code, city, wants_offers)
    values (
      v_person_id, nullif(p_document, ''),
      nullif(p_country_code, ''), nullif(p_city, ''), p_wants_offers
    );
  end if;

  -- Insertar SIEMPRE al precio de lista del tipo de habitación.
  insert into public.reservations (
    guest_id, room_id, room_type_id, check_in_date, check_out_date,
    reservation_method, payment_status, total_amount_bs, status
  ) values (
    v_person_id, p_room_id, p_room_type_id, current_date, current_date + p_nights,
    'walk-in', 'pending', v_room_type_rate * p_nights, 'checked_in'
  ) returning id into v_reservation_id;

  insert into public.folios (reservation_id) values (v_reservation_id);
  update public.rooms set operational_status = 'occupied' where id = p_room_id;

  if p_rate_bs is not null and p_rate_bs <> v_room_type_rate then
    perform public.apply_rate_change(
      v_reservation_id, p_room_type_id, v_room_type_rate, p_nights, p_rate_bs, p_rate_reason
    );
  end if;

  return v_reservation_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 6) override_reservation_rate: se agrega join a room_types para obtener
--    base_price_bs; se reemplaza el update+insert directo por
--    apply_rate_change. Guards de rol/justificación/monto positivo
--    (líneas 400-409 de 20260722010000_reception_admin_role.sql) se
--    mantienen igual.
-- ---------------------------------------------------------------------
create or replace function public.override_reservation_rate(
  p_reservation_id uuid,
  p_new_rate       numeric,
  p_reason         text
)
returns public.reservations
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nights        int;
  v_room_type_id  uuid;
  v_base_price_bs numeric(10,2);
  v_row           public.reservations;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado para cambiar la tarifa';
  end if;

  if p_reason is null or char_length(trim(p_reason)) = 0 then
    raise exception 'La justificación es obligatoria';
  end if;

  if p_new_rate is null or p_new_rate <= 0 then
    raise exception 'La tarifa debe ser un monto positivo';
  end if;

  select greatest(r.check_out_date - r.check_in_date, 1), rt.id, rt.base_price_bs
    into v_nights, v_room_type_id, v_base_price_bs
  from public.reservations r
  join public.room_types rt on rt.id = r.room_type_id
  where r.id = p_reservation_id;

  if not found then
    raise exception 'Reserva no encontrada';
  end if;

  perform public.apply_rate_change(
    p_reservation_id, v_room_type_id, v_base_price_bs, v_nights, p_new_rate, p_reason
  );

  select * into v_row from public.reservations where id = p_reservation_id;

  return v_row;
end;
$$;

-- ---------------------------------------------------------------------
-- 7) approve_rate_discount_request / reject_rate_discount_request:
--    solo reception_admin/root. Approve aplica la tarifa solicitada y
--    registra auditoría; reject no toca la reserva.
-- ---------------------------------------------------------------------
create or replace function public.approve_rate_discount_request(p_request_id uuid)
returns public.reservations
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req    public.rate_discount_requests;
  v_nights int;
  v_prev   numeric(10,2);
  v_row    public.reservations;
begin
  if public.current_user_role() not in ('root', 'reception_admin') then
    raise exception 'No autorizado para aprobar descuentos';
  end if;

  select * into v_req
  from public.rate_discount_requests
  where id = p_request_id and status = 'pending'
  for update;

  if not found then
    raise exception 'Solicitud no encontrada o ya resuelta';
  end if;

  select greatest(check_out_date - check_in_date, 1), total_amount_bs / greatest(check_out_date - check_in_date, 1)
    into v_nights, v_prev
  from public.reservations
  where id = v_req.reservation_id;

  update public.reservations
    set total_amount_bs = v_req.requested_price_bs * v_nights
    where id = v_req.reservation_id
    returning * into v_row;

  insert into public.rate_overrides (
    reservation_id, previous_rate_bs, new_rate_bs, reason, changed_by
  ) values (
    v_req.reservation_id, v_prev, v_req.requested_price_bs, v_req.reason, auth.uid()
  );

  update public.rate_discount_requests
    set status = 'approved', resolved_by = auth.uid(), resolved_at = now(), applied_at = now()
    where id = p_request_id;

  return v_row;
end;
$$;

create or replace function public.reject_rate_discount_request(
  p_request_id uuid,
  p_note       text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.current_user_role() not in ('root', 'reception_admin') then
    raise exception 'No autorizado para rechazar descuentos';
  end if;

  update public.rate_discount_requests
    set status = 'rejected', resolved_by = auth.uid(), resolved_at = now()
    where id = p_request_id and status = 'pending';

  if not found then
    raise exception 'Solicitud no encontrada o ya resuelta';
  end if;
end;
$$;

-- Grants: approve/reject son invocables por cualquier usuario autenticado,
-- pero el guard de rol dentro de la función bloquea a quien no sea
-- root/reception_admin (mismo patrón que el resto de RPC del módulo).
-- apply_rate_change y discount_pct NO se otorgan a anon/authenticated:
-- discount_pct es de solo lectura pura pero interna (se usa vía las RPC
-- de arriba); apply_rate_change es estrictamente interno (riesgo #4 del
-- diseño) — Supabase revoca EXECUTE de PUBLIC por defecto en funciones
-- nuevas del schema public, así que la ausencia de grant explícito ya
-- las deja inalcanzables desde el cliente.
grant execute on function public.approve_rate_discount_request(uuid) to authenticated;
grant execute on function public.reject_rate_discount_request(uuid, text) to authenticated;
