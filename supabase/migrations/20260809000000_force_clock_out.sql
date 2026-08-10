-- =====================================================================
-- Cierre de fichaje forzado por root.
-- (change: force-clock-out)
--
-- EL PROBLEMA
-- `clock_out()` sólo cierra el turno de QUIEN LO LLAMA
-- (`where user_id = auth.uid()`). Si un recepcionista se va sin fichar la
-- salida, nadie puede cerrarlo: el turno queda abierto acumulando horas y
-- no hay ninguna vía en la aplicación para intervenir. En producción hay
-- fichajes de 24, 61 y hasta 104 horas.
--
-- POR QUÉ NO ALCANZA CON "CERRAR AHORA"
-- Si el turno terminó ayer a las 19:00 y root lo detecta hoy a las 11:00,
-- cerrar con `now()` registra 16 horas igual de falsas. Root elige la hora
-- REAL de salida; la RPC sólo valida que sea posterior a la entrada y no
-- futura.
--
-- ESTO ES DATO DE NÓMINA: cambiar las horas trabajadas de otra persona
-- exige justificación y deja rastro de quién lo hizo. Por eso cada ajuste
-- escribe una fila en `time_entry_adjustments` y el original nunca se
-- pierde (se guarda el clock_out previo, null si estaba abierto).
-- =====================================================================

create table if not exists public.time_entry_adjustments (
  id                 uuid primary key default gen_random_uuid(),
  time_entry_id      uuid not null references public.time_entries(id) on delete cascade,
  previous_clock_out timestamptz,          -- null = el turno estaba abierto
  new_clock_out      timestamptz not null,
  reason             text not null check (char_length(trim(reason)) > 0),
  adjusted_by        uuid not null references public.profiles(id) default auth.uid(),
  adjusted_at        timestamptz not null default now()
);

create index if not exists idx_te_adjustments_entry
  on public.time_entry_adjustments (time_entry_id);

alter table public.time_entry_adjustments enable row level security;

drop policy if exists "te_adjustments_read" on public.time_entry_adjustments;
create policy "te_adjustments_read" on public.time_entry_adjustments
  for select using (public.current_user_role() in ('root', 'accountant'));
-- Sin políticas de escritura: sólo la RPC de abajo.

comment on table public.time_entry_adjustments is
  'Auditoría de cierres/correcciones de fichaje hechos por root sobre el '
  'turno de otra persona. Es dato de nómina: queda quién, cuándo y por qué.';

-- ---------------------------------------------------------------------
-- force_clock_out: cierra (o corrige) el fichaje de otra persona.
--
-- Sirve para los dos casos, porque son el mismo problema en distinto
-- momento: el turno que quedó abierto, y el que ya se cerró con una
-- duración imposible porque nadie pudo intervenir a tiempo.
-- ---------------------------------------------------------------------
create or replace function public.force_clock_out(
  p_entry_id  uuid,
  p_clock_out timestamptz,
  p_reason    text
) returns public.time_entries
language plpgsql
security definer
set search_path = public
as $$
declare
  v_entry public.time_entries;
  v_row   public.time_entries;
begin
  if public.current_user_role() <> 'root' then
    raise exception 'Sólo root puede cerrar el fichaje de otra persona';
  end if;

  if p_reason is null or char_length(trim(p_reason)) = 0 then
    raise exception 'La justificación es obligatoria';
  end if;

  select * into v_entry from public.time_entries where id = p_entry_id for update;
  if not found then
    raise exception 'Fichaje no encontrado';
  end if;

  if p_clock_out is null then
    raise exception 'Indicá la hora de salida';
  end if;
  if p_clock_out < v_entry.clock_in then
    raise exception 'La salida (%) no puede ser anterior a la entrada (%)',
      p_clock_out, v_entry.clock_in;
  end if;
  if p_clock_out > now() then
    raise exception 'La salida no puede ser en el futuro';
  end if;

  insert into public.time_entry_adjustments (
    time_entry_id, previous_clock_out, new_clock_out, reason
  ) values (
    p_entry_id, v_entry.clock_out, p_clock_out, trim(p_reason)
  );

  update public.time_entries
    set clock_out = p_clock_out
    where id = p_entry_id
    returning * into v_row;

  return v_row;
end;
$$;

grant execute on function public.force_clock_out(uuid, timestamptz, text) to authenticated;

-- ---------------------------------------------------------------------
-- open_time_entries: turnos abiertos ahora mismo, con cuánto llevan.
-- Es lo que root necesita ver para saber a quién cerrar.
-- ---------------------------------------------------------------------
create or replace function public.open_time_entries()
returns table (
  id         uuid,
  user_id    uuid,
  user_name  text,
  username   text,
  role       text,
  clock_in   timestamptz,
  hours_open numeric
)
language sql
stable
security definer
set search_path = public
as $$
  select
    t.id, t.user_id,
    coalesce(nullif(trim(p.full_name), ''), p.username, '—'),
    p.username, p.role,
    t.clock_in,
    round(extract(epoch from (now() - t.clock_in)) / 3600, 1)
  from public.time_entries t
  join public.profiles p on p.id = t.user_id
  where t.clock_out is null
    and public.current_user_role() in ('root', 'accountant')
  order by t.clock_in;
$$;

grant execute on function public.open_time_entries() to authenticated;
