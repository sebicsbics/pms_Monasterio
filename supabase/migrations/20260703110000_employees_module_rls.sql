-- =====================================================================
-- MÓDULO EMPLEADOS + BLINDAJE RLS POR ROL (root, accountant).
-- Primera tabla con enforcement REAL de acceso por rol en la base.
-- =====================================================================

-- Rol del usuario logueado (para usar en políticas RLS).
create or replace function public.current_user_role()
returns text
language sql
security definer
stable
set search_path = public
as $$
  select role from public.profiles where id = auth.uid();
$$;

-- =====================================================================
-- RLS de employees: SOLO root y accountant. Reemplaza la política dev_all.
-- =====================================================================
drop policy if exists "dev_all_employees" on public.employees;
create policy "employees_finance_only" on public.employees
  for all
  using (public.current_user_role() in ('root', 'accountant'))
  with check (public.current_user_role() in ('root', 'accountant'));

-- =====================================================================
-- FUNCIÓN: alta de empleado (persona + registro laboral), ATÓMICA.
-- Autorizada solo para root/accountant (chequeo explícito + RLS de respaldo).
-- =====================================================================
create or replace function public.create_employee(
  p_first_name text,
  p_last_name  text,
  p_email      text,
  p_job_title  text,
  p_hire_date  date,
  p_salary     numeric
) returns uuid
language plpgsql
as $$
declare
  v_person_id uuid;
begin
  if public.current_user_role() not in ('root', 'accountant') then
    raise exception 'No autorizado para gestionar empleados';
  end if;
  if nullif(trim(p_first_name), '') is null or nullif(trim(p_last_name), '') is null then
    raise exception 'Nombre y apellido son obligatorios';
  end if;
  if nullif(trim(p_job_title), '') is null then
    raise exception 'El cargo es obligatorio';
  end if;

  insert into public.people (first_name, last_name, email)
  values (p_first_name, p_last_name, nullif(p_email, ''))
  returning id into v_person_id;

  insert into public.employees (person_id, job_title, hire_date, salary, status)
  values (v_person_id, p_job_title, coalesce(p_hire_date, current_date), p_salary, 'active');

  return v_person_id;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant execute on function public.current_user_role() to anon, authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function public.create_employee(text,text,text,text,date,numeric)
      to authenticated;
  end if;
end$$;
