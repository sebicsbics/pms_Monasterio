-- =====================================================================
-- Cierre automático del grupo institucional (change: group-billing,
-- stage 6, Slice 5, branch feat/booking-15-close-trigger).
--
-- Cuando la última habitación activa de un booking 'client' termina su
-- estadía (check-out) o se cancela, el grupo se cierra: se audita el
-- saldo neto en booking_balances (evento 'group_closed', SIEMPRE, incluso
-- si el saldo es 0 o negativo -- nunca puede ser negativo desde
-- feat/booking-14, que ya rechaza sobrepagos) y, si queda saldo
-- pendiente, se genera la cuenta por cobrar del booking (spec R5.1-R5.6).
--
-- V-A (verificado en vivo, pg_get_functiondef, antes de escribir esta
-- migración): los ÚNICOS caminos que cambian reservations.status son
-- check_in_reservation (confirmed->checked_in), cancel_reservation
-- (confirmed->cancelled) y check_out_room (checked_in->checked_out).
-- Ningún otro (approve_rate_discount_request/settle_receivable/etc.
-- matchean el grep por casualidad -- inspeccionados uno por uno, tocan
-- total_amount_bs/receivables.status/payment_status, nunca
-- reservations.status). No existe ningún camino de "reapertura": una vez
-- 'checked_out' o 'cancelled', reservations.status es terminal -- el
-- WHEN de este trigger (status in ('checked_out','cancelled') AND
-- old IS DISTINCT FROM new) dispara exactamente una vez por reserva real,
-- nunca dos veces para la misma transición.
--
-- ORDEN DE LOCKS / ANÁLISIS DE DEADLOCK (obligatorio, ver instrucción de
-- apply): se mapeó, leyendo los cuerpos VIVOS, qué lock de fila toma cada
-- camino y en qué orden:
--   * record_booking_advance (feat/booking-14): toma
--     `select * from bookings where id=... for update`. add_cash_movement
--     y record_mixed_income no hacen SELECT ... FOR UPDATE sobre
--     cash_sessions, PERO el INSERT en cash_movements toma un lock
--     IMPLÍCITO `FOR KEY SHARE` sobre la fila de cash_sessions (lo hace
--     Postgres por la FK session_id, en todo INSERT que la referencia).
--     Cadena: [bookings] -> [cash_sessions KEY SHARE].
--   * check_out_room: toma `select ... from rooms where id=... for
--     update` (lock de `rooms`), su cobro también toma KEY SHARE sobre
--     cash_sessions (misma FK), y recién al final hace
--     `update reservations set status='checked_out'` (lock de fila de
--     `reservations`, implícito en el UPDATE) -- ESE update es el que
--     dispara este trigger AFTER, que (solo para bookings 'client') toma
--     el lock de `bookings`. Cadena: [rooms] -> [reservations] ->
--     [bookings].
--   * cancel_reservation: `select status from reservations where id=...
--     for update` (lock de `reservations`), después
--     `update reservations set status='cancelled'` (misma fila, ya
--     bloqueada) dispara el trigger -> [bookings]. Cadena:
--     [reservations] -> [bookings].
--
-- Para que exista un deadlock, DOS transacciones necesitan tomar DOS
-- recursos en orden CRUZADO y con modos que CONFLICTÚEN. El único recurso
-- que record_booking_advance comparte en orden inverso con check_out_room
-- es cash_sessions, y ahí ambos toman FOR KEY SHARE: es compatible
-- consigo mismo y con el FOR NO KEY UPDATE de un UPDATE de cash_sessions
-- que no toque la clave (close_cash_session), así que nunca se esperan
-- entre sí por esa fila (medido con dos sesiones en la review de
-- feat/booking-15). AVISO para cambios futuros: si algún camino que
-- también toque `bookings` pasa a hacer SELECT ... FOR UPDATE / FOR SHARE
-- sobre cash_sessions, o un UPDATE que modifique su clave, este análisis
-- deja de valer y hay que rehacerlo.
-- check_out_room/cancel_reservation SÍ encadenan dos locks cada uno
-- (rooms|reservations -> bookings), pero NINGÚN camino adquiere
-- `bookings` primero y `rooms`/`reservations` después -- así que tampoco
-- hay ciclo entre ellos (dos check-outs concurrentes de habitaciones
-- DISTINTAS del mismo booking simplemente se serializan en el lock de
-- `bookings`: el segundo espera a que el primero termine, no hay orden
-- cruzado). CONCLUSIÓN: no se detectó ningún deadlock posible con el
-- mapeo de locks actual -- no se requiere ningún cambio en
-- record_booking_advance ni en las funciones de checkout/cancelación.
--
-- VERIFICADO END-TO-END en la base local (2026-09-15, dos sesiones
-- psql reales, datos temporales ya borrados):
--   1) check_out_room de la última habitación queda sin commit 8s; un
--      record_booking_advance concurrente sobre el mismo booking espera
--      el lock y, al liberarse, falla con 'Esta reserva de grupo ya está
--      cerrada' (vio el cierre ya confirmado).
--   2) check_out_room concurrente de las dos últimas habitaciones: la
--      segunda espera ~4s el lock de bookings, ve el check-out confirmado
--      de la primera (READ COMMITTED toma snapshot nuevo por sentencia) y
--      cierra el grupo: exactamente 1 group_closed y 1 receivable.
-- =====================================================================

