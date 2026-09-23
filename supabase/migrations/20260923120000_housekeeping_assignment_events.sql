-- =====================================================================
-- Bitácora de eventos de housekeeping (change:
-- housekeeping-assignment-notes, branch feat/housekeeping-assignment-notes).
--
-- POR QUÉ
-- `housekeeping_assignments.notes` existe desde el primer módulo
-- (20260722000000) pero nada lo escribe -- la mucama no tiene forma de
-- dejar constancia de anomalías ("ventana rota", "faltó reponer
-- amenities") al cambiar el estado de una limpieza. Housekeeping no tiene
-- cuentas propias: recepción escribe por ellas.
--
-- LOG, NO CAMPO EDITABLE
-- La decisión (usuario) es un log append-only, no reescribir `notes` en
-- cada cambio: un campo editable pierde historia (la segunda nota borra
-- la primera) y no dice CUÁNDO ni QUIÉN. Se agrega
-- `housekeeping_assignment_events` -- una fila por cambio de estado (o
-- por nota suelta, sin cambiar estado) -- y se deja `notes` intacta (no
-- se toca ni se migra: dato de producción, columna legacy sin lectores
-- nuevos).
--
-- RPC, NO UPDATE DIRECTO
-- Mover el cambio de estado a `change_housekeeping_assignment_status`
-- (SECURITY DEFINER) en vez de mantener el UPDATE plano que hacía
-- `updateAssignmentStatus` en TS: es el único punto que puede escribir en
-- la bitácora (append-only de verdad -- sin una vía SQL para insertar un
-- evento por fuera de la RPC, cualquiera con acceso a la tabla podría
-- insertar un evento con una fecha o autor falsos). La tabla de
-- asignaciones SIGUE aceptando UPDATE directo vía
-- `housekeeping_assignments_operations` (no se le quita ese permiso: lo
-- necesitan `generateAssignments`/`assignStaffName` y no romper eso es
-- fuera de alcance de este cambio) -- ver nota de seguimiento al final.
--
-- El trigger `housekeeping_assignment_syncs_room_status`
-- (20260922160000) sigue disparando igual: la RPC hace un UPDATE real
-- sobre `housekeeping_assignments`, no lo esquiva.
-- =====================================================================

create table public.housekeeping_assignment_events (
  id            uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references public.housekeeping_assignments(id) on delete cascade,
  from_status   varchar(15) not null check (from_status in ('pending', 'in_progress', 'done')),
  to_status     varchar(15) not null check (to_status in ('pending', 'in_progress', 'done')),
  note          text,
  created_by    uuid references public.profiles(id) default auth.uid(),
  created_at    timestamptz not null default now(),
  -- Un evento sin cambio de estado (from = to) es "sólo nota": tiene que
  -- traer una nota, si no no hay razón para que exista la fila.
  constraint housekeeping_assignment_events_note_required_when_no_change
    check (from_status is distinct from to_status or note is not null)
);

create index idx_housekeeping_assignment_events_assignment
  on public.housekeeping_assignment_events (assignment_id, created_at desc);

comment on table public.housekeeping_assignment_events is
  'Bitácora append-only de cambios de estado y notas de housekeeping. '
  'Sólo se escribe vía change_housekeeping_assignment_status -- no hay '
  'policy de INSERT para authenticated (ver comentario de la función).';

alter table public.housekeeping_assignment_events enable row level security;

-- Sólo SELECT para authenticated (staff de recepción + owner de sólo
-- lectura, mismo conjunto de roles que ya lee housekeeping_assignments
-- vía housekeeping_assignments_operations/housekeeping_assignments_owner_read).
-- Sin policy de INSERT/UPDATE/DELETE a propósito: la única vía de
-- escritura es la RPC SECURITY DEFINER de abajo, que bypasea RLS.
create policy "housekeeping_assignment_events_read" on public.housekeeping_assignment_events
  for select
  using (public.current_user_role() in ('root', 'reception', 'reception_admin', 'owner'));

-- =====================================================================
-- change_housekeeping_assignment_status: mueve a SQL la lógica de
-- timestamps que antes vivía en `updateAssignmentStatus` (TS) y agrega
-- el evento correspondiente en la misma transacción que el UPDATE.
--
-- `for update` sobre la fila: evita una carrera entre dos cambios de
-- estado concurrentes sobre la misma asignación (el segundo espera a
-- que termine el primero y lee el status ya actualizado, no uno viejo).
-- =====================================================================
create or replace function public.change_housekeeping_assignment_status(
  p_assignment_id uuid,
  p_status        text,
  p_note          text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old_status text;
  v_note       text;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado para cambiar el estado de una limpieza';
  end if;

  if p_status not in ('pending', 'in_progress', 'done') then
    raise exception 'Estado inválido';
  end if;

  v_note := nullif(trim(coalesce(p_note, '')), '');

  select status into v_old_status
  from public.housekeeping_assignments
  where id = p_assignment_id
  for update;

  if v_old_status is null then
    raise exception 'La asignación no existe';
  end if;

  if v_old_status = p_status then
    -- Sólo nota, sin cambio de estado: no toca timestamps/status, pero
    -- exige una nota real (si no, no hay nada que registrar).
    if v_note is null then
      raise exception 'La nota no puede estar vacía';
    end if;
  else
    -- Mismos timestamps que `updateAssignmentStatus` en TS:
    --  - in_progress: marca started_at, limpia completed_at.
    --  - done: marca completed_at (started_at queda como esté).
    --  - pending: limpia ambos (vuelve a foja cero).
    if p_status = 'in_progress' then
      update public.housekeeping_assignments
        set status = p_status, started_at = now(), completed_at = null
        where id = p_assignment_id;
    elsif p_status = 'done' then
      update public.housekeeping_assignments
        set status = p_status, completed_at = now()
        where id = p_assignment_id;
    else
      update public.housekeeping_assignments
        set status = p_status, started_at = null, completed_at = null
        where id = p_assignment_id;
    end if;
  end if;

  insert into public.housekeeping_assignment_events (assignment_id, from_status, to_status, note)
  values (p_assignment_id, v_old_status, p_status, v_note);
end;
$$;

revoke execute on function public.change_housekeeping_assignment_status(uuid, text, text) from public, anon;
grant execute on function public.change_housekeeping_assignment_status(uuid, text, text) to authenticated;

comment on function public.change_housekeeping_assignment_status(uuid, text, text) is
  'Única vía de escritura de housekeeping_assignment_events: hace el '
  'UPDATE de status/timestamps (dispara el trigger de liberación de '
  'habitación) y agrega el evento correspondiente en la misma '
  'transacción. Reemplaza el UPDATE directo que hacía updateAssignmentStatus.';

-- =====================================================================
-- list_housekeeping_assignment_events: lectura para el tablero, con el
-- nombre de quien registró cada evento ya resuelto (mismo patrón
-- coalesce(full_name, username, '—') que list_anticipos/list_info_notes).
-- =====================================================================
create or replace function public.list_housekeeping_assignment_events(
  p_assignment_ids uuid[]
) returns table (
  id                uuid,
  assignment_id     uuid,
  from_status       text,
  to_status         text,
  note              text,
  created_by_name   text,
  created_at        timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin', 'owner') then
    raise exception 'No autorizado';
  end if;

  return query
    select
      e.id, e.assignment_id, e.from_status::text, e.to_status::text, e.note,
      coalesce(nullif(trim(pr.full_name), ''), pr.username, '—')::text,
      e.created_at
    from public.housekeeping_assignment_events e
    left join public.profiles pr on pr.id = e.created_by
    where e.assignment_id = any(p_assignment_ids)
    order by e.created_at desc;
end;
$$;

revoke execute on function public.list_housekeeping_assignment_events(uuid[]) from public, anon;
grant execute on function public.list_housekeeping_assignment_events(uuid[]) to authenticated;

-- =====================================================================
-- FOLLOW-UP (fuera de alcance de este cambio, dejar registrado): la
-- policy `housekeeping_assignments_operations` (FOR ALL) todavía permite
-- que root/reception/reception_admin hagan UPDATE directo de `status` en
-- `housekeeping_assignments` por fuera de esta RPC -- eso bypasea la
-- bitácora sin que Postgres lo impida. No se cierra en este change
-- porque esa misma policy es la que necesitan
-- assignStaffName/generateAssignments (assigned_to_name, inserts del
-- tablero) y separarla en policies más finas (UPDATE de status vs.
-- UPDATE de otras columnas) es un cambio de superficie mayor al de
-- "agregar notas". La UI (updateAssignmentStatus en src/) ya sólo llama
-- a la RPC de aquí en más; cerrar la vía SQL directa queda para un
-- change aparte si se vuelve necesario.
-- =====================================================================
