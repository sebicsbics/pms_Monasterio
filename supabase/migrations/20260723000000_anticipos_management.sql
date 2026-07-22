-- =====================================================================
-- Anticipos management (change: anticipos-management).
--
-- Recepción puede registrar anticipos (adelantos de huésped) contra una
-- reserva. Reembolsar o modificar un anticipo es un camino de
-- correction/money-out restringido a `reception_admin`, mismo patrón de
-- lockdown que folios/caja (20260718000000_lock_down_reservations_folios.sql,
-- 20260722010000_reception_admin_role.sql). anticipos vive independiente de
-- `event_payments` — sin tabla compartida, sin vocabulario unificado en
-- este cambio.
--
-- Verified facts (ver design sdd/anticipos-management/design):
-- - add_cash_movement(p_kind, p_category, p_amount, p_concept,
--   p_receipt_path, p_payment_method default null) ya permite
--   root/reception/reception_admin y requiere una cash_session abierta.
--   No soporta montos negativos: un reembolso se modela como
--   p_kind='expense' con categoría propia, NUNCA como income negativo.
-- - payment_methods.code es texto en MAYÚSCULA (catálogo canónico).
-- - reservations.id es uuid.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) anticipos: registro de adelantos. Sin política de insert/update/
--    delete — solo se escribe vía las RPC SECURITY DEFINER de abajo
--    (mismo patrón que rate_discount_requests / rate_overrides).
-- ---------------------------------------------------------------------
create table if not exists public.anticipos (
  id                 uuid primary key default gen_random_uuid(),
  reservation_id     uuid not null references public.reservations(id),
  amount_bs          numeric(10,2) not null check (amount_bs > 0),
  refunded_amount_bs numeric(10,2) not null default 0 check (refunded_amount_bs >= 0),
  payment_method     text not null references public.payment_methods(code),
  status             text not null default 'active'
                        check (status in ('active','partially_refunded','refunded')),
  cash_movement_id   uuid references public.cash_movements(id),
  received_by        uuid not null references public.profiles(id) default auth.uid(),
  received_at        timestamptz not null default now(),
  notes              text,
  created_at         timestamptz not null default now(),
  check (refunded_amount_bs <= amount_bs)
);

alter table public.anticipos enable row level security;

drop policy if exists "anticipos_read" on public.anticipos;
create policy "anticipos_read" on public.anticipos
  for select using (
    public.current_user_role() in ('root','reception','reception_admin','accountant')
  );

-- ---------------------------------------------------------------------
-- 2) anticipo_corrections: bitácora append-only para reembolsos y
--    modificaciones (una sola tabla para ambas acciones — ver decisión de
--    diseño). Sin política de insert/update/delete — solo RPC.
-- ---------------------------------------------------------------------
create table if not exists public.anticipo_corrections (
  id                       uuid primary key default gen_random_uuid(),
  anticipo_id              uuid not null references public.anticipos(id),
  action                   text not null check (action in ('refund','modify')),
  refund_amount_bs         numeric(10,2) check (refund_amount_bs > 0),
  cash_movement_id         uuid references public.cash_movements(id),
  previous_amount_bs       numeric(10,2),
  previous_payment_method  text references public.payment_methods(code),
  new_amount_bs            numeric(10,2),
  new_payment_method       text references public.payment_methods(code),
  reason                   text not null check (char_length(trim(reason)) > 0),
  performed_by             uuid not null references public.profiles(id) default auth.uid(),
  performed_at             timestamptz not null default now()
);

alter table public.anticipo_corrections enable row level security;

drop policy if exists "anticipo_corrections_read" on public.anticipo_corrections;
create policy "anticipo_corrections_read" on public.anticipo_corrections
  for select using (
    public.current_user_role() in ('root','reception','reception_admin','accountant')
  );

-- ---------------------------------------------------------------------
-- 3) record_anticipo: reception + reception_admin + root. Money IN —
--    llama add_cash_movement('income', ...) igual que otros flujos de
--    caja existentes.
-- ---------------------------------------------------------------------
create or replace function public.record_anticipo(
  p_reservation_id uuid,
  p_amount_bs      numeric,
  p_payment_method text,
  p_notes          text default null
) returns public.anticipos
language plpgsql
security definer
set search_path = public
as $$
declare
  v_movement public.cash_movements;
  v_row      public.anticipos;
