-- =====================================================================
-- Fix alta de staff (email duplicado) + borrado de empleados (root).
-- =====================================================================

-- ---------- 1) create_staff_member reutiliza la persona existente ----------
-- people.email es único y compartido con huéspedes. Si la persona ya existe,
-- se reusa su fila (una persona = una fila) en vez de duplicar.
create or replace function public.create_staff_member(
  p_first_name text,
  p_last_name  text,
  p_email      text,
  p_job_title  text,
  p_hire_date  date,
  p_salary     numeric,
  p_user_id    uuid default null,
  p_role       text default null,
  p_username   text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_person uuid;
begin
  if public.current_user_role() not in ('root', 'accountant') then
    raise exception 'No autorizado';
  end if;
  if p_role is not null and p_role not in ('root', 'accountant', 'reception') then
    raise exception 'Rol inválido: %', p_role;
  end if;

  -- ¿Ya existe una persona con ese email? Reusarla; si no, crearla.
  select id into v_person from public.people where email = p_email;
  if v_person is null then
    insert into public.people (first_name, last_name, email)
      values (p_first_name, p_last_name, p_email)
      returning id into v_person;
  else
    update public.people
      set first_name = p_first_name, last_name = p_last_name
      where id = v_person;
  end if;

  if exists (select 1 from public.employees where person_id = v_person) then
    raise exception 'Esa persona ya está registrada como empleado';
  end if;

  insert into public.employees (person_id, job_title, hire_date, salary, user_id)
    values (v_person, p_job_title, coalesce(p_hire_date, current_date),
            p_salary, p_user_id);

  if p_user_id is not null then
    update public.profiles
      set role     = coalesce(p_role, role),
          username = coalesce(nullif(p_username, ''), username)
      where id = p_user_id;
  end if;

  return v_person;
end $$;

-- ---------- 2) Borrar un empleado (solo root) ----------
-- Elimina SOLO la faceta de empleado; la persona (people) queda, porque puede
-- ser huésped. Antes desvincula las asignaciones (tasks/tickets) para no violar
-- los FK, preservando esos registros históricos (assigned_to -> null).
create or replace function public.delete_employee(p_person_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.current_user_role() <> 'root' then
    raise exception 'Solo root puede eliminar empleados';
  end if;

  update public.tasks              set assigned_to = null where assigned_to = p_person_id;
  update public.maintenance_tickets set assigned_to = null where assigned_to = p_person_id;

  delete from public.employees where person_id = p_person_id;
end $$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function public.create_staff_member(
      text, text, text, text, date, numeric, uuid, text, text) to authenticated;
    grant execute on function public.delete_employee(uuid) to authenticated;
  end if;
end $$;
