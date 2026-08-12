-- =====================================================================
-- REGRESIÓN: `anon` no pasa ningún guard de rol.
--
-- Hubo un momento en que sí los pasaba TODOS. `current_user_role()`
-- devolvía NULL sin sesión, y en SQL:
--
--     null not in ('root', 'reception')  →  NULL
--     if NULL then raise exception       →  no dispara
--
-- Los 33 guards escritos con `not in` dejaban pasar a anon, y como son
-- funciones SECURITY DEFINER además se salteaban la RLS. Sin ninguna
-- sesión se llegó a cargar un consumo al folio de un huésped.
--
-- Este archivo prueba las dos barreras: que el rol nunca sea NULL, y que
-- anon ni siquiera pueda ejecutar las funciones del negocio.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(10);

-- Datos que el test necesita, tomados ANTES de bajar de privilegios.
create temp table datos on commit drop as
select r.room_id from public.reservations r where r.status = 'checked_in' limit 1;
grant select on datos to anon;

set local role anon;

-- ---------- La raíz ----------
select is(public.current_user_role(), 'anonymous',
  'sin sesión el rol es anonymous, NUNCA null');
select ok(public.current_user_role() not in ('root','reception','reception_admin'),
  'el guard escrito con `not in` evalúa a TRUE y por lo tanto dispara');
select ok(not public.current_user_role() in ('root','reception','reception_admin'),
  'y los guards escritos en positivo también lo excluyen');

-- ---------- La barrera de permisos ----------
select ok(not has_function_privilege('anon','public.add_folio_charge(uuid,text,numeric)','execute'),
  'anon no puede ejecutar add_folio_charge');
select ok(not has_function_privilege('anon','public.check_out_room(uuid,text,text,text,uuid,numeric,numeric,text)','execute'),
  'anon no puede ejecutar check_out_room');
select ok(not has_function_privilege('anon','public.open_cash_session(numeric)','execute'),
  'anon no puede ejecutar open_cash_session');
select ok(not has_function_privilege('anon','public.list_anticipos(boolean,integer)','execute'),
  'anon no puede ejecutar list_anticipos');
-- Se afirma CUÁLES son, no cuántas: si mañana aparece otra, el test dice
-- exactamente cuál y hay que justificarla.
select is(
  (select string_agg(p.proname, ', ' order by p.proname)
     from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.prokind='f'
      and has_function_privilege('anon', p.oid, 'execute')),
  'current_user_role, is_staff, username_to_email',
  'anon sólo alcanza 3 funciones: la del login y los dos predicados de las políticas');

-- ---------- Y el login tiene que seguir funcionando ----------
select ok(has_function_privilege('anon','public.username_to_email(text)','execute'),
  'username_to_email sigue disponible: sin ella nadie podría iniciar sesión');
select isnt(public.username_to_email('root'), null,
  'anon traduce usuario → correo, que es el paso previo a autenticarse');

reset role;
select * from finish();
rollback;
