-- =====================================================================
-- Login por USERNAME + cambio de contraseña forzado en el primer ingreso.
-- Supabase Auth es por email; resolvemos username->email antes del login.
-- =====================================================================

alter table public.profiles
  add column if not exists username text unique;
alter table public.profiles
  add column if not exists must_change_password boolean not null default true;

-- El trigger de alta ahora también toma username y deja must_change_password.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, role, username, must_change_password)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    coalesce(nullif(new.raw_user_meta_data->>'role', ''), 'reception'),
    nullif(new.raw_user_meta_data->>'username', ''),
    true
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

-- =====================================================================
-- FUNCIÓN: traduce username -> email (se llama ANTES del login).
-- SECURITY DEFINER para poder leer auth.users.
-- =====================================================================
create or replace function public.username_to_email(p_username text)
returns text
language sql
security definer
set search_path = public, auth
stable
as $$
  select u.email
  from public.profiles p
  join auth.users u on u.id = p.id
  where p.username = p_username;
$$;

-- =====================================================================
-- FUNCIÓN: baja el flag tras cambiar la contraseña (solo el propio user).
-- Evita que el usuario toque su rol: solo limpia su propio flag.
-- =====================================================================
create or replace function public.clear_password_change_flag()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.profiles
    set must_change_password = false
    where id = auth.uid();
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    -- username_to_email se llama sin sesión: lo puede usar anon.
    grant execute on function public.username_to_email(text) to anon, authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function public.clear_password_change_flag() to authenticated;
  end if;
end$$;
