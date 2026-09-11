-- =====================================================================
-- Booking foundation (change: reservation-booker-vs-guest, PR1/6).
--
-- POR QUÉ
-- Hoy `reservations.guest_id` hace dos trabajos a la vez: "a quién le
-- respondo/factura" (el contacto que reservó) y "quién ocupa la
-- habitación" (el titular). Eso produjo el bug de origen de este cambio:
-- una reserva grupal/institucional donde el coordinador que llamó quedó
-- como `guest_id` de VARIAS habitaciones a la vez, aunque él solo se
-- alojó en una (o en ninguna).
--
-- Esta migración separa el "quién reserva" en una tabla nueva,
-- `bookings`, y deja `reservation_guests.role` explícito ('holder' |
-- 'companion') para "quién ocupa". `reservations.guest_id` NO se toca
-- todavía (sigue NOT NULL, sigue siendo el titular): eso es la migración
-- de la PR2a, que además vuelve nullable esa columna. Acá solo se agrega
-- la base y se repara el dato histórico.
--
-- BACKFILL
-- Se agrupan las reservas existentes por (guest_id, check_in_date,
-- check_out_date): cada cluster es 1 sola `bookings`. La mayoría de los
-- clusters tiene 1 reserva. Cuando un mismo contacto reservó varias
-- habitaciones para las mismas fechas (grupo/institución), el cluster
-- agrupa esas reservas en 1 booking compartida -- que es justo el
-- comportamiento correcto para "quién reserva".
--
-- Para "quién ocupa" (reservation_guests.role='holder'), el backfill
-- asume guest_id como titular de CADA reserva, EXCEPTO cuando el cluster
-- tiene 2+ habitaciones checked_in/checked_out simultáneas compartiendo
-- el mismo contacto: ahí no hay forma de saber, sólo con los datos que
-- hay, en qué habitación se alojó realmente el contacto (si en alguna).
-- Esos casos (8 estadías en prod, verificado en la exploración) quedan
-- SIN holder automático, y la migración imprime la lista para que
-- recepción reconcilie a mano contra el registro en papel.
--
-- La lógica de backfill vive en una función (`_run_booking_backfill`)
-- en lugar de un bloque DO suelto, para poder re-ejercitarla en pgTAP
-- contra fixtures que sí reproducen el caso corrupto (el seed local no
-- tiene ninguno). Es idempotente: sólo toca reservas con booking_id NULL
-- y sólo inserta holder cuando no existe uno. No se dropea al final
-- porque el test la vuelve a invocar contra fixtures; queda revocada de
-- public/anon como cualquier función interna.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1) Tabla bookings: el "quién reserva/responde".
-- ---------------------------------------------------------------------
create table public.bookings (
  id                     uuid primary key default gen_random_uuid(),
  contact_person_id      uuid not null references public.people(id),
  receivable_account_id  uuid references public.receivable_accounts(id),
  payer_mode             text not null default 'each_stay'
                            check (payer_mode in ('client', 'each_stay')),
  channel_code           varchar references public.reservation_channels(code),
  agency_name            text,
  notes                  text,
  created_at             timestamptz not null default now(),
  created_by             uuid references public.profiles(id) default auth.uid()
);

comment on table public.bookings is
  'Quién reservó/responde por la estadía (contacto), separado de quién '
  'ocupa la habitación (reservation_guests). Ver 20260911000000.';

alter table public.bookings enable row level security;

create policy "bookings_select" on public.bookings
  for select using (
    public.current_user_role() in ('root', 'reception', 'reception_admin', 'accountant')
    or public.current_user_role() = 'owner'
  );

-- Sin política de escritura directa: se escribe sólo vía RPC
-- SECURITY DEFINER, igual que reservations.

-- ---------------------------------------------------------------------
-- 2) reservations.booking_id (nullable por ahora; NOT NULL luego del
--    backfill, más abajo).
-- ---------------------------------------------------------------------
alter table public.reservations add column booking_id uuid references public.bookings(id);

-- ---------------------------------------------------------------------
-- 3) reservation_guests.role: quién ocupa, explícito.
-- ---------------------------------------------------------------------
alter table public.reservation_guests add column role text not null default 'companion'
  check (role in ('holder', 'companion'));

create unique index reservation_guests_one_holder_per_stay
  on public.reservation_guests (reservation_id) where role = 'holder';

comment on column public.reservation_guests.role is
  'holder = titular de la habitación (a lo sumo 1 por reserva, ver '
  'reservation_guests_one_holder_per_stay). companion = acompañante.';

-- ---------------------------------------------------------------------
-- 4) Función de backfill (reutilizable, ver nota arriba).
-- ---------------------------------------------------------------------
create or replace function public._run_booking_backfill()
returns void
language plpgsql
as $$
declare
  v_repair record;
