-- =====================================================================
-- Búsqueda de huésped por documento (change: guest-document-lookup).
--
-- Recepción ya tenía la deduplicación por documento DENTRO de las RPC de
-- check-in (walk_in_check_in, add_reservation_companions): si el documento
-- ya existía, se reutilizaba la persona. Pero eso pasaba recién al
-- confirmar — el recepcionista igual tenía que tipear todos los datos de
-- un huésped que YA está en la base.
--
-- Esta RPC expone esa misma llave (guests.passport_number, único parcial
-- desde 20260703010000) como una búsqueda previa, para autocompletar el
-- formulario antes de confirmar.
--
-- Devuelve SOLO los datos estables de la ficha. Los campos
-- CIRCUNSTANCIALES del viaje (origin_city, travel_purpose,
-- transport_means) quedan afuera a propósito: cambian en cada estadía y
-- precargarlos con los de la visita anterior sería registrar datos
-- turísticos falsos.
-- =====================================================================

create or replace function public.lookup_guest_by_document(p_document text)
returns table (
  person_id    uuid,
  first_name   text,
  last_name    text,
  email        text,
  birth_date   date,
  country_code text,
  city         text,
  occupation   text,
  wants_offers boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_doc text := nullif(trim(p_document), '');
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado para buscar huéspedes';
  end if;

  if v_doc is null then
    return;
  end if;

  return query
  select
    p.id,
    p.first_name::text,
    p.last_name::text,
    -- El email sintético del walk-in sin correo no es un dato real: no se
    -- devuelve para no arrastrarlo a la ficha nueva.
    nullif(p.email, '')::text,
    p.birth_date,
    g.country_code::text,
    g.city::text,
    g.occupation,
    coalesce(g.wants_offers, false)
  from public.guests g
  join public.people p on p.id = g.person_id
  where g.passport_number = v_doc
  limit 1;
end;
$$;

grant execute on function public.lookup_guest_by_document(text) to authenticated;

comment on function public.lookup_guest_by_document(text) is
  'Busca un huésped ya registrado por documento/pasaporte para autocompletar '
  'el formulario. NO devuelve los campos circunstanciales del viaje '
  '(procedencia, motivo, transporte): esos se piden en cada estadía.';
