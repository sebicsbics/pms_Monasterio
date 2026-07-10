-- =====================================================================
-- Flujo unificado de alta de staff (versión SEGURA / semi-unificada).
--
-- En UNA transacción: crea people + employees y, opcionalmente, vincula a un
-- usuario del sistema ya existente y configura su rol/username.
--
-- NO crea la cuenta auth.users: eso requiere service_role (no puede salir del
-- servidor). La creación de la credencial sigue siendo un paso de admin
-- (dashboard de Supabase o, a futuro, una Edge Function). Este RPC elimina los
-- otros pasos manuales (crear empleado, setup_employee, vincular).
-- =====================================================================

create or replace function public.create_staff_member(
  p_first_name text,
  p_last_name  text,
  p_email      text,
  p_job_title  text,
  p_hire_date  date,
  p_salary     numeric,
  p_user_id    uuid default null,   -- perfil existente a vincular (opcional)
  p_role       text default null,   -- rol a fijar en ese perfil (opcional)
  p_username   text default null    -- username a fijar (opcional)
) returns uuid                       -- devuelve el person_id creado
language plpgsql
security definer
set search_path = public
as $$
declare
  v_person uuid;
begin
  -- Autorización: solo gerencia crea staff.
  if public.current_user_role() not in ('root', 'accountant') then
    raise exception 'No autorizado';
  end if;

  if p_role is not null and p_role not in ('root', 'accountant', 'reception') then
    raise exception 'Rol inválido: %', p_role;
  end if;

  -- Persona + empleado.
  insert into public.people (first_name, last_name, email)
    values (p_first_name, p_last_name, p_email)
    returning id into v_person;

  insert into public.employees (person_id, job_title, hire_date, salary, user_id)
    values (v_person, p_job_title, coalesce(p_hire_date, current_date),
            p_salary, p_user_id);

  -- Si se vincula un usuario, opcionalmente configurar su perfil.
  if p_user_id is not null then
    update public.profiles
      set role     = coalesce(p_role, role),
          username = coalesce(nullif(p_username, ''), username)
      where id = p_user_id;
  end if;

  return v_person;
end $$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function public.create_staff_member(
      text, text, text, text, date, numeric, uuid, text, text
    ) to authenticated;
  end if;
end $$;
