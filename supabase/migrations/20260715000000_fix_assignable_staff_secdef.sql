-- =====================================================================
-- Fix advisory "Security Definer View" en public.assignable_staff.
--
-- La vista era SECURITY DEFINER a propósito (recepción ve al personal asignable
-- sin poder leer employees ni los sueldos). El linter marca toda vista definer.
-- Solución recomendada: reemplazarla por una FUNCIÓN security definer con
-- search_path fijo, que expone SOLO las columnas seguras (nombre, cargo).
-- Mismo modelo de seguridad, sin el advisory de vistas.
-- =====================================================================

drop view if exists public.assignable_staff;

create or replace function public.assignable_staff()
returns table (person_id uuid, full_name text, job_title text)
language sql
security definer
set search_path = public
stable
as $$
  select e.person_id,
         (p.first_name || ' ' || p.last_name) as full_name,
         e.job_title
  from public.employees e
  join public.people p on p.id = e.person_id
  where e.status = 'active'
  order by full_name;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function public.assignable_staff() to authenticated;
  end if;
end$$;
