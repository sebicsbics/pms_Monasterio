-- =====================================================================
-- PERFIL DEL USUARIO — datos personales propios + foto.
--
-- Un usuario debe poder ver su propia info aunque sea recepción (la RLS de
-- employees es solo root/accountant). Se resuelve con funciones SECURITY DEFINER
-- que devuelven EXCLUSIVAMENTE los datos del que llama (where ... = auth.uid()).
-- La foto va a Supabase Storage (bucket 'avatars').
-- =====================================================================

alter table public.profiles
  add column if not exists avatar_url text;

-- ---------- Perfil propio combinado (profiles + employee + people) ----------
create or replace function public.my_profile()
returns table (
  full_name  text,
  username   text,
  role       text,
  avatar_url text,
  first_name text,
  last_name  text,
  email      text,
  birth_date date,
  job_title  text,
  hire_date  date,
  status     text
)
language sql
security definer
set search_path = public
stable
as $$
  select
    p.full_name, p.username, p.role, p.avatar_url,
    pe.first_name, pe.last_name, pe.email, pe.birth_date,
    e.job_title, e.hire_date, e.status
  from public.profiles p
  left join public.employees e on e.user_id = p.id
  left join public.people pe   on pe.id = e.person_id
  where p.id = auth.uid();
$$;

-- ---------- Fijar la URL de la propia foto ----------
create or replace function public.set_my_avatar(p_url text)
returns void
language sql
security definer
set search_path = public
as $$
  update public.profiles set avatar_url = p_url where id = auth.uid();
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function public.my_profile()          to authenticated;
    grant execute on function public.set_my_avatar(text)   to authenticated;
  end if;
end $$;

-- ---------- Storage: bucket de avatares ----------
insert into storage.buckets (id, name, public)
  values ('avatars', 'avatars', true)
  on conflict (id) do nothing;

-- Lectura pública (bucket público). Escritura/actualización/borrado: cada quien
-- solo en su carpeta {auth.uid()}/... .
drop policy if exists "avatars_read"        on storage.objects;
drop policy if exists "avatars_insert_own"  on storage.objects;
drop policy if exists "avatars_update_own"  on storage.objects;
drop policy if exists "avatars_delete_own"  on storage.objects;

create policy "avatars_read" on storage.objects
  for select using (bucket_id = 'avatars');
create policy "avatars_insert_own" on storage.objects
  for insert with check (
    bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text
  );
create policy "avatars_update_own" on storage.objects
  for update using (
    bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text
  );
create policy "avatars_delete_own" on storage.objects
  for delete using (
    bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text
  );
