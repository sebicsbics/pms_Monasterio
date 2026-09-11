-- =====================================================================
-- Una persona no puede ocupar dos estadías activas que se solapen.
-- (change: reservation-booker-vs-guest, PR3, 6/8).
--
-- POR QUÉ
-- Nada impedía hasta ahora que la misma persona quedara registrada como
-- ocupante (titular o acompañante) de dos habitaciones con fechas que se
-- cruzan -- ni un doble check-in por error de carga, ni un extend_stay o
-- change_room que termine pisando otra estadía activa de la misma
-- persona. `reservation_guests` gana `stay_range` (daterange semiabierto
-- '[)') y `active` (confirmed/checked_in), mantenidos por triggers desde
-- `reservations`, y un EXCLUDE USING gist los usa para rechazar el
-- solapamiento a nivel de base -- la barrera de verdad es el índice
-- GiST, no un chequeo de aplicación que se puede pisar por una carrera.
--
-- modify_stay_dates/change_room (20260807000000_cash_history_and_stay_dates.sql,
-- 20260805030000_stay_segments.sql -- modify_stay_dates reemplazó a
-- extend_stay en 20260807000000) no necesitan un trigger propio: ambos
-- terminan actualizando `reservations.check_in_date`/`check_out_date`
-- (/`room_id`) -- directo (change_room) o vía recalc_reservation_total
-- (modify_stay_dates) -- y el trigger de sync ya escucha esas columnas.
--
-- DEUDA DECLARADA (presupuesto de PR): la violación del EXCLUDE
-- (SQLSTATE 23P01) NO se traduce a un mensaje en español dentro de las
-- RPCs de alta/check-in/extend_stay/change_room en esta migración --
-- envolver las ~6 RPCs involucradas (check_in_reservation_with_guests,
-- walk_in_check_in_with_guests, add_reservation_companions,
-- add_guests_to_stay, create_reservation, create_bulk_reservation,
-- modify_stay_dates, change_room)
-- hubiera implicado re-copiar sus cuerpos completos sólo para agregar
-- un bloque EXCEPTION, muy por encima del presupuesto de esta PR (y
-- production ya se verificó sin violaciones hoy, ver apply-progress).
-- Reception ve hoy el mensaje crudo de Postgres si esto ocurre; queda
-- documentado como tarea de una PR siguiente cuando cualquiera de esas
-- funciones se vuelva a tocar.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0) Extensión: btree_gist habilita EXCLUDE con `=` (uuid) y `&&`
--    (daterange) en el mismo índice GiST. Convención del repo: se crea
--    en el schema `extensions` (igual que pgcrypto/pg_net/uuid-ossp), y
--    `search_path` ("$user", public, extensions) ya la resuelve sin
--    calificar el operador class en el EXCLUDE de abajo.
-- ---------------------------------------------------------------------
create extension if not exists btree_gist with schema extensions;

-- ---------------------------------------------------------------------
-- 1) Columnas mantenidas por trigger, nunca por la aplicación.
-- ---------------------------------------------------------------------
alter table public.reservation_guests
  add column stay_range daterange,
  add column active boolean not null default true;

comment on column public.reservation_guests.stay_range is
  'Rango semiabierto [check_in, check_out) de la reserva dueña, sincronizado por trigger. Ver 20260911040000.';
comment on column public.reservation_guests.active is
  'true si la reserva dueña está confirmed/checked_in. Sincronizado por trigger. Ver 20260911040000.';

-- Backfill ANTES del NOT NULL y ANTES del EXCLUDE.
update public.reservation_guests rg
  set stay_range = daterange(r.check_in_date, r.check_out_date, '[)'),
      active = r.status in ('confirmed', 'checked_in')
  from public.reservations r
  where r.id = rg.reservation_id;

alter table public.reservation_guests alter column stay_range set not null;

-- ---------------------------------------------------------------------
-- 2) Triggers de sincronización.
-- ---------------------------------------------------------------------
create or replace function public.init_reservation_guests_stay_range()
returns trigger
language plpgsql
as $$
declare
  v_check_in  date;
  v_check_out date;
  v_status    varchar;
begin
  select check_in_date, check_out_date, status
    into v_check_in, v_check_out, v_status
  from public.reservations
  where id = new.reservation_id;

  new.stay_range := daterange(v_check_in, v_check_out, '[)');
  new.active := v_status in ('confirmed', 'checked_in');
  return new;
end;
$$;

create trigger reservation_guests_init_stay_range
  before insert on public.reservation_guests
  for each row execute function public.init_reservation_guests_stay_range();

create or replace function public.sync_reservation_guests_stay_range()
returns trigger
language plpgsql
as $$
begin
  update public.reservation_guests
    set stay_range = daterange(new.check_in_date, new.check_out_date, '[)'),
        active = new.status in ('confirmed', 'checked_in')
    where reservation_id = new.id;
  return new;
end;
$$;

create trigger reservations_sync_stay_range
  after insert or update of check_in_date, check_out_date, status
  on public.reservations
  for each row execute function public.sync_reservation_guests_stay_range();

-- Ni una ni otra se llaman a mano: sólo las invoca el trigger. Sin
-- grant a authenticated, revocadas de public y anon explícitamente.
revoke execute on function public.init_reservation_guests_stay_range() from public, anon, authenticated;
revoke execute on function public.sync_reservation_guests_stay_range() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3) Pre-flight: mismo criterio que el EXCLUDE, pero ANTES de crearlo,
--    para que un despliegue con datos ya corrompidos falle con una
--    lista accionable (reserva + fechas, sin nombres/documentos) en vez
--    de un error de constraint opaco. Se expone como función para poder
--    reusarla desde pgTAP (supabase/tests/12_stay_overlap_constraint.sql).
-- ---------------------------------------------------------------------
create or replace function public._stay_overlap_violations()
returns table (
  person_id      uuid,
  reservation_a  uuid,
  range_a        daterange,
  reservation_b  uuid,
  range_b        daterange
)
language sql
stable
as $$
  select a.person_id, a.reservation_id, a.stay_range, b.reservation_id, b.stay_range
  from public.reservation_guests a
  join public.reservation_guests b
    on a.person_id = b.person_id
   and a.reservation_id < b.reservation_id
   and a.active and b.active
   and a.stay_range && b.stay_range;
$$;

revoke execute on function public._stay_overlap_violations() from public, anon, authenticated;

do $$
declare
  v_count int;
  v_list  text;
  v_msg   text;
begin
  select count(*) into v_count from public._stay_overlap_violations();
  if v_count > 0 then
    select string_agg(
             format('reserva %s (%s) se solapa con reserva %s (%s)',
                    reservation_a, range_a, reservation_b, range_b),
             E'\n'
           )
      into v_list
      from public._stay_overlap_violations();
    v_msg := format(
      'No se puede aplicar la restricción de una-persona-una-estadía: '
      '%s solapamiento(s) activos ya existen. Resolver antes de desplegar:%s%s',
      v_count, E'\n', v_list
    );
    raise exception '%', v_msg;
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 4) La restricción de verdad: índice GiST, no un chequeo de aplicación.
-- ---------------------------------------------------------------------
alter table public.reservation_guests
  add constraint reservation_guests_no_overlap
  exclude using gist (person_id with =, stay_range with &&) where (active);
