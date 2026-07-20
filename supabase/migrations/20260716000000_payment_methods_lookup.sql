-- =====================================================================
-- ADOPCIÓN de `public.payment_methods` — la tabla YA EXISTE, creada en
-- 20260703130000_seed_channels_and_payments.sql a partir del ETL del
-- histórico (etl/output/stg_estadias.csv). Forma real:
--   payment_methods (code varchar(20) PK, label varchar(60), is_active bool)
-- con 10 códigos canónicos EN MAYÚSCULA: EFECTIVO, TARJETA, DEPOSITO,
-- TRANSFERENCIA, QR, CTAS_POR_COBRAR, MIXTO, CORTESIA, INTERCAMBIO, OTRO.
-- Ya tiene RLS (`dev_all_payments`, permisiva).
--
-- Este archivo originalmente intentaba RECREAR la tabla con otro shape
-- (columnas `active`/`sort_order`, 4 valores en minúscula) — eso rompió
-- `supabase db push` porque insertaba `sort_order` sobre la tabla real
-- que no tiene esa columna. Corregido: NO se toca `payment_methods`, solo
-- se agregan los usos aditivos que sí son nuevos (FK desde cash_movements
-- y reservations, y las funciones que validan contra el catálogo real).
-- =====================================================================

-- ---------- cash_movements gana payment_method (nullable: hay movimientos
-- que no son "pagos", ej. reposición de caja chica, gasto varios) ----------
alter table public.cash_movements
  add column if not exists payment_method text references public.payment_methods(code);

-- ---------- reservations.payment_method pasa a estar validado por FK,
-- no por CHECK inline. OJO: el flujo de check-out (check_out_room, desde
-- 20260709010000) venía escribiendo los códigos en MINÚSCULAS
-- (efectivo/qr/transferencia/tarjeta), mientras el catálogo del ETL usa
-- MAYÚSCULAS. Antes de validar el FK normalizamos los datos operativos
-- existentes a mayúscula (mapeo 1:1 y sin pérdida). Si quedara algún valor
-- fuera del catálogo, validate constraint falla ruidosamente en el push. ----------
update public.reservations
  set payment_method = upper(payment_method)
  where payment_method is not null
    and payment_method <> upper(payment_method);

alter table public.reservations
  add constraint reservations_payment_method_fkey
  foreign key (payment_method) references public.payment_methods(code)
  not valid;
alter table public.reservations validate constraint reservations_payment_method_fkey;

-- ---------- check_out_room: reemplaza el CHECK inline por una validación
-- contra la tabla de referencia real (columna is_active, códigos en
-- mayúscula) ----------
create or replace function public.check_out_room(
  p_room_id uuid,
  p_payment_method text default 'EFECTIVO'
)
returns numeric
language plpgsql
as $$
declare
  v_reservation_id uuid;
  v_room_total     numeric(10,2);
  v_extras         numeric(10,2);
  v_total          numeric(10,2);
  v_status         varchar(15);
begin
  if not exists (
    select 1 from public.payment_methods where code = p_payment_method and is_active
  ) then
    raise exception 'Forma de pago inválida: %', p_payment_method;
  end if;

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

  select coalesce(sum(fc.amount_bs), 0) into v_extras
  from public.folio_charges fc
  join public.folios f on f.id = fc.folio_id
  where f.reservation_id = v_reservation_id;

  v_total := coalesce(v_room_total, 0) + v_extras;

  -- Registrar forma de pago y marcar cobrada.
  update public.reservations
    set payment_method = p_payment_method, payment_status = 'paid'
    where id = v_reservation_id;

  -- Efectivo -> alimenta la caja (requiere caja abierta; si no, revierte todo).
  if p_payment_method = 'EFECTIVO' and v_total > 0 then
    perform public.add_cash_movement(
      'income', 'cobro_habitacion', v_total,
      'Check-out habitación', null, p_payment_method
    );
  end if;

  update public.reservations set status = 'checked_out' where id = v_reservation_id;
  update public.folios set closed_at = now() where reservation_id = v_reservation_id;
  update public.rooms set operational_status = 'dirty' where id = p_room_id;

  return v_total;
end;
$$;

-- ---------- add_cash_movement: nueva firma con p_payment_method (opcional,
-- porque no todo movimiento de caja es un "pago" -- reposiciones, gastos
-- varios, etc. no tienen forma de pago asociada) ----------
drop function if exists public.add_cash_movement(text, text, numeric, text, text);

create or replace function public.add_cash_movement(
  p_kind text, p_category text, p_amount numeric,
  p_concept text, p_receipt_path text, p_payment_method text default null
) returns public.cash_movements
language plpgsql security definer set search_path = public as $$
declare v_session uuid; row public.cash_movements;
begin
  if public.current_user_role() not in ('root', 'reception') then
    raise exception 'No autorizado';
  end if;
  select id into v_session from public.cash_sessions where status = 'open';
  if v_session is null then
    raise exception 'No hay una caja abierta';
  end if;
  if p_kind not in ('income', 'expense') then
    raise exception 'Tipo inválido';
  end if;
  if p_payment_method is not null
     and not exists (select 1 from public.payment_methods where code = p_payment_method and is_active) then
    raise exception 'Forma de pago inválida: %', p_payment_method;
  end if;
  insert into public.cash_movements
    (session_id, kind, category, amount_bs, concept, receipt_path, created_by, payment_method)
    values (v_session, p_kind, p_category, p_amount, p_concept, p_receipt_path, auth.uid(), p_payment_method)
    returning * into row;
  return row;
end $$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function public.check_out_room(uuid, text) to anon, authenticated;
    grant execute on function public.add_cash_movement(text, text, numeric, text, text, text) to authenticated;
  end if;
end$$;
