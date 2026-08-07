-- =====================================================================
-- 1) Historial de caja para arqueos.  2) Modificar fechas (no sólo extender).
-- (change: cash-history-and-stay-dates)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) cash_session_history: turnos de caja en un rango, con todo lo que un
--    arqueo necesita — quién abrió y cuándo, con cuánto abrió y cerró, la
--    diferencia y su justificación.
--
-- El saldo esperado se calcula ACÁ y no en el frontend. Hasta ahora sólo
-- existía para la caja abierta, calculado en React; un arqueo de un mes
-- cerrado necesita el mismo número para turnos que ya nadie tiene en
-- pantalla, y recalcularlo en el cliente para 30 turnos sería traerse
-- todos los movimientos al navegador.
--
-- CLAVE: el esperado cuenta SÓLO efectivo (payment_method null o
-- EFECTIVO), igual que la pestaña "Efectivo". El nulo es de los
-- movimientos anteriores a que existiera la columna: en esa época todo
-- era efectivo. QR/depósito/tarjeta se devuelven aparte, informativos: no
-- pasan por el cajón y no pueden mover el arqueo.
-- ---------------------------------------------------------------------
create or replace function public.cash_session_history(
  p_from date default null,
  p_to   date default null
) returns table (
  id                 uuid,
  opened_at          timestamptz,
  opened_by_name     text,
  opening_balance_bs numeric,
  closed_at          timestamptz,
  closed_by_name     text,
  counted_balance_bs numeric,
  cash_income_bs     numeric,
  cash_expense_bs    numeric,
  expected_bs        numeric,
  difference_bs      numeric,
  other_income_bs    numeric,
  other_expense_bs   numeric,
  movements          int,
  status             text,
  notes              text
)
language sql
stable
security definer
set search_path = public
as $$
  with movs as (
    select
      m.session_id,
      -- Efectivo: lo que de verdad está en el cajón.
      sum(case when (m.payment_method is null or m.payment_method = 'EFECTIVO')
                and m.kind = 'income'  then m.amount_bs else 0 end) as cash_in,
      sum(case when (m.payment_method is null or m.payment_method = 'EFECTIVO')
                and m.kind = 'expense' then m.amount_bs else 0 end) as cash_out,
      sum(case when m.payment_method is not null and m.payment_method <> 'EFECTIVO'
                and m.kind = 'income'  then m.amount_bs else 0 end) as other_in,
      sum(case when m.payment_method is not null and m.payment_method <> 'EFECTIVO'
                and m.kind = 'expense' then m.amount_bs else 0 end) as other_out,
      count(*) as n
    from public.cash_movements m
    where not m.voided          -- los anulados no cuentan para el arqueo
    group by m.session_id
  )
  select
    s.id,
    s.opened_at,
    coalesce(nullif(trim(pro.full_name), ''), pro.username, '—'),
    s.opening_balance_bs,
    s.closed_at,
    coalesce(nullif(trim(prc.full_name), ''), prc.username),
    s.counted_balance_bs,
    coalesce(mv.cash_in, 0),
    coalesce(mv.cash_out, 0),
    s.opening_balance_bs + coalesce(mv.cash_in, 0) - coalesce(mv.cash_out, 0),
    -- Diferencia sólo si la caja se cerró: en una abierta no hay conteo.
    case when s.counted_balance_bs is null then null
         else s.counted_balance_bs
              - (s.opening_balance_bs + coalesce(mv.cash_in, 0) - coalesce(mv.cash_out, 0))
    end,
    coalesce(mv.other_in, 0),
    coalesce(mv.other_out, 0),
    coalesce(mv.n, 0)::int,
    s.status,
    s.notes
  from public.cash_sessions s
  left join movs mv on mv.session_id = s.id
  left join public.profiles pro on pro.id = s.opened_by
  left join public.profiles prc on prc.id = s.closed_by
  where public.current_user_role() in ('root', 'reception_admin', 'accountant')
    and (p_from is null or s.opened_at >= p_from::timestamptz)
    and (p_to   is null or s.opened_at <  (p_to + 1)::timestamptz)
  order by s.opened_at desc;
$$;

grant execute on function public.cash_session_history(date, date) to authenticated;

