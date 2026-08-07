-- =====================================================================
-- list_anticipos: todos los anticipos con su contexto.
-- (change: list-anticipos)
--
-- Hasta ahora los anticipos sólo se podían mirar de a una reserva por vez
-- (`fetchAnticipos(reservationId)`), y la vista de corrección pedía pegar
-- a mano el UUID de la reserva. En la práctica eso significa que para
-- corregir un anticipo hay que salir a buscar el UUID a otro lado — no es
-- un flujo que alguien pueda usar en el mostrador.
--
-- Devuelve el anticipo con la habitación, el huésped y las fechas ya
-- resueltos, para que la UI no tenga que encadenar consultas ni el
-- navegador armar el join.
--
-- Nota sobre `status`: el esquema conserva el CHECK original con
-- 'partially_refunded' y 'refunded' de cuando existían los reembolsos
-- (eliminados en 20260727000100). Hoy sólo se escriben 'active' y
-- 'forfeited'; los otros dos no pueden aparecer.
-- =====================================================================

create or replace function public.list_anticipos(
  p_only_active boolean default false,
  p_limit       int default 200
) returns table (
  id                uuid,
  reservation_id    uuid,
  room_number       text,
  guest_name        text,
  check_in_date     date,
  check_out_date    date,
  reservation_status text,
  amount_bs         numeric,
  payment_method    text,
  status            text,
  receipt_path      text,
  payment_reference text,
  received_by_name  text,
  received_at       timestamptz,
  notes             text
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
      a.id, a.reservation_id, rm.room_number::text,
      (p.first_name || ' ' || p.last_name)::text,
      r.check_in_date, r.check_out_date, r.status::text,
      a.amount_bs, a.payment_method, a.status,
      a.receipt_path, a.payment_reference,
      coalesce(nullif(trim(pr.full_name), ''), pr.username, '—')::text,
      a.received_at, a.notes
    from public.anticipos a
    join public.reservations r on r.id = a.reservation_id
    join public.rooms  rm on rm.id = r.room_id
    join public.guests g   on g.person_id = r.guest_id
    join public.people p   on p.id = g.person_id
    left join public.profiles pr on pr.id = a.received_by
    where (not p_only_active or a.status = 'active')
    order by a.received_at desc
    limit greatest(p_limit, 1);
end;
$$;

grant execute on function public.list_anticipos(boolean, int) to authenticated;

comment on function public.list_anticipos(boolean, int) is
  'Anticipos con habitación, huésped y fechas ya resueltos. Alimenta la '
  'lista de "Registrar anticipo" y el selector de "Corregir anticipos", '
  'que antes exigía pegar a mano el UUID de la reserva.';
