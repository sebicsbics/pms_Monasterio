-- =====================================================================
-- DEPOSITO y TRANSFERENCIA eran el mismo medio de pago con dos nombres.
--
-- ORIGEN: el catálogo canónico (20260703130000_seed_channels_and_payments)
-- se sembró tomando los códigos de la columna de pago del histórico tal
-- cual venían del Excel. Ahí convivían 633 DEPOSITO y 59 TRANSFERENCIA
-- para la misma operación — mismos bancos, misma semántica. Esa migración
-- limpió AIRBNB de esa columna (era un canal, no un pago), pero no vio que
-- dos códigos eran sinónimos, así que promovió el sinónimo a entidad del
-- sistema.
--
-- CONSECUENCIA: quedaron dos listas de "medios que son plata en caja" que
-- no coincidían — payment_records_income incluía TRANSFERENCIA y el
-- desplegable de caja no. El check-out podía crear un movimiento que la
-- caja manual no podía crear. Un solo movimiento real lo expuso
-- (Check-out Hab. 1 del 26/08).
--
-- Y una tercera lista, peor: add_cash_movement validaba contra el catálogo
-- GLOBAL, así que aceptaba CORTESIA, INTERCAMBIO, CTAS_POR_COBRAR, MIXTO y
-- OTRO — cosas que por definición no son plata en el cajón. Lo único que
-- lo impedía era un filtro en el desplegable de React. Seis movimientos
-- CORTESIA anteriores al 05/08 entraron por ahí.
--
-- Este cambio deja UNA fuente de verdad: payment_records_income.
-- (change: unify-deposito-transferencia)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Backfill ANTES de tocar el catálogo: si se desactivara primero, estas
--    filas quedarían apuntando a un código inactivo.
--
--    Idempotente por el WHERE: correrla dos veces no cambia nada.
-- ---------------------------------------------------------------------
update public.reservations   set payment_method = 'DEPOSITO' where payment_method = 'TRANSFERENCIA';
update public.cash_movements set payment_method = 'DEPOSITO' where payment_method = 'TRANSFERENCIA';
update public.anticipos      set payment_method = 'DEPOSITO' where payment_method = 'TRANSFERENCIA';
update public.event_payments set method         = 'DEPOSITO' where method         = 'TRANSFERENCIA';

-- ---------------------------------------------------------------------
-- 2) El código se DESACTIVA, no se borra.
--
--    Borrarlo rompería la FK de cualquier fila que se nos haya escapado, y
--    sobre todo borraría el rastro: dentro de un año, ver el código
--    inactivo explica por qué no aparece en ningún desplegable. Una fila
--    ausente no explica nada.
-- ---------------------------------------------------------------------
update public.payment_methods
  set is_active = false,
      label     = 'Transferencia (unificado en Depósito bancario)'
  where code = 'TRANSFERENCIA';

-- ---------------------------------------------------------------------
-- 3) payment_records_income pasa a ser la ÚNICA lista de medios que
--    mueven plata en caja: sin TRANSFERENCIA, queda exactamente el
--    conjunto que la caja acepta a mano.
--
--    No se crea una función nueva para "medios de caja" justamente porque
--    el problema que este cambio arregla es haber tenido dos listas para
--    el mismo concepto.
-- ---------------------------------------------------------------------
create or replace function public.payment_records_income(p_method text)
returns boolean
language sql
immutable
set search_path = public
as $$
  select p_method in ('EFECTIVO', 'QR', 'TARJETA', 'DEPOSITO');
$$;

comment on function public.payment_records_income(text) is
  'Única fuente de verdad de los medios de pago que mueven plata en caja: '
  'los que representan plata que entra de verdad Y por lo tanto pueden ser '
  'un movimiento de cash_movements. Excluye deuda (CTAS_POR_COBRAR), '
  'cortesías, intercambios y los códigos que no se pueden atribuir a un '
  'medio concreto (MIXTO, OTRO). TRANSFERENCIA salió al unificarse con '
  'DEPOSITO. La usan check_out_room (para decidir si registra el cobro) y '
  'add_cash_movement (para validar lo que le mandan).';

-- ---------------------------------------------------------------------
-- 4) add_cash_movement: valida contra payment_records_income en vez del
--    catálogo global.
--
--    Cuerpo idéntico al vigente (20260805010000_payment_proof_qr_card)
--    salvo esa condición. Misma firma de 7 args, así que no hace falta
--    dropear nada: no hay ambigüedad para PostgREST.
--
--    El null sigue permitido: hay movimientos sin forma de pago (varios,
--    ajustes) y los históricos anteriores a que existiera la columna.
-- ---------------------------------------------------------------------
create or replace function public.add_cash_movement(
  p_kind text, p_category text, p_amount numeric,
  p_concept text, p_receipt_path text,
  p_payment_method text default null,
  p_payment_reference text default null
) returns public.cash_movements
language plpgsql security definer set search_path = public as $$
declare v_session uuid; row public.cash_movements;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
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
     and not public.payment_records_income(p_payment_method) then
    raise exception
      'Forma de pago inválida para caja: %. En un movimiento de caja sólo '
      'entra plata de verdad (efectivo, QR, tarjeta o depósito)',
      p_payment_method;
  end if;
  perform public.assert_payment_proof(p_payment_method, p_payment_reference, p_receipt_path);

  insert into public.cash_movements
    (session_id, kind, category, amount_bs, concept, receipt_path, created_by,
     payment_method, payment_reference)
    values (v_session, p_kind, p_category, p_amount, p_concept, p_receipt_path,
            auth.uid(), p_payment_method, nullif(trim(p_payment_reference), ''))
    returning * into row;
  return row;
end $$;
