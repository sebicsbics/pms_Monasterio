-- =====================================================================
-- Rol `owner`: ve todo, no escribe nada.
-- (change: owner-read-only-role)
--
-- El dueño del hotel quiere mirar todos los datos del PMS sin poder
-- modificarlos por error. Cualquier cambio lo pide a root, que lo ejecuta.
--
-- CÓMO SE GARANTIZA QUE NO ESCRIBE
--   1) Toda escritura del sistema pasa por RPC SECURITY DEFINER con un
--      guard `current_user_role() not in (...)`. Como `owner` no se agrega
--      a NINGUNA de esas listas, queda rechazado por defecto: es
--      fail-closed, no hace falta enumerar lo que no puede hacer.
--   2) Las tablas que sí se escriben directo desde el frontend tenían
--      políticas `dev_all` con `using (true)` — cualquier autenticado
--      podía escribirlas. Se cierran acá (ver más abajo).
--
-- LECTURA: se agrega `owner` a las políticas de SELECT existentes con SQL
-- dinámico en vez de a mano. Son 23 políticas de SELECT más 13 de ALL
-- repartidas por todo el esquema; editarlas una por una es la vía segura
-- de olvidarse justo la que importa.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) El rol existe.
-- ---------------------------------------------------------------------
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('root', 'accountant', 'reception', 'reception_admin', 'owner'));

-- create_staff_member acepta el rol nuevo. Cuerpo IDÉNTICO al vigente
-- (obtenido con pg_get_functiondef) salvo la lista de roles válidos: los
-- DEFAULT de los últimos 3 parámetros son parte de la firma y omitirlos
-- hace fallar el CREATE OR REPLACE.
create or replace function public.create_staff_member(
  p_first_name text, p_last_name text, p_email text, p_job_title text,
  p_hire_date date, p_salary numeric,
  p_user_id uuid default null::uuid,
  p_role text default null::text,
  p_username text default null::text
) returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_person uuid;
begin
  if public.current_user_role() not in ('root', 'accountant') then
    raise exception 'No autorizado';
  end if;
  if p_role is not null
     and p_role not in ('root', 'accountant', 'reception', 'reception_admin', 'owner') then
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
end $function$;

-- ---------------------------------------------------------------------
-- 2) LECTURA. Dos casos, tratados distinto a propósito:
--
--    a) Políticas de SELECT que ya nombran a 'root': se les agrega
--       `OR owner`. Siguen siendo de lectura, así que ampliarlas es seguro.
--
--    b) Políticas FOR ALL que nombran a 'root': NO se tocan. Ampliarlas
--       le daría a owner también la escritura, que es justo lo contrario
--       de lo que se busca. Para esas tablas se crea una política NUEVA,
--       exclusiva de SELECT.
-- ---------------------------------------------------------------------
do $$
declare r record; v_qual text;
begin
  -- (a) SELECT existentes
  for r in
    select c.relname as tbl, p.polname as pol, pg_get_expr(p.polqual, p.polrelid) as qual
    from pg_policy p join pg_class c on c.oid = p.polrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and p.polcmd = 'r'
      and pg_get_expr(p.polqual, p.polrelid) like '%root%'
      and pg_get_expr(p.polqual, p.polrelid) not like '%owner%'
  loop
    execute format(
      'alter policy %I on public.%I using ((%s) or public.current_user_role() = ''owner'')',
      r.pol, r.tbl, r.qual
    );
    raise notice 'lectura owner + en SELECT %.%', r.tbl, r.pol;
  end loop;

  -- (b) FOR ALL con rol: política de sólo lectura aparte
  for r in
    select distinct c.relname as tbl
    from pg_policy p join pg_class c on c.oid = p.polrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and p.polcmd = '*'
      and pg_get_expr(p.polqual, p.polrelid) like '%root%'
  loop
    execute format('drop policy if exists %I on public.%I', r.tbl || '_owner_read', r.tbl);
    execute format(
      'create policy %I on public.%I for select using (public.current_user_role() = ''owner'')',
      r.tbl || '_owner_read', r.tbl
    );
    raise notice 'lectura owner + política nueva en %', r.tbl;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 3) ESCRITURA. Se cierran las 16 tablas con `dev_all ... using (true)`.
--
-- Eran políticas FOR ALL permisivas heredadas de la fase de desarrollo:
-- cualquier usuario autenticado podía INSERT/UPDATE/DELETE directo por
-- PostgREST, sin pasar por ninguna RPC ni dejar auditoría. Es el riesgo
-- que 20260716030000_rate_overrides.sql documentó como "NO RESUELTO":
-- incluye `room_types` (precios de lista) y `rooms`.
--
-- La LECTURA se deja abierta (`using (true)`) igual que antes: el riesgo
-- acá siempre fue la escritura, y varias de estas tablas son catálogos que
-- se leen desde flujos que no conviene romper por un cambio de permisos.
--
-- Sólo 3 escrituras directas existen en el frontend, verificadas antes de
-- este cambio: rooms.update (setRoomStatus, tablero) y products /
-- product_categories .insert (Inventario). El resto de las tablas no se
-- escribe desde ninguna pantalla → sólo root.
-- ---------------------------------------------------------------------
do $$
declare
  r record;
  v_roles text;
begin
  for r in
    select c.relname as tbl, p.polname as pol
    from pg_policy p join pg_class c on c.oid = p.polrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and p.polcmd = '*'
      and pg_get_expr(p.polqual, p.polrelid) = 'true'
  loop
    v_roles := case r.tbl
      -- El tablero cambia el estado operativo con un update directo.
      when 'rooms' then '''root'', ''reception'', ''reception_admin'''
      -- Inventario está abierto a SHARED y da de alta productos/categorías.
      when 'products'           then '''root'', ''accountant'', ''reception'', ''reception_admin'''
      when 'product_categories' then '''root'', ''accountant'', ''reception'', ''reception_admin'''
      -- Catálogos y tablas sin escritura desde la aplicación.
      else '''root'''
    end;

    execute format('drop policy if exists %I on public.%I', r.pol, r.tbl);
    execute format(
      'create policy %I on public.%I for select using (true)',
      r.tbl || '_read', r.tbl
    );
    execute format(
      'create policy %I on public.%I for all
         using (public.current_user_role() in (%s))
         with check (public.current_user_role() in (%s))',
      r.tbl || '_write', r.tbl, v_roles, v_roles
    );
    raise notice 'escritura de % restringida a %', r.tbl, v_roles;
  end loop;
end $$;

comment on constraint profiles_role_check on public.profiles is
  'owner: ve todo el PMS y no escribe nada. No figura en el guard de '
  'ninguna RPC (fail-closed) y las tablas con escritura directa quedaron '
  'restringidas por rol en 20260809010000.';
