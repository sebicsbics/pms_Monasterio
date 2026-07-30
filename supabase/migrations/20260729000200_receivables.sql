-- =====================================================================
-- Cuentas por cobrar (change: receivables).
--
-- Hasta ahora 'CTAS_POR_COBRAR' era solo una etiqueta de método de pago y
-- el check-out marcaba la reserva como 'paid' igual. Ahora:
--   - receivable_accounts: cuentas de clientes/convenios (empresa/agencia/
--     persona).
--   - receivables: cada deuda (cuenta + reserva + monto + estado).
--   - check_out_room con método CTAS_POR_COBRAR crea un receivable
--     'pending' contra una cuenta y deja la reserva 'pending' (NO 'paid').
--   - settle_receivable / cancel_receivable para cobrar o anular.
--
-- Gestión (crear cuenta, saldar, anular): root/reception/reception_admin.
-- Lectura: además accountant.
-- =====================================================================

create table if not exists public.receivable_accounts (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(trim(name)) > 0),
  kind       text not null check (kind in ('empresa', 'agencia', 'persona')),
  contact    text,
  notes      text,
  is_active  boolean not null default true,
  created_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now()
);

alter table public.receivable_accounts enable row level security;
drop policy if exists "receivable_accounts_ops" on public.receivable_accounts;
create policy "receivable_accounts_ops" on public.receivable_accounts
  for all
  using (public.current_user_role() in ('root', 'reception', 'reception_admin'))
  with check (public.current_user_role() in ('root', 'reception', 'reception_admin'));
drop policy if exists "receivable_accounts_read_acct" on public.receivable_accounts;
create policy "receivable_accounts_read_acct" on public.receivable_accounts
  for select using (public.current_user_role() = 'accountant');

create table if not exists public.receivables (
  id               uuid primary key default gen_random_uuid(),
  account_id       uuid not null references public.receivable_accounts(id),
  reservation_id   uuid references public.reservations(id),
  amount_bs        numeric(10,2) not null check (amount_bs > 0),
  concept          text,
  status           text not null default 'pending'
                     check (status in ('pending', 'paid', 'cancelled')),
  created_by       uuid references public.profiles(id) default auth.uid(),
  created_at       timestamptz not null default now(),
  settled_by       uuid references public.profiles(id),
  settled_at       timestamptz,
  settle_method    text references public.payment_methods(code),
  cash_movement_id uuid references public.cash_movements(id),
  cancel_reason    text
);
create index if not exists idx_receivables_account on public.receivables (account_id);
create index if not exists idx_receivables_status on public.receivables (status);

alter table public.receivables enable row level security;
drop policy if exists "receivables_ops" on public.receivables;
create policy "receivables_ops" on public.receivables
  for all
  using (public.current_user_role() in ('root', 'reception', 'reception_admin'))
  with check (public.current_user_role() in ('root', 'reception', 'reception_admin'));
drop policy if exists "receivables_read_acct" on public.receivables;
create policy "receivables_read_acct" on public.receivables
  for select using (public.current_user_role() = 'accountant');

-- ---------------------------------------------------------------------
-- check_out_room: +p_receivable_account_id. Si el método es
-- CTAS_POR_COBRAR crea un receivable pendiente contra la cuenta elegida y
-- deja la reserva 'pending' (no 'paid'), sin tocar caja. Drop del overload
-- de 4 args antes de crear el de 5. Conserva la excepción de root sin caja.
-- ---------------------------------------------------------------------
drop function if exists public.check_out_room(uuid, text, text, text);

create function public.check_out_room(
  p_room_id             uuid,
  p_payment_method      text default 'EFECTIVO',
  p_receipt_path        text default null,
  p_payment_reference   text default null,
  p_receivable_account_id uuid default null
) returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reservation_id uuid;
  v_room_total     numeric(10,2);
  v_extras         numeric(10,2);
  v_total          numeric(10,2);
  v_status         varchar(15);
  v_room_number    text;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin', 'accountant') then
    raise exception 'No autorizado para hacer check-out';
  end if;

  if not exists (
    select 1 from public.payment_methods where code = p_payment_method and is_active
  ) then
    raise exception 'Forma de pago inválida: %', p_payment_method;
  end if;

  select operational_status, room_number into v_status, v_room_number
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

  select coalesce(sum(fc.amount_bs), 0) into v_extras
  from public.folio_charges fc
  join public.folios f on f.id = fc.folio_id
  where f.reservation_id = v_reservation_id;

  v_total := coalesce(v_room_total, 0) + v_extras;

  update public.reservations
    set payment_method = p_payment_method,
        receipt_path = p_receipt_path,
        payment_reference = p_payment_reference
    where id = v_reservation_id;

  if p_payment_method = 'CTAS_POR_COBRAR' then
    -- Cuenta por cobrar: queda pendiente de cobro, se registra la deuda.
    if p_receivable_account_id is null then
      raise exception 'Elegí la cuenta por cobrar a la que se factura';
    end if;
    if not exists (select 1 from public.receivable_accounts where id = p_receivable_account_id and is_active) then
      raise exception 'Cuenta por cobrar inválida o inactiva';
    end if;

    update public.reservations set payment_status = 'pending' where id = v_reservation_id;

    if v_total > 0 then
      insert into public.receivables (account_id, reservation_id, amount_bs, concept)
      values (p_receivable_account_id, v_reservation_id, v_total,
              'Hospedaje Hab. ' || coalesce(v_room_number, '?'));
    end if;
  else
    update public.reservations set payment_status = 'paid' where id = v_reservation_id;

    -- Efectivo -> caja (excepción de root sin caja, ver 20260727000400).
    if p_payment_method = 'EFECTIVO' and v_total > 0
       and (public.current_user_role() <> 'root'
            or exists (select 1 from public.cash_sessions where status = 'open')) then
      perform public.add_cash_movement(
        'income', 'cobro_habitacion', v_total,
        'Check-out habitación', null, p_payment_method
      );
    end if;
  end if;

  update public.reservations set status = 'checked_out' where id = v_reservation_id;
  update public.folios set closed_at = now() where reservation_id = v_reservation_id;
  update public.rooms set operational_status = 'dirty' where id = p_room_id;

  return v_total;
