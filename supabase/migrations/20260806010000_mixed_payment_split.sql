-- =====================================================================
-- Pago mixto: se parte en efectivo + un medio electrónico.
-- (change: mixed-payment-split)
--
-- MIXTO existía en el catálogo desde el seed inicial pero nunca fue
-- utilizable: no había dónde decir CUÁNTO fue en efectivo y cuánto no, así
-- que 20260806000000 lo dejó explícitamente fuera de
-- `payment_records_income` ("no se puede atribuir a un medio sin inventar
-- el dato"). Ahora recepción da el desglose, así que el dato existe y el
-- cobro puede registrarse.
--
-- MODELO: MIXTO no genera un movimiento de caja propio. Genera DOS —
-- uno EFECTIVO y uno QR/TARJETA — porque son plata que entra por canales
-- distintos: el primero va al cajón y cuenta para el arqueo, el segundo
-- no. Un único movimiento "MIXTO" volvería a mezclar justamente lo que la
-- pestaña "Otros medios" separa.
--
-- El desglose se valida en la RPC: la suma tiene que dar el total exacto.
-- Si no cuadrara, la caja arrancaría descuadrada desde el minuto cero.
-- =====================================================================

create or replace function public.record_mixed_income(
  p_total             numeric,
  p_cash_bs           numeric,
  p_non_cash_bs       numeric,
  p_non_cash_method   text,
  p_category          text,
  p_concept           text,
  p_receipt_path      text default null,
  p_payment_reference text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cash_mov public.cash_movements;
  v_cash_id  uuid;
begin
  if p_non_cash_method not in ('QR', 'TARJETA') then
    raise exception 'La parte no-efectivo debe ser QR o TARJETA (recibido: %)',
      coalesce(p_non_cash_method, 'nada');
  end if;

  if coalesce(p_cash_bs, 0) < 0 or coalesce(p_non_cash_bs, 0) < 0 then
    raise exception 'Los montos del pago mixto no pueden ser negativos';
  end if;

  if coalesce(p_cash_bs, 0) = 0 or coalesce(p_non_cash_bs, 0) = 0 then
    raise exception 'Un pago mixto necesita monto en efectivo Y en %; si es uno solo, elegí ese medio',
      p_non_cash_method;
  end if;

  -- El desglose tiene que dar el total exacto. Tolerancia de 1 centavo por
  -- el redondeo de numeric(10,2), no por descuido.
  if abs((p_cash_bs + p_non_cash_bs) - p_total) > 0.01 then
    raise exception 'El desglose (% + % = %) no coincide con el total a cobrar (%)',
      p_cash_bs, p_non_cash_bs, p_cash_bs + p_non_cash_bs, p_total;
  end if;

  -- La parte electrónica exige su respaldo, igual que un pago simple.
  perform public.assert_payment_proof(
    p_non_cash_method, p_payment_reference, p_receipt_path
  );

  v_cash_mov := public.add_cash_movement(
    'income', p_category, p_cash_bs,
    p_concept || ' (mixto: efectivo)', null, 'EFECTIVO', null
  );
  v_cash_id := v_cash_mov.id;

  perform public.add_cash_movement(
    'income', p_category, p_non_cash_bs,
    p_concept || ' (mixto: ' || lower(p_non_cash_method) || ')',
    p_receipt_path, p_non_cash_method, p_payment_reference
  );

  -- Devuelve el movimiento en EFECTIVO: es el que afecta el cajón y el
  -- que hay que poder rastrear desde el arqueo.
  return v_cash_id;
end;
$$;

revoke execute on function public.record_mixed_income(
  numeric, numeric, numeric, text, text, text, text, text
) from public, anon, authenticated;

comment on function public.record_mixed_income is
  'Registra un cobro mixto como DOS movimientos de caja (efectivo + '
  'QR/TARJETA). Valida que el desglose sume el total exacto. Devuelve el '
  'id del movimiento en efectivo. Sólo se llama desde otras RPC.';

-- ---------------------------------------------------------------------
-- 1) check_out_room: +3 parámetros de desglose. Cambia la aridad, así que
--    hay que dropear la firma previa o PostgREST queda ambiguo.
-- ---------------------------------------------------------------------
drop function if exists public.check_out_room(uuid, text, text, text, uuid);

create or replace function public.check_out_room(
  p_room_id               uuid,
  p_payment_method        text default 'EFECTIVO',
  p_receipt_path          text default null,
  p_payment_reference     text default null,
  p_receivable_account_id uuid default null,
  p_cash_bs               numeric default null,
  p_non_cash_bs           numeric default null,
  p_non_cash_method       text default null
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

  -- En MIXTO el respaldo pertenece a la parte electrónica, no al método
  -- 'MIXTO' en sí: lo valida record_mixed_income más abajo.
  if p_payment_method <> 'MIXTO' then
    perform public.assert_payment_proof(p_payment_method, p_payment_reference, p_receipt_path);
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
        payment_reference = nullif(trim(p_payment_reference), '')
    where id = v_reservation_id;

  if p_payment_method = 'CTAS_POR_COBRAR' then
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

    if p_payment_method = 'MIXTO' and v_total > 0 then
      perform public.record_mixed_income(
        v_total, p_cash_bs, p_non_cash_bs, p_non_cash_method,
        'cobro_habitacion', 'Check-out Hab. ' || coalesce(v_room_number, '?'),
        p_receipt_path, p_payment_reference
      );
    elsif public.payment_records_income(p_payment_method) and v_total > 0
       and (public.current_user_role() <> 'root'
            or exists (select 1 from public.cash_sessions where status = 'open')) then
      perform public.add_cash_movement(
        'income', 'cobro_habitacion', v_total,
        'Check-out Hab. ' || coalesce(v_room_number, '?'),
        p_receipt_path, p_payment_method, p_payment_reference
      );
    end if;
  end if;

  update public.reservations set status = 'checked_out' where id = v_reservation_id;
  update public.folios set closed_at = now() where reservation_id = v_reservation_id;
  update public.rooms set operational_status = 'dirty' where id = p_room_id;

  return v_total;
end;
$$;

grant execute on function public.check_out_room(
  uuid, text, text, text, uuid, numeric, numeric, text
) to authenticated;

-- ---------------------------------------------------------------------
-- 2) record_anticipo: MIXTO también se puede elegir al registrar un
--    anticipo. El anticipo guarda una sola forma de pago ('MIXTO') y
--    apunta al movimiento en efectivo; el desglose vive en los dos
--    movimientos de caja.
-- ---------------------------------------------------------------------
drop function if exists public.record_anticipo(uuid, numeric, text, text, text, text);

create or replace function public.record_anticipo(
  p_reservation_id    uuid,
  p_amount_bs         numeric,
  p_payment_method    text,
  p_notes             text default null,
  p_receipt_path      text default null,
  p_payment_reference text default null,
  p_cash_bs           numeric default null,
  p_non_cash_bs       numeric default null,
  p_non_cash_method   text default null
) returns public.anticipos
language plpgsql
security definer
set search_path = public
as $$
declare
  v_movement public.cash_movements;
  v_mov_id   uuid;
  v_row      public.anticipos;
  v_ref      text := nullif(trim(p_payment_reference), '');
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

  if p_payment_method = 'MIXTO' then
    v_mov_id := public.record_mixed_income(
      p_amount_bs, p_cash_bs, p_non_cash_bs, p_non_cash_method,
      'adelanto', 'Anticipo reserva ' || p_reservation_id,
      p_receipt_path, v_ref
    );
  else
    perform public.assert_payment_proof(p_payment_method, v_ref, p_receipt_path);
    v_movement := public.add_cash_movement(
      'income', 'adelanto', p_amount_bs,
      'Anticipo reserva ' || p_reservation_id, p_receipt_path, p_payment_method, v_ref
    );
    v_mov_id := v_movement.id;
  end if;

  insert into public.anticipos (
    reservation_id, amount_bs, payment_method, cash_movement_id, notes,
    receipt_path, payment_reference
  )
  values (
    p_reservation_id, p_amount_bs, p_payment_method, v_mov_id, p_notes,
    p_receipt_path, v_ref
  )
  returning * into v_row;

  return v_row;
end;
$$;

grant execute on function public.record_anticipo(
  uuid, numeric, text, text, text, text, numeric, numeric, text
) to authenticated;

-- ---------------------------------------------------------------------
-- 3) settle_receivable: idem al cobrar una deuda.
-- ---------------------------------------------------------------------
drop function if exists public.settle_receivable(uuid, text, text, text);

