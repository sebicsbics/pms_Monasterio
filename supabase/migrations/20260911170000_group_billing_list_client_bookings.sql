-- =====================================================================
-- list_client_bookings_brief(): vista de reservas institucionales
-- abiertas (payer_mode='client', todavía no group_closed) con su saldo
-- pendiente y las habitaciones vencidas (change: group-billing, stage 6,
-- Slice 11, branch feat/booking-24-ui-group-bookings-view).
--
-- Guard de rol: root/reception/reception_admin/accountant -- SIN owner.
-- owner no tiene acceso de lectura a booking_balances/receivables bajo
-- ninguna política de esta etapa (booking_balances_read, receivables_ops,
-- receivables_read_acct); incluirlo acá repetiría el bug de Slice 1
-- (net_owed_bs sin guard, sdd/group-billing/review-booking-8 #352).
--
-- Balance: usa public._net_owed_bs (helper interno, sin guard propio) y
-- NUNCA el wrapper público net_owed_bs -- esta función ya hace su propia
-- autorización arriba, así que llamar al wrapper sería una capa de
-- acoplamiento redundante entre dos guards de rol que evolucionan por
-- separado (convención fijada en sdd/group-billing/design-part-4).
-- =====================================================================
create or replace function public.list_client_bookings_brief()
returns table(
  booking_id uuid,
  account_name text,
  contact_name text,
  net_owed_bs numeric,
  overdue_rooms text[]
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
      b.id,
      ra.name::text,
      (p.first_name || ' ' || p.last_name)::text,
      public._net_owed_bs(b.id),
      array_remove(
        array_agg(
          distinct case
            when r.status = 'confirmed'
              and (r.check_in_date < current_date or r.check_out_date <= current_date)
            then rm.room_number::text
          end
        ),
        null
      )
    from public.bookings b
    join public.receivable_accounts ra on ra.id = b.receivable_account_id
    join public.people p on p.id = b.contact_person_id
    left join public.reservations r on r.booking_id = b.id
    left join public.rooms rm on rm.id = r.room_id
    where b.payer_mode = 'client'
      and not exists (
        select 1 from public.booking_balances bb
        where bb.booking_id = b.id and bb.event_type = 'group_closed'
      )
    group by b.id, ra.name, p.first_name, p.last_name;
end;
$$;

revoke execute on function public.list_client_bookings_brief() from public, anon;
grant execute on function public.list_client_bookings_brief() to authenticated;