end;
$$;

grant execute on function public.check_out_room(uuid, text, text, text, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- settle_receivable: cobra una deuda pendiente. En EFECTIVO alimenta la
-- caja (requiere caja abierta). Marca la reserva asociada como 'paid'.
-- ---------------------------------------------------------------------
create or replace function public.settle_receivable(
  p_id     uuid,
  p_method text
) returns public.receivables
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row      public.receivables;
  v_movement public.cash_movements;
  v_mov_id   uuid;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado';
  end if;
  if not exists (select 1 from public.payment_methods where code = p_method and is_active) then
    raise exception 'Forma de pago inválida: %', p_method;
  end if;

  select * into v_row from public.receivables where id = p_id for update;
  if not found then
    raise exception 'Cuenta por cobrar no encontrada';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'La deuda ya no está pendiente (estado: %)', v_row.status;
  end if;

  if p_method = 'EFECTIVO' then
    v_movement := public.add_cash_movement(
      'income', 'cobro_cuenta', v_row.amount_bs,
      'Cobro cuenta por cobrar', null, p_method
    );
    v_mov_id := v_movement.id;
  end if;

  update public.receivables
    set status = 'paid', settled_by = auth.uid(), settled_at = now(),
        settle_method = p_method, cash_movement_id = v_mov_id
    where id = p_id
    returning * into v_row;

  if v_row.reservation_id is not null then
    update public.reservations set payment_status = 'paid' where id = v_row.reservation_id;
  end if;

  return v_row;
end;
$$;

grant execute on function public.settle_receivable(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- cancel_receivable: anula una deuda pendiente con justificación.
-- ---------------------------------------------------------------------
create or replace function public.cancel_receivable(
  p_id     uuid,
  p_reason text
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado';
  end if;
  if p_reason is null or char_length(trim(p_reason)) = 0 then
    raise exception 'La justificación es obligatoria';
  end if;

  update public.receivables
    set status = 'cancelled', cancel_reason = trim(p_reason)
    where id = p_id and status = 'pending';

  if not found then
    raise exception 'Cuenta por cobrar no encontrada o ya resuelta';
  end if;
end;
$$;

grant execute on function public.cancel_receivable(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- list_receivables: deudas con nombre de cuenta, habitación y huésped
-- resueltos server-side. Filtros opcionales por cuenta y estado.
-- ---------------------------------------------------------------------
create or replace function public.list_receivables(
  p_account_id uuid default null,
  p_status     text default null
) returns table (
  id             uuid,
  account_id     uuid,
  account_name   text,
  reservation_id uuid,
  room_number    text,
  guest_name     text,
  amount_bs      numeric,
  concept        text,
  status         text,
  created_at     timestamptz,
  settled_at     timestamptz,
  settle_method  text,
  cancel_reason  text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin', 'accountant') then
    raise exception 'No autorizado';
  end if;

  return query
    select
      r.id, r.account_id, ra.name::text, r.reservation_id,
      rm.room_number::text,
      (p.first_name || ' ' || p.last_name)::text,
      r.amount_bs, r.concept, r.status, r.created_at,
      r.settled_at, r.settle_method, r.cancel_reason
    from public.receivables r
    join public.receivable_accounts ra on ra.id = r.account_id
    left join public.reservations res on res.id = r.reservation_id
    left join public.rooms rm on rm.id = res.room_id
    left join public.guests g on g.person_id = res.guest_id
    left join public.people p on p.id = g.person_id
    where (p_account_id is null or r.account_id = p_account_id)
      and (p_status is null or r.status = p_status)
    order by r.created_at desc;
end;
$$;

grant execute on function public.list_receivables(uuid, text) to authenticated;
