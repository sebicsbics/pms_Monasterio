-- =====================================================================
-- CRÍTICO: el registro público permitía elegirse el rol.
-- (change: fix-signup-role-escalation)
--
-- EL AGUJERO
-- `handle_new_user` (trigger sobre auth.users) tomaba el rol de
-- `new.raw_user_meta_data->>'role'`. Ese campo lo manda EL CLIENTE en el
-- signUp, y el registro público está habilitado en el proyecto. Con la
-- clave anónima —que viaja en el bundle del navegador— cualquiera en
-- internet podía hacer:
--
--     supabase.auth.signUp({ email, password,
--                            options: { data: { role: 'root' } } })
--
-- y quedar con un perfil root. No es un guard mal ubicado como los de
-- 20260810000000: es el trigger confiando en un dato del cliente.
--
-- Auditado antes de tocar nada: las 10 cuentas existentes son personal
-- conocido o pruebas. Nadie lo explotó.
--
-- LA CORRECCIÓN
--   1) El trigger IGNORA por completo el rol que viene del cliente.
--   2) Se agrega el rol `pending`, que no figura en NINGUNA política ni
--      guard: una cuenta recién registrada no puede leer ni escribir
--      nada. Antes el default era `reception`, así que cualquier registro
--      nacía con permisos de escritura sobre la operación del hotel.
--   3) Root le asigna el rol real después (create_staff_member, o el
--      cambio manual que ya se hace al dar de alta a alguien).
--
-- Esto es defensa en profundidad. La corrección de fondo es DESHABILITAR
-- el registro público en Authentication → Providers → Email: este hotel
-- no tiene ningún flujo donde un desconocido deba poder registrarse.
-- =====================================================================

alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('root', 'accountant', 'reception', 'reception_admin', 'owner', 'pending'));

alter table public.profiles alter column role set default 'pending';

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
    -- NUNCA se lee el rol del metadata: lo controla quien se registra.
    'pending',
    nullif(new.raw_user_meta_data->>'username', ''),
    true
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

comment on function public.handle_new_user() is
  'Crea el perfil al registrarse un usuario. SIEMPRE con rol `pending`: '
  'el rol NO se toma de raw_user_meta_data porque lo controla el cliente '
  'del signUp. Root asigna el rol real después.';