create or replace function public.settle_receivable(
  p_id                uuid,
  p_method            text,
  p_receipt_path      text default null,
  p_payment_reference text default null,
  p_cash_bs           numeric default null,
  p_non_cash_bs       numeric default null,
  p_non_cash_method   text default null
) returns public.receivables
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row      public.receivables;
  v_movement public.cash_movements;
  v_mov_id   uuid;
  v_ref      text := nullif(trim(p_payment_reference), '');
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

  if p_method = 'MIXTO' then
    v_mov_id := public.record_mixed_income(
      v_row.amount_bs, p_cash_bs, p_non_cash_bs, p_non_cash_method,
      'cobro_cuenta', 'Cobro cuenta por cobrar', p_receipt_path, v_ref
    );
  else
    perform public.assert_payment_proof(p_method, v_ref, p_receipt_path);
    if public.payment_records_income(p_method) then
      v_movement := public.add_cash_movement(
        'income', 'cobro_cuenta', v_row.amount_bs,
        'Cobro cuenta por cobrar', p_receipt_path, p_method, v_ref
      );
      v_mov_id := v_movement.id;
    end if;
  end if;

  update public.receivables
    set status = 'paid', settled_by = auth.uid(), settled_at = now(),
        settle_method = p_method, cash_movement_id = v_mov_id,
        settle_receipt_path = p_receipt_path, settle_payment_reference = v_ref
    where id = p_id
    returning * into v_row;

  if v_row.reservation_id is not null then
    update public.reservations set payment_status = 'paid' where id = v_row.reservation_id;
  end if;

  return v_row;
end;
$$;

grant execute on function public.settle_receivable(
  uuid, text, text, text, numeric, numeric, text
) to authenticated;