begin
  -- 4a) Una booking por cluster (guest_id, check_in_date, check_out_date)
  --     entre las reservas que todavía no tienen booking_id.
  create temporary table _cluster_bookings on commit drop as
  select
    gen_random_uuid() as booking_id,
    guest_id,
    check_in_date,
    check_out_date,
    (array_agg(agency_name order by created_at) filter (where agency_name is not null))[1] as agency_name,
    (array_agg(channel_code order by created_at) filter (where channel_code is not null))[1] as channel_code
  from public.reservations
  where booking_id is null
  group by guest_id, check_in_date, check_out_date;

  insert into public.bookings (id, contact_person_id, agency_name, channel_code)
  select booking_id, guest_id, agency_name, channel_code
  from _cluster_bookings;

  update public.reservations r
  set booking_id = cb.booking_id
  from _cluster_bookings cb
  where r.booking_id is null
    and r.guest_id = cb.guest_id
    and r.check_in_date = cb.check_in_date
    and r.check_out_date = cb.check_out_date;

  drop table _cluster_bookings;

  -- 4b) Clusters corruptos: mismo contacto, mismas fechas, 2+
  --     habitaciones checked_in/checked_out a la vez. No se infiere
  --     titular ahí -- se deja la lista para reconciliación manual.
  create temporary table _corrupted_clusters on commit drop as
  select guest_id, check_in_date, check_out_date
  from public.reservations
  group by guest_id, check_in_date, check_out_date
  having count(*) filter (where status in ('checked_in', 'checked_out')) >= 2;

  for v_repair in
    select r.id as reservation_id, r.room_id, r.check_in_date, r.check_out_date, r.guest_id
    from public.reservations r
    join _corrupted_clusters cc
      on cc.guest_id = r.guest_id
     and cc.check_in_date = r.check_in_date
     and cc.check_out_date = r.check_out_date
  loop
    raise notice
      'reconciliar a mano: reserva % (room %, % a %) -- contacto compartido %, no se infirió titular',
      v_repair.reservation_id, v_repair.room_id, v_repair.check_in_date,
      v_repair.check_out_date, v_repair.guest_id;
  end loop;

  -- 4c) Holder = guest_id para toda reserva sin holder que NO esté en un
  --     cluster corrupto.
  insert into public.reservation_guests (reservation_id, person_id, role)
  select r.id, r.guest_id, 'holder'
  from public.reservations r
  where not exists (
    select 1 from public.reservation_guests rg
    where rg.reservation_id = r.id and rg.role = 'holder'
  )
  and not exists (
    select 1 from _corrupted_clusters cc
    where cc.guest_id = r.guest_id
      and cc.check_in_date = r.check_in_date
      and cc.check_out_date = r.check_out_date
  );

  drop table _corrupted_clusters;
end;
$$;

revoke execute on function public._run_booking_backfill() from public, anon;
-- No se otorga a authenticated: es de uso interno (migración + pgTAP),
-- no una operación que la aplicación dispare.

select public._run_booking_backfill();

-- ---------------------------------------------------------------------
-- 5) Ahora sí, toda reserva tiene booking -- se endurece la columna.
-- ---------------------------------------------------------------------
alter table public.reservations alter column booking_id set not null;

-- ---------------------------------------------------------------------
-- 6) Hasta que PR2a reescriba create_reservation/create_bulk_reservation
--    para crear la booking explícitamente, cualquier inserción directa
--    (seed, datos de prueba, altas manuales) necesita booking_id. Este
--    trigger crea una booking 1:1 con el contacto cuando no se indicó
--    una -- así el NOT NULL de arriba no rompe nada que hoy inserta sin
--    pasar por una RPC nueva. Cuando PR2a arme la booking a mano (con
--    agrupamiento real para bulk), simplemente seteará booking_id antes
--    del insert y este trigger no hace nada (sólo actúa si es NULL).
-- ---------------------------------------------------------------------
create or replace function public._create_booking_for_new_reservation()
returns trigger
language plpgsql
as $$
begin
  if new.booking_id is null then
    insert into public.bookings (contact_person_id, agency_name, channel_code)
    values (new.guest_id, new.agency_name, new.channel_code)
    returning id into new.booking_id;
  end if;
  return new;
end;
$$;

revoke execute on function public._create_booking_for_new_reservation() from public, anon;

create trigger reservations_create_booking
  before insert on public.reservations
  for each row execute function public._create_booking_for_new_reservation();

-- Mismo criterio que el backfill (4c): guest_id es el titular mientras no
-- exista todavía una vía explícita para dejarlo sin asignar (eso llega en
-- PR2a, junto con guest_id nullable). Va en un trigger AFTER separado
-- porque reservation_guests.reservation_id tiene FK a reservations: la
-- fila padre recién existe después del insert.
create or replace function public._create_holder_for_new_reservation()
returns trigger
language plpgsql
as $$
begin
  insert into public.reservation_guests (reservation_id, person_id, role)
  select new.id, new.guest_id, 'holder'
  where not exists (
    select 1 from public.reservation_guests rg
    where rg.reservation_id = new.id and rg.role = 'holder'
  );
  return new;
end;
$$;

revoke execute on function public._create_holder_for_new_reservation() from public, anon;

create trigger reservations_create_holder
  after insert on public.reservations
  for each row execute function public._create_holder_for_new_reservation();

-- Nota: no hace falta un GRANT explícito de tabla acá -- 20260811000000
-- dejó `alter default privileges ... grant all on tables to anon,
-- authenticated, service_role`, así que bookings ya lo hereda. La RLS de
-- arriba es la barrera real.
