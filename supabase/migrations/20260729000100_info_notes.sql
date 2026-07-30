-- =====================================================================
-- Pase de información (change: info-notes).
--
-- Bitácora de líneas de información que recepción se pasa entre turnos y
-- que persiste en el tiempo (ej. objetos olvidados: "se dejó una chaqueta
-- en la Hab. 12 el 2026-07-29, del huésped Juan Pérez"). Buscable por
-- palabras clave y por fechas. Guarda quién la registró y, al cerrarse
-- (ej. el huésped retira la chaqueta), quién y cuándo la resolvió.
-- =====================================================================

create table if not exists public.info_notes (
  id            uuid primary key default gen_random_uuid(),
  content       text not null check (char_length(trim(content)) > 0),
  created_by    uuid references public.profiles(id) default auth.uid(),
  created_at    timestamptz not null default now(),
  resolved      boolean not null default false,
  resolved_by   uuid references public.profiles(id),
  resolved_at   timestamptz,
  resolved_note text
);

create index if not exists idx_info_notes_created_at on public.info_notes (created_at desc);

alter table public.info_notes enable row level security;

drop policy if exists "info_notes_ops" on public.info_notes;
create policy "info_notes_ops" on public.info_notes
  for all
  using (public.current_user_role() in ('root', 'reception', 'reception_admin'))
  with check (public.current_user_role() in ('root', 'reception', 'reception_admin'));

-- ---------------------------------------------------------------------
-- list_info_notes: búsqueda por texto (ilike) y rango de fechas, con el
-- nombre de quien registró/resolvió resuelto server-side (profiles no es
-- legible entre usuarios desde el cliente). SECURITY DEFINER + guard.
-- ---------------------------------------------------------------------
create or replace function public.list_info_notes(
  p_search           text default null,
  p_from             date default null,
  p_to               date default null,
  p_include_resolved boolean default true
) returns table (
  id               uuid,
  content          text,
  created_at       timestamptz,
  created_by_name  text,
  resolved         boolean,
  resolved_at      timestamptz,
  resolved_by_name text,
  resolved_note    text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado';
  end if;

  return query
    select
      n.id, n.content, n.created_at,
      coalesce(nullif(trim(pc.full_name), ''), pc.username, '—'),
      n.resolved, n.resolved_at,
      coalesce(nullif(trim(pr.full_name), ''), pr.username),
      n.resolved_note
    from public.info_notes n
    left join public.profiles pc on pc.id = n.created_by
    left join public.profiles pr on pr.id = n.resolved_by
    where (p_search is null or n.content ilike '%' || p_search || '%')
      and (p_from is null or n.created_at >= p_from::timestamptz)
      and (p_to is null or n.created_at < (p_to::timestamptz + interval '1 day'))
      and (p_include_resolved or not n.resolved)
    order by n.created_at desc;
end;
$$;

grant execute on function public.list_info_notes(text, date, date, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- resolve_info_note: cierra una nota (ej. el objeto fue retirado).
-- ---------------------------------------------------------------------
create or replace function public.resolve_info_note(
  p_id   uuid,
  p_note text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado';
  end if;

  update public.info_notes
    set resolved = true, resolved_by = auth.uid(), resolved_at = now(),
        resolved_note = nullif(trim(p_note), '')
    where id = p_id and not resolved;

  if not found then
    raise exception 'Nota no encontrada o ya resuelta';
  end if;
end;
$$;

grant execute on function public.resolve_info_note(uuid, text) to authenticated;
