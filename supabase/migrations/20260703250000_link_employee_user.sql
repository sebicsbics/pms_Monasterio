-- =====================================================================
-- Vincular EMPLEADO (RRHH) con su USUARIO del sistema (auth/profiles).
--
-- Hoy son mundos separados: un recepcionista puede tener perfil para loguear
-- sin estar en employees, o al revés. Este link los une.
--
-- Dirección: employees.user_id -> profiles.id (único, nullable).
--   - nullable: un empleado puede no tener login (ej. mucama).
--   - único:    un usuario pertenece a lo sumo a un empleado.
-- Conecta además el fichaje con RRHH (time_entries.user_id = profiles.id).
-- =====================================================================

alter table public.employees
  add column if not exists user_id uuid unique references public.profiles(id);

comment on column public.employees.user_id is
  'Usuario del sistema (profiles.id) con el que este empleado inicia sesión. Null si no tiene acceso.';

-- Para armar la vinculación desde el módulo Empleados, gerencia necesita LISTAR
-- los perfiles. Hoy la RLS de profiles es solo-propio; se agrega lectura para
-- root y contaduría (las políticas se combinan con OR, no reemplaza la existente).
create policy "profiles_select_mgmt" on public.profiles
  for select using (public.current_user_role() in ('root', 'accountant'));
