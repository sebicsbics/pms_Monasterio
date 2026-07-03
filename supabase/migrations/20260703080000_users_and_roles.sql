-- =====================================================================
-- FASE 6 — Usuarios y roles (sobre Supabase Auth).
-- auth.users lo gestiona Supabase; aquí agregamos el perfil con rol.
-- =====================================================================

create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  full_name  text,
  role       text not null default 'reception'
             check (role in ('root', 'accountant', 'reception')),
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- Cada usuario puede leer su propio perfil (para conocer su rol en la app).
drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own" on public.profiles
  for select using (id = auth.uid());

-- =====================================================================
-- TRIGGER: al crear un usuario en auth.users, crear su perfil.
-- El rol puede venir en la metadata; por defecto 'reception'.
-- =====================================================================
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    coalesce(nullif(new.raw_user_meta_data->>'role', ''), 'reception')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Backfill: perfiles para usuarios que ya existieran sin perfil.
insert into public.profiles (id, role)
select u.id, 'reception'
from auth.users u
left join public.profiles p on p.id = u.id
where p.id is null;

-- Permiso de lectura (RLS restringe a su propio perfil).
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant select on public.profiles to authenticated;
  end if;
end$$;
