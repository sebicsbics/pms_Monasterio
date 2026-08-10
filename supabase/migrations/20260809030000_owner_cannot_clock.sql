-- =====================================================================
-- owner no ficha: no es empleado.
-- (change: owner-read-only-role, follow-up)
--
-- `clock_in()` y `clock_out()` nunca tuvieron guard de rol — cualquier
-- usuario autenticado podía fichar. Con los roles anteriores eso era
-- inofensivo (todos eran personal del hotel), pero `owner` es el dueño:
-- no cumple turno y su fichaje ensuciaría las horas trabajadas y el
-- historial de asistencia.
--
-- Se enumeran los roles que SÍ fichan en vez de excluir a owner: si mañana
-- se agrega otro rol no operativo, queda afuera por defecto.
-- =====================================================================

create or replace function public.clock_in()
returns public.time_entries
language plpgsql
security definer
set search_path = public
as $$
declare row public.time_entries;
begin
  if public.current_user_role() not in
     ('root', 'accountant', 'reception', 'reception_admin') then
    raise exception 'Tu usuario no ficha asistencia';
  end if;
  if exists (select 1 from public.time_entries
             where user_id = auth.uid() and clock_out is null) then
    raise exception 'Ya tenés un fichaje abierto. Marcá salida primero.';
  end if;
  insert into public.time_entries (user_id) values (auth.uid())
    returning * into row;
  return row;
end $$;

create or replace function public.clock_out()
returns public.time_entries
language plpgsql
security definer
set search_path = public
as $$
declare row public.time_entries;
begin
  if public.current_user_role() not in
     ('root', 'accountant', 'reception', 'reception_admin') then
    raise exception 'Tu usuario no ficha asistencia';
  end if;
  update public.time_entries set clock_out = now()
    where user_id = auth.uid() and clock_out is null
    returning * into row;
  if not found then
    raise exception 'No tenés un fichaje abierto.';
  end if;
  return row;
end $$;

grant execute on function public.clock_in()  to authenticated;
grant execute on function public.clock_out() to authenticated;
