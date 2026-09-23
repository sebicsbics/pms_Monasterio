-- =====================================================================
-- HOUSEKEEPING SE HACE CARGO DE LIBERAR LA HABITACIÓN (change:
-- housekeeping-owns-room-release, branch
-- feat/housekeeping-owns-room-release).
--
-- Hoy completar una limpieza (`status -> 'done'`) es un UPDATE plano sin
-- ningún efecto sobre `rooms.operational_status`; lo único que libera la
-- habitación es el botón "Marcar como limpia" del tablero de
-- habitaciones. Este paso mueve esa responsabilidad al propio módulo de
-- housekeeping: completar la asignación es lo que libera la habitación.
--
-- TRIGGER, no RPC: la tabla ya tiene una sola vía de escritura para
-- cambiar `status` (UPDATE directo desde `updateAssignmentStatus`, sin
-- una función intermediaria) y el objetivo es que ESE INSTANTE dispare
-- el efecto sin depender de que cada punto de llamada recuerde invocar
-- una función aparte. Un trigger AFTER UPDATE lo garantiza sin importar
-- desde dónde llegue el UPDATE.
--
-- SECURITY INVOKER (el default, no DEFINER): no hay un rol dedicado de
-- housekeeping -- quien opera este tablero es reception/reception_admin/
-- root, que YA tiene permiso de escritura sobre `rooms` vía la policy
-- `rooms_write`. Forzar SECURITY DEFINER acá sería escalar privilegios
-- sin necesidad: si algún día alguien sin `rooms_write` pudiera cerrar
-- una asignación, un DEFINER le regalaría la escritura sobre `rooms` que
-- la RLS le niega explícitamente. Con INVOKER, el trigger respeta la RLS
-- de quien ejecuta el UPDATE.
--
-- LA TRAMPA DE CORRECTITUD: una asignación 'stayover' es la limpieza
-- diaria de una habitación CON el huésped adentro -- su
-- operational_status es 'occupied', no 'dirty'. El UPDATE del trigger
-- sólo libera si la habitación está HOY 'dirty'; si no, no toca nada.
-- =====================================================================

alter table public.housekeeping_assignments
  drop constraint housekeeping_assignments_kind_check;

-- Tercer kind: habitación que sigue sucia de un día anterior y no tiene
-- ninguna reserva activa que la explique hoy (ni stayover ni turnover).
-- Se nombra distinto a propósito -- llamarla "turnover" mentiría sobre
-- por qué está en el tablero (no hubo checkout hoy) y confundiría
-- cualquier reporte que agrupe por kind.
alter table public.housekeeping_assignments
  add constraint housekeeping_assignments_kind_check
  check (kind in ('stayover', 'turnover', 'carryover'));

comment on column public.housekeeping_assignments.kind is
  'stayover = huésped sigue en la habitación (solo limpieza). '
  'turnover = hubo checkout ese día (habilitar para el próximo). '
  'carryover = quedó sucia de un día anterior sin reserva que la '
  'explique hoy (nadie la liberó a tiempo).';

create or replace function public.sync_room_status_from_housekeeping_assignment()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'done' and old.status is distinct from 'done' then
    -- Solo libera si sigue sucia; una stayover completada sobre una
    -- habitación ocupada no debe tocarla (ver nota de correctitud arriba).
    update public.rooms
      set operational_status = 'available'
      where id = new.room_id
        and operational_status = 'dirty';
  elsif old.status = 'done' and new.status is distinct from 'done' then
    -- Reversión (done -> pending/in_progress): solo re-ensucia si la
    -- habitación sigue tal como la dejó esta asignación ('available').
    -- Si mientras tanto se vendió (occupied) o entró a mantenimiento,
    -- ese estado lo puso otra acción explícita y no se pisa -- mismo
    -- criterio defensivo que la liberación: solo tocar el estado que se
    -- espera encontrar.
    update public.rooms
      set operational_status = 'dirty'
      where id = new.room_id
        and operational_status = 'available';
  end if;
  return new;
end;
$$;

create trigger housekeeping_assignment_syncs_room_status
  after update on public.housekeeping_assignments
  for each row
  execute function public.sync_room_status_from_housekeeping_assignment();

-- Función de trigger: se dispara sola, no necesita ser invocable a mano
-- (mismo criterio que 20260911115000_revoke_internal_function_grants.sql
-- aplicó a las otras 5 funciones RETURNS trigger de la base).
revoke execute on function public.sync_room_status_from_housekeeping_assignment() from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke execute on function public.sync_room_status_from_housekeeping_assignment() from anon;
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    revoke execute on function public.sync_room_status_from_housekeeping_assignment() from authenticated;
  end if;
end $$;

-- =====================================================================
-- generate_housekeeping_assignments: agrega la tercera fuente de filas
-- (carryover). Reescrita con CTE para poder excluir de "dirty" las
-- habitaciones que YA entraron por stayover/turnover -- insertar el
-- mismo room_id+service_date dos veces en el mismo INSERT (con kind
-- distinto) violaría la unique constraint, porque ON CONFLICT solo
-- resuelve contra filas YA existentes en la tabla, no contra duplicados
-- dentro del mismo comando.
-- =====================================================================
create or replace function public.generate_housekeeping_assignments(
  p_service_date date
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado para generar el tablero de housekeeping';
  end if;

  with candidates as (
    select r.room_id, 'stayover'::varchar(10) as kind
    from public.reservations r
    where r.room_id is not null
      and r.status = 'checked_in'
      and r.check_in_date <= p_service_date
      and r.check_out_date > p_service_date

    union

    select r.room_id, 'turnover'::varchar(10) as kind
    from public.reservations r
    where r.room_id is not null
      and r.check_out_date = p_service_date
      and r.status in ('checked_in', 'checked_out')
  )
  insert into public.housekeeping_assignments (room_id, service_date, kind, status)
  select room_id, p_service_date, kind, 'pending' from candidates

  union all

  select rm.id, p_service_date, 'carryover', 'pending'
  from public.rooms rm
  where rm.operational_status = 'dirty'
    and rm.id not in (select room_id from candidates)

  on conflict (room_id, service_date) do nothing;
end;
$$;