create or replace function public._close_booking_group()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payer_mode text;
  v_account_id uuid;
  v_net        numeric(10,2);
begin
  -- (1) Lectura SIN lock: evita tomar un lock de fila de `bookings` en
  -- CADA check-out/cancelación de una reserva each_stay (el caso común,
  -- la inmensa mayoría de las transiciones de status). payer_mode es
  -- NOT NULL con default 'each_stay' (constraint de Slice 2a,
  -- verificado en vivo: is_nullable=NO) y ninguna función de este repo
  -- lo modifica después de crear el booking -- leerlo sin FOR UPDATE es
  -- seguro: no hay carrera posible sobre un valor que nunca cambia.
  -- `is distinct from` en vez de `<>`: NULL-safe por construcción
  -- (postgres/check-constraint-null-trap, #368), aunque acá payer_mode
  -- nunca sea NULL -- defensa en profundidad, mismo estilo del resto del
  -- cambio.
  select payer_mode into v_payer_mode
  from public.bookings where id = new.booking_id;

  if v_payer_mode is distinct from 'client' then
    return new;
  end if;

  -- (2) Recién acá, SOLO para bookings institucionales, se toma el lock
  -- de fila de `bookings` (mismo lock que ya usa record_booking_advance,
  -- feat/booking-14) -- serializa un cierre en curso contra un adelanto
  -- concurrente y viceversa (ver análisis de deadlock arriba).
  select payer_mode, receivable_account_id into v_payer_mode, v_account_id
  from public.bookings where id = new.booking_id for update;

  -- (3) Todavía quedan habitaciones activas del grupo: no cierra.
  if exists (
    select 1 from public.reservations
    where booking_id = new.booking_id and status in ('confirmed', 'checked_in')
  ) then
    return new;
  end if;

  -- (4) Idempotencia (defensa de aplicación; el unique index de
  -- `receivables` -- Slice 1 -- es la defensa de esquema si esto
  -- fallara igual).
  if exists (
    select 1 from public.booking_balances
    where booking_id = new.booking_id and event_type = 'group_closed'
  ) then
    return new;
  end if;

  -- (5) _net_owed_bs, NUNCA net_owed_bs (el wrapper público guardado por
  -- rol, sdd/group-billing/net-owed-guard #353) -- código interno usa
  -- siempre el helper con underscore. coalesce(...,0)-coalesce(...,0)
  -- por construcción: nunca NULL.
  v_net := public._net_owed_bs(new.booking_id);

  -- (6) SIEMPRE se audita el cierre, incluso con saldo <= 0 (spec R5.3).
  insert into public.booking_balances (booking_id, event_type, amount_bs, notes)
  values (new.booking_id, 'group_closed', v_net, 'Cierre automático del grupo');

  -- (7) Cuenta por cobrar SOLO si queda saldo pendiente (spec R5.4).
  -- receivable_account_id está garantizado NOT NULL para bookings
  -- 'client' (constraint bookings_client_requires_account, Slice 2a) --
  -- la rama "cuenta nula al cerrar" es inalcanzable por construcción.
  -- `on conflict` sobre el unique index parcial de Slice 1 es la última
  -- red de seguridad ante una carrera que el lock de arriba ya debería
  -- haber prevenido.
  if v_net > 0 then
    insert into public.receivables (account_id, booking_id, amount_bs, concept)
    values (v_account_id, new.booking_id, v_net, 'Saldo de grupo/institución')
    on conflict (booking_id) where booking_id is not null do nothing;
  end if;

  return new;
end;
$$;

-- Interna: ni un guard de rol la protege (no lo necesita, solo dispara
-- como trigger) ni debe ser invocable directo -- mismo patrón que
-- _net_owed_bs/_apply_rate_change_direct/_resolve_receivable_account.
revoke execute on function public._close_booking_group() from public, anon, authenticated;

create trigger reservations_close_booking_group
  after update of status on public.reservations
  for each row
  when (new.status in ('checked_out', 'cancelled') and old.status is distinct from new.status)
  execute function public._close_booking_group();
