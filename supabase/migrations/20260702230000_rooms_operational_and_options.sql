-- =====================================================================
-- FASE 3.1 — Adaptar rooms al front-desk + tipos duales (many-to-many)
-- Cambios ADITIVOS: no rompen la web de reservas (base compartida).
-- =====================================================================

-- ---------- Estado OPERATIVO de recepción ----------
-- Distinto de rooms.status (entity_status = ciclo de vida: active/deleted...).
-- Este describe el día a día que pinta el tablero de recepción.
alter table public.rooms
  add column if not exists operational_status varchar(15) not null default 'available'
    check (operational_status in ('available','occupied','dirty','maintenance'));

-- ---------- Zona / patio del hotel colonial ----------
-- El hotel se organiza por patios (Primer/Segundo/Tercer Patio) dentro de cada piso.
alter table public.rooms
  add column if not exists zone varchar(50);

-- ---------- Tabla puente: tipos ofrecibles por habitación ----------
-- Una habitación física puede venderse como VARIOS tipos (ej: Simple O Matrimonial).
-- rooms.room_type_id sigue siendo el tipo POR DEFECTO; aquí van todas las opciones.
create table if not exists public.room_type_options (
  room_id      uuid not null references public.rooms(id)       on delete cascade,
  room_type_id uuid not null references public.room_types(id)  on delete restrict,
  primary key (room_id, room_type_id)
);

alter table public.room_type_options enable row level security;
create policy "dev_all_room_type_options"
  on public.room_type_options for all using (true) with check (true);
