-- =====================================================================
-- FIX: corregir un anticipo no ajustaba la caja. + soporte de MIXTO.
-- (change: fix-modify-anticipo-cash)
--
-- EL BUG (original del módulo, 20260723000000)
-- `modify_anticipo` actualizaba la fila del anticipo y escribía la fila de
-- auditoría, pero NUNCA tocaba `cash_movements`. Corregir un anticipo de
-- 900 a 450 dejaba el movimiento de caja en 900: el anticipo y la caja
-- divergían en silencio, y el arqueo mostraba plata que ya no correspondía.
-- Verificado en producción antes de este cambio.
--
-- LA REGLA: NO SE REESCRIBE UN ARQUEO YA CERRADO
--   - Si el movimiento original pertenece a un turno TODAVÍA ABIERTO, se
--     anula y se registra el corregido en ese mismo turno. El turno no
--     estaba cerrado, así que nadie firmó ese número.
--   - Si el turno YA SE CERRÓ, el movimiento original queda INTACTO y el
--     ajuste se registra como contraasiento en la caja de hoy: una salida
--     por el monto viejo y una entrada por el nuevo. Es la regla contable
--     estándar — un período cerrado no se toca, se compensa.
--
-- El contraasiento usa la MISMA forma de pago del movimiento que revierte,
-- así el ajuste cae en la misma pestaña (efectivo u otros medios) que el
-- cobro original y ninguna de las dos queda descuadrada.
-- =====================================================================

drop function if exists public.modify_anticipo(uuid, numeric, text, text, text, text);

create or replace function public.modify_anticipo(
  p_anticipo_id        uuid,
  p_new_amount_bs      numeric,
  p_new_payment_method text,
  p_reason             text,
  p_receipt_path       text default null,
  p_payment_reference  text default null,
  p_cash_bs            numeric default null,
  p_non_cash_bs        numeric default null,
  p_non_cash_method    text default null
) returns public.anticipos
language plpgsql
security definer
set search_path = public
as $$
declare
  v_anticipo   public.anticipos;
  v_row        public.anticipos;
  v_ref        text := nullif(trim(p_payment_reference), '');
  v_old_mov    public.cash_movements;
  v_old_open   boolean := false;
  v_new_mov    public.cash_movements;
  v_new_mov_id uuid;
  v_concept    text;
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
    raise exception 'El anticipo está perdido (reserva cancelada): no se puede modificar';
  end if;

  if p_new_amount_bs is null or p_new_amount_bs <= 0 then
    raise exception 'El monto debe ser positivo';
  end if;

  if not exists (
    select 1 from public.payment_methods where code = p_new_payment_method and is_active
  ) then
    raise exception 'Forma de pago inválida: %', p_new_payment_method;
  end if;

  -- Corregir sólo el monto no debe borrar el comprobante ya cargado.
  if p_new_payment_method = v_anticipo.payment_method then
    p_receipt_path := coalesce(p_receipt_path, v_anticipo.receipt_path);
    v_ref          := coalesce(v_ref, v_anticipo.payment_reference);
  end if;

  v_concept := 'Anticipo reserva ' || v_anticipo.reservation_id;

  -- ---------- 1) Deshacer el movimiento anterior ----------
  if v_anticipo.cash_movement_id is not null then
    select m.* into v_old_mov
    from public.cash_movements m where m.id = v_anticipo.cash_movement_id;

    if found and not v_old_mov.voided then
      select (s.status = 'open') into v_old_open
      from public.cash_sessions s where s.id = v_old_mov.session_id;

      if v_old_open then
        -- Turno abierto: se anula en su lugar, nadie firmó ese arqueo.
        update public.cash_movements set
          voided = true, voided_by = auth.uid(), voided_at = now(),
          void_reason = 'Corrección de anticipo: ' || trim(p_reason)
        where id = v_old_mov.id;
      else
        -- Turno cerrado: NO se toca. Contraasiento en la caja de hoy.
        -- Se arrastra el respaldo del movimiento original: un
        -- contraasiento revierte un cobro que YA tiene su comprobante, y
        -- exigir una foto nueva para deshacer un asiento por QR haría
        -- imposible la corrección (assert_payment_proof la rechaza).
        perform public.add_cash_movement(
          'expense', 'ajuste_anticipo', v_old_mov.amount_bs,
          'Reversión ' || v_concept || ' (corrección)',
          v_old_mov.receipt_path, v_old_mov.payment_method, v_old_mov.payment_reference
        );
      end if;
    end if;
  end if;

  -- ---------- 2) Registrar el movimiento corregido ----------
  if p_new_payment_method = 'MIXTO' then
    v_new_mov_id := public.record_mixed_income(
      p_new_amount_bs, p_cash_bs, p_non_cash_bs, p_non_cash_method,
      'adelanto', v_concept || ' (corregido)', p_receipt_path, v_ref
    );
  else
    perform public.assert_payment_proof(p_new_payment_method, v_ref, p_receipt_path);
    v_new_mov := public.add_cash_movement(
      'income', 'adelanto', p_new_amount_bs,
      v_concept || ' (corregido)', p_receipt_path, p_new_payment_method, v_ref
    );
    v_new_mov_id := v_new_mov.id;
  end if;

  -- ---------- 3) Auditoría y actualización ----------
  insert into public.anticipo_corrections (
    anticipo_id, action, previous_amount_bs, previous_payment_method,
    new_amount_bs, new_payment_method, reason
  ) values (
    p_anticipo_id, 'modify', v_anticipo.amount_bs, v_anticipo.payment_method,
    p_new_amount_bs, p_new_payment_method, p_reason
  );

  update public.anticipos set
    amount_bs         = p_new_amount_bs,
    payment_method    = p_new_payment_method,
    cash_movement_id  = v_new_mov_id,
    receipt_path      = p_receipt_path,
    payment_reference = v_ref
  where id = p_anticipo_id
  returning * into v_row;

  return v_row;
end;
$$;

grant execute on function public.modify_anticipo(
  uuid, numeric, text, text, text, text, numeric, numeric, text
) to authenticated;

comment on function public.modify_anticipo is
  'Corrige un anticipo Y ajusta la caja. Si el turno del movimiento '
  'original sigue abierto lo anula ahí; si ya se cerró lo deja intacto y '
  'registra un contraasiento en la caja de hoy — un arqueo cerrado no se '
  'reescribe. Soporta MIXTO vía record_mixed_income.';
