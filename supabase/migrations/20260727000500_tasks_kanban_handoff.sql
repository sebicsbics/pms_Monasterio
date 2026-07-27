-- =====================================================================
-- Tareas como tablero Kanban de handoff entre turnos
-- (change: tasks-kanban-handoff).
--
-- El módulo de tareas ya era un canal de handoff entre turnos
-- (20260716040000). Este cambio lo lleva a un modelo Kanban y ajusta el
-- alta:
--   - La asignación pasa a TEXTO LIBRE (assigned_to_name): se puede
--     escribir el nombre de cualquier persona, no solo empleados del
--     sistema. Se conserva la columna assigned_to (FK, deprecada) por
--     compatibilidad; no se usa más desde la UI.
--   - Se registra QUIÉN abrió el ticket (created_by = auth.uid()) además
--     de la fecha/hora (created_at ya existía).
--   - La habitación (room_id) desaparece de la UI (columna deprecada ya
--     desde 20260716040000; se deja dormida por compatibilidad).
--
-- Aditivo, no destructivo. Cero migración de datos.
-- =====================================================================

alter table public.tasks
  add column if not exists assigned_to_name text;

alter table public.tasks
  add column if not exists created_by uuid references public.profiles(id) default auth.uid();

comment on column public.tasks.assigned_to_name is
  'Texto libre: nombre de la persona a la que se le pasa la tarea. '
  'Reemplaza a assigned_to (FK a employees, deprecada) — ahora se puede '
  'escribir cualquier nombre, no solo empleados del sistema.';

comment on column public.tasks.created_by is
  'Quién abrió el ticket (auth.uid()). Junto con created_at permite ver '
  'quién y cuándo registró la tarea en el handoff entre turnos.';

-- ---------------------------------------------------------------------
-- list_tasks: devuelve las tareas con el nombre del creador resuelto
-- server-side (profiles solo es legible por el propio usuario / gestión,
-- así que un join directo desde el cliente no serviría). SECURITY DEFINER
-- con guard de rol propio, mismo alcance que la policy tasks_operations
-- (root / reception / reception_admin).
-- ---------------------------------------------------------------------
create or replace function public.list_tasks()
returns table (
  id               uuid,
  task_type        text,
  status           text,
  notes            text,
  assigned_to_name text,
  created_at       timestamptz,
  created_by       uuid,
  created_by_name  text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado';
  end if;

  return query
    select
      t.id, t.task_type, t.status, t.notes,
      t.assigned_to_name, t.created_at, t.created_by,
      coalesce(nullif(trim(pr.full_name), ''), pr.username, '—') as created_by_name
    from public.tasks t
    left join public.profiles pr on pr.id = t.created_by
    order by t.created_at desc;
end;
$$;

grant execute on function public.list_tasks() to authenticated;
