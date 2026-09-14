-- =====================================================================
-- Contrato institucional: columnas de tarifa/cortesía + helpers internos
-- (change: group-billing, stage 6, Slice 2a).
--
-- Este slice agrega el ESQUEMA y dos helpers internos que necesita el
-- contrato congelado de una reserva institucional (payer_mode='client'):
--   - bookings.rate_mode / agreed_unit_price_bs: un booking institucional
--     puede pactarse "por habitación" (rate_mode='room', default -- el
--     total sale de sumar reservations.total_amount_bs como siempre) o
--     "por persona por noche" (rate_mode='person', requiere un precio
--     pactado agreed_unit_price_bs). "Por persona" sólo tiene sentido en
--     un contrato institucional, nunca en payer_mode='each_stay'.
--   - bookings.receivable_account_id ya existía (foundation); acá se
--     vuelve OBLIGATORIA cuando payer_mode='client' vía CHECK, porque
--     todo el dinero de un contrato institucional se cobra contra esa
--     cuenta (Slice 5b/6).
--   - reservations.is_courtesy / courtesy_reason: una habitación de
--     cortesía sigue ocupando el cuarto (billing-only) pero no cuenta
--     para el contrato (total_amount_bs=0, excluida del headcount en
--     rate_mode='person') -- siempre necesita un motivo real, nunca
--     NULL ni un string en blanco.
--
-- IMPORTANTE -- el CHECK de courtesy_reason usa coalesce(char_length(...),
-- 0) y NO la forma corta `not is_courtesy or char_length(trim(x)) > 0`:
-- en Postgres, un CHECK sólo rechaza la fila si el resultado es
-- explícitamente FALSE -- si courtesy_reason es NULL, esa forma corta
-- evalúa a NULL (desconocido) y el motor lo trata como "pasa", dejando
-- colar una cortesía sin motivo. Confirmado empíricamente en la sesión
-- de este branch: `select (not true or char_length(trim(null)) > 0)` da
-- NULL, no false.
--
-- _resolve_receivable_account y _apply_rate_change_direct son helpers
-- INTERNOS -- ningún cliente (frontend/API) los llama nunca. Se revocan
-- de public/anon/authenticated (mismo patrón que _net_owed_bs en
-- 20260911090000): sólo los usan otras funciones SECURITY DEFINER que sí
-- están gateadas (create_reservation/create_bulk_reservation en
-- feat/booking-10/11, apply_rate_change en feat/booking-13).
--
-- _apply_rate_change_direct es una extracción FIEL de la rama "aplicar
-- directo" del apply_rate_change actualmente en producción local (ver
-- pg_get_functiondef en la sesión de este branch): misma inserción en
-- rate_overrides, misma auto-aprobación de rate_discount_requests cuando
-- el descuento calculado supera 20% (nunca queda 'pending', porque quien
-- llama a este helper -- creación institucional o un futuro
-- apply_rate_change ya gateado a reception_admin -- ya decidió aplicar
-- directo). apply_rate_change EN SÍ NO se toca en este branch --
-- eso es feat/booking-13-rate-lock.
-- =====================================================================

alter table public.bookings
  add column rate_mode text not null default 'room' check (rate_mode in ('room', 'person')),
  add column agreed_unit_price_bs numeric(10,2),
  add constraint bookings_person_rate_requires_price
    check (rate_mode <> 'person' or agreed_unit_price_bs is not null),
  add constraint bookings_person_rate_requires_client
    check (rate_mode <> 'person' or payer_mode = 'client'),
  add constraint bookings_client_requires_account
    check (payer_mode <> 'client' or receivable_account_id is not null);

alter table public.reservations
  add column is_courtesy boolean not null default false,
  add column courtesy_reason text,
  add constraint reservations_courtesy_reason_required
    check (not is_courtesy or coalesce(char_length(trim(courtesy_reason)), 0) > 0);

create function public._resolve_receivable_account(
  p_receivable_account_id uuid,
  p_new_account_name text,
  p_new_account_kind text,
  p_new_account_contact text,
  p_new_account_notes text
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_account_id uuid;
begin
  if p_receivable_account_id is not null and nullif(trim(p_new_account_name), '') is not null then
    raise exception 'Elegí una cuenta existente O creá una nueva, no ambas';
  end if;

  if p_receivable_account_id is not null then
    if not exists (
      select 1 from public.receivable_accounts
      where id = p_receivable_account_id and is_active
    ) then
      raise exception 'Cuenta por cobrar inválida o inactiva';
    end if;
    return p_receivable_account_id;
  end if;

  if nullif(trim(p_new_account_name), '') is null then
    raise exception 'Elegí una cuenta existente o indicá los datos de la nueva cuenta';
  end if;
  if p_new_account_kind not in ('empresa', 'agencia', 'persona') then
    raise exception 'Tipo de cuenta inválido: %', p_new_account_kind;
  end if;

  insert into public.receivable_accounts (name, kind, contact, notes)
  values (
    trim(p_new_account_name), p_new_account_kind,
    nullif(trim(p_new_account_contact), ''), nullif(trim(p_new_account_notes), '')
  )
  returning id into v_account_id;

  return v_account_id;
end;
$$;
revoke execute on function public._resolve_receivable_account(uuid, text, text, text, text)
  from public, anon, authenticated;

create function public._apply_rate_change_direct(
  p_reservation_id uuid,
  p_room_type_id uuid,
  p_base_price_bs numeric,
  p_nights int,
  p_new_price_per_night numeric,
  p_reason text
) returns table(applied boolean, discount_pct numeric, request_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pct numeric(5,2);
  v_prev numeric(10,2);
  v_request uuid;
begin
  v_pct := public.discount_pct(p_base_price_bs, p_new_price_per_night);

  select total_amount_bs / greatest(p_nights, 1) into v_prev
  from public.reservations where id = p_reservation_id;

  update public.reservations
    set total_amount_bs = p_new_price_per_night * p_nights
    where id = p_reservation_id;

  insert into public.rate_overrides (
    reservation_id, previous_rate_bs, new_rate_bs, reason, changed_by
  ) values (
    p_reservation_id, v_prev, p_new_price_per_night, p_reason, auth.uid()
  );

  if v_pct > 20 then
    -- Auto-aprobado y auditado: quien llama a este helper ya decidió que
    -- esto se aplica directo -- nunca queda 'pending' (a diferencia de la
    -- rama "solicitud" de apply_rate_change para reception sin rol admin).
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
end;
$$;
-- Sin guard de rol propio: helper interno, seguridad por proximidad
-- (mismo patrón que apply_rate_change) -- sólo lo llaman
-- create_reservation/create_bulk_reservation (ya gateadas a
-- root/reception_admin para payer_mode='client') y apply_rate_change
-- (feat/booking-13, ya gateado por su propio caller).
revoke execute on function public._apply_rate_change_direct(uuid, uuid, numeric, int, numeric, text)
  from public, anon, authenticated;