begin
  if public.current_user_role() not in ('root','reception','reception_admin') then
    raise exception 'No autorizado para registrar anticipos';
  end if;

  if p_amount_bs is null or p_amount_bs <= 0 then
    raise exception 'El monto debe ser positivo';
  end if;

  if not exists (select 1 from public.reservations where id = p_reservation_id) then
    raise exception 'Reserva no encontrada';
  end if;

  v_movement := public.add_cash_movement(
    'income', 'adelanto', p_amount_bs,
    'Anticipo reserva ' || p_reservation_id, null, p_payment_method
  );

  insert into public.anticipos (reservation_id, amount_bs, payment_method, cash_movement_id, notes)
  values (p_reservation_id, p_amount_bs, p_payment_method, v_movement.id, p_notes)
  returning * into v_row;

  return v_row;
end;
$$;

-- ---------------------------------------------------------------------
-- 4) refund_anticipo: reception_admin ONLY (guard inline, no depende de
--    RLS). Money OUT — modelado como add_cash_movement('expense', ...),
--    NUNCA como income negativo (add_cash_movement no soporta montos
--    negativos). `for update` bloquea la fila para evitar condiciones de
--    carrera entre reembolsos concurrentes sobre el mismo anticipo.
--    Reembolso parcial permitido; rechaza si excede el saldo disponible.
--    NO toca folios ni folio_charges.
-- ---------------------------------------------------------------------
create or replace function public.refund_anticipo(
  p_anticipo_id uuid,
  p_refund_bs   numeric,
  p_reason      text
) returns public.anticipos
language plpgsql
security definer
set search_path = public
as $$
declare
  v_anticipo  public.anticipos;
  v_movement  public.cash_movements;
  v_remaining numeric(10,2);
  v_new_status text;
begin
  if public.current_user_role() <> 'reception_admin' then
    raise exception 'Solo reception_admin puede reembolsar anticipos';
  end if;

  if p_reason is null or char_length(trim(p_reason)) = 0 then
    raise exception 'La justificación es obligatoria';
  end if;

  if p_refund_bs is null or p_refund_bs <= 0 then
    raise exception 'El monto a reembolsar debe ser positivo';
  end if;

  select * into v_anticipo from public.anticipos where id = p_anticipo_id for update;
  if not found then
    raise exception 'Anticipo no encontrado';
  end if;

  v_remaining := v_anticipo.amount_bs - v_anticipo.refunded_amount_bs;
  if p_refund_bs > v_remaining then
    raise exception 'El reembolso (%) excede el saldo disponible (%)', p_refund_bs, v_remaining;
  end if;

  v_movement := public.add_cash_movement(
    'expense', 'reembolso_anticipo', p_refund_bs,
    'Reembolso anticipo ' || p_anticipo_id, null, v_anticipo.payment_method
  );

  v_new_status := case when p_refund_bs = v_remaining then 'refunded' else 'partially_refunded' end;

  update public.anticipos
    set refunded_amount_bs = refunded_amount_bs + p_refund_bs,
        status = v_new_status
    where id = p_anticipo_id;

  insert into public.anticipo_corrections (anticipo_id, action, refund_amount_bs, cash_movement_id, reason)
  values (p_anticipo_id, 'refund', p_refund_bs, v_movement.id, p_reason);

  select * into v_anticipo from public.anticipos where id = p_anticipo_id;
  return v_anticipo;
end;
$$;

-- ---------------------------------------------------------------------
-- 5) modify_anticipo: reception_admin ONLY (guard inline). Solo permitido
--    mientras status='active' — se congela permanentemente en cuanto
--    existe CUALQUIER reembolso (decisión de diseño confirmada, no se
--    permite modificar partially_refunded). El original NUNCA se pierde:
--    se escribe una fila en anticipo_corrections con los valores previos
--    antes de aplicar el update.
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
    raise exception 'No se puede modificar un anticipo ya reembolsado (total o parcialmente)';
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

-- Grants: record/refund/modify son invocables por cualquier usuario
-- autenticado, pero el guard de rol dentro de cada función bloquea a
-- quien no tenga el rol requerido (mismo patrón que
-- approve_rate_discount_request / reject_rate_discount_request). No se
-- introduce ningún helper interno sin guard propio en este cambio, así
-- que no se requieren revokes adicionales — si en el futuro se agrega un
-- helper compartido sin guard propio (p.ej. un "get remaining balance"
-- en SQL), DEBE recibir
-- `revoke execute on function public.<fn>(<argtypes>) from public, anon, authenticated;`
-- explícito (nombrando anon y authenticated), ya que este esquema otorga
-- EXECUTE a anon/authenticated por defecto en funciones nuevas
-- (ALTER DEFAULT PRIVILEGES, ver discount-approval-workflow).
grant execute on function public.record_anticipo(uuid, numeric, text, text) to authenticated;
grant execute on function public.refund_anticipo(uuid, numeric, text) to authenticated;
grant execute on function public.modify_anticipo(uuid, numeric, text, text) to authenticated;