comment on function public.cash_session_history(date, date) is
  'Turnos de caja con el arqueo resuelto server-side: esperado (sólo '
  'efectivo), contado, diferencia y justificación. Sólo root, '
  'reception_admin y accountant — el guard de rol está en el WHERE porque '
  'la función es SECURITY DEFINER.';

-- ---------------------------------------------------------------------
-- 2) modify_stay_dates: reemplaza a extend_stay.
--
-- Extender era la mitad del problema: el huésped también se va antes de lo
-- previsto, y ahí hay que QUITAR noches y dejar de cobrarlas. Con tramos
-- eso es recortar: se borran los que empiezan después de la nueva salida y
-- se trunca el que la cruza.
--
-- La tarifa sólo se pide al EXTENDER (las noches nuevas hay que valorarlas).
-- Al acortar no se pregunta nada: las noches que quedan ya tienen su precio.
--
-- No se permite mover la salida a antes de hoy: serían noches ya dormidas,
-- y descontarlas convertiría una corrección en un descuento sin rastro.
-- ---------------------------------------------------------------------
drop function if exists public.extend_stay(uuid, date, numeric, text);

create or replace function public.modify_stay_dates(
  p_room_id       uuid,
  p_new_check_out date,
  p_rate_bs       numeric default null,
  p_reason        text default null
) returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_res  public.reservations;
  v_last public.stay_segments;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado para modificar las fechas de la estadía';
  end if;

  select * into v_res
  from public.reservations
  where room_id = p_room_id and status = 'checked_in'
  order by check_in_date desc
  limit 1
  for update;

  if not found then
    raise exception 'No hay una estadía activa en esta habitación';
  end if;

  if p_new_check_out = v_res.check_out_date then
    raise exception 'La fecha de salida es la misma que la actual';
  end if;

  if p_new_check_out <= v_res.check_in_date then
    raise exception 'La salida debe ser posterior a la entrada (%)', v_res.check_in_date;
  end if;

  -- ---------------- EXTENDER ----------------
  if p_new_check_out > v_res.check_out_date then
    if p_rate_bs is null or p_rate_bs < 0 then
      raise exception 'La tarifa de las noches nuevas es obligatoria';
    end if;

    if not public.room_is_free_between(
         p_room_id, v_res.check_out_date, p_new_check_out, v_res.id
       ) then
      raise exception 'La habitación ya está reservada por otro huésped en esas fechas';
    end if;

    select * into v_last
    from public.stay_segments
    where reservation_id = v_res.id
    order by end_date desc
    limit 1;

    -- Misma habitación y misma tarifa: se estira el tramo en vez de partir
    -- el folio en dos líneas idénticas.
    if v_last.id is not null
       and v_last.room_id = p_room_id
       and v_last.rate_bs = p_rate_bs then
      update public.stay_segments
        set end_date = p_new_check_out
        where id = v_last.id;
    else
      insert into public.stay_segments (
        reservation_id, room_id, room_type_id, rate_bs, start_date, end_date, reason
      ) values (
        v_res.id, p_room_id, coalesce(v_last.room_type_id, v_res.room_type_id), p_rate_bs,
        v_res.check_out_date, p_new_check_out,
        coalesce(nullif(trim(p_reason), ''), 'Extensión de estadía')
      );
    end if;

  -- ---------------- ACORTAR ----------------
  else
    if p_new_check_out < current_date then
      raise exception
        'No se pueden quitar noches ya dormidas: la nueva salida (%) es anterior a hoy',
        p_new_check_out;
    end if;

    -- Tramos que quedan enteros fuera de la estadía: desaparecen.
    delete from public.stay_segments
    where reservation_id = v_res.id and start_date >= p_new_check_out;

    -- El tramo que cruza la nueva salida se recorta.
    update public.stay_segments
      set end_date = p_new_check_out,
          reason = coalesce(reason, '') ||
                   case when coalesce(reason,'') = '' then '' else ' · ' end ||
                   coalesce(nullif(trim(p_reason), ''), 'Salida adelantada')
      where reservation_id = v_res.id and end_date > p_new_check_out;
  end if;

  return public.recalc_reservation_total(v_res.id);
end;
$$;

grant execute on function public.modify_stay_dates(uuid, date, numeric, text) to authenticated;
