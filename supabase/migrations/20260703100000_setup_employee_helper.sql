-- =====================================================================
-- Helper de alta de empleados: configura el perfil de un usuario ya
-- creado en Supabase Auth (dashboard). NO toca el esquema auth.
-- Uso (en SQL Editor):
--   select public.setup_employee('recepcion1@staff.monasterio.local',
--                                'recepcion1', 'reception');
-- =====================================================================
create or replace function public.setup_employee(
  p_email    text,
  p_username text,
  p_role     text
) returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_id uuid;
begin
  if p_role not in ('root', 'accountant', 'reception') then
    raise exception 'Rol inválido: % (usar root, accountant o reception)', p_role;
  end if;

  select id into v_id from auth.users where email = p_email;
  if v_id is null then
    raise exception 'No existe un usuario con email % — crealo primero en el dashboard', p_email;
  end if;

  update public.profiles
    set username = p_username,
        role = p_role,
        must_change_password = true
    where id = v_id;
end;
$$;

-- Sin grant a anon/authenticated: solo se ejecuta desde el SQL Editor
-- (rol administrativo). Los usuarios comunes NO pueden llamarla.
