-- =====================================================================
-- BUG: owner no podía leer por las RPC (sólo por las tablas).
-- (change: owner-read-only-role, follow-up)
--
-- 20260809010000 agregó `owner` a las POLÍTICAS de lectura, pero no a los
-- guards de las RPC de sólo lectura. Varias pantallas no leen la tabla
-- directamente sino una función que resuelve joins server-side, así que
-- para el dueño quedaban vacías o con un error de "No autorizado".
--
-- Reportado en Anticipos y en Pase de información. Al buscar el patrón
-- completo aparecieron SIETE funciones con el mismo problema — otra vez
-- la lección de que hay que buscar la familia, no el caso.
--
-- Consulta que las encontró:
--   select proname from pg_proc p ...
--   where p.prosrc like '%current_user_role%'
--     and p.prosrc not like '%owner%'
--     and has_function_privilege('authenticated', p.oid, 'execute')
--     and p.provolatile in ('s','i');   -- stable/immutable = lectura
--
-- Sumar a `owner` a un guard de LECTURA es seguro: estas funciones no
-- escriben nada. Las de escritura siguen sin nombrarlo (fail-closed).
-- =====================================================================

do $$
declare
  r      record;
  v_src  text;
  v_def  text;
begin
  for r in
    select p.oid, p.proname,
           pg_get_functiondef(p.oid) as def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'cash_session_history', 'list_anticipos', 'list_info_notes',
        'list_receivables', 'list_reservations_brief', 'list_tasks',
        'open_time_entries'
      )
  loop
    v_def := r.def;

    -- Guards con forma `current_user_role() not in (...)` (lanzan excepción):
    -- se agrega 'owner' a la lista de permitidos.
    v_def := regexp_replace(
      v_def,
      '(current_user_role\(\)\s+not\s+in\s+\([^)]*)\)',
      '\1, ''owner'')',
      'g'
    );

    -- Guards con forma `current_user_role() in (...)` dentro de un WHERE.
    v_def := regexp_replace(
      v_def,
      '(current_user_role\(\)\s+in\s+\([^)]*)\)',
      '\1, ''owner'')',
      'g'
    );

    if v_def = r.def then
      raise exception 'No se pudo ubicar el guard en %', r.proname;
    end if;

    execute v_def;
    raise notice 'owner agregado al guard de lectura de %', r.proname;
  end loop;
end $$;
