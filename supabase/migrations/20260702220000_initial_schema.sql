-- =====================================================================
-- PMS Hotel Monasterio — Esquema base
-- Portado desde la base PostgreSQL local (Docker: hotel-monasterio-db).
-- Diseño normalizado original del usuario, adaptado para Supabase + RLS.
-- Precios en Bs (bolivianos).
-- =====================================================================

-- UUIDs: usamos gen_random_uuid(), incorporado en el núcleo de PostgreSQL 13+
-- (no requiere extensión). Es el enfoque recomendado por Supabase.

-- Dominio de estado de ciclo de vida de entidades.
do $$
begin
  if not exists (select 1 from pg_type where typname = 'entity_status') then
    create domain public.entity_status as varchar(15)
      constraint entity_status_check
      check (value in ('active','inactive','maintenance','deleted'));
  end if;
end$$;

-- Función de trigger: mantiene updated_at al día.
create or replace function public.trigger_set_timestamp()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------- PEOPLE (base de la herencia persona) ----------
create table if not exists public.people (
  id         uuid primary key default gen_random_uuid(),
  first_name varchar(100) not null,
  last_name  varchar(100) not null,
  email      varchar(255) not null unique,
  birth_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_people_email on public.people (email);

-- ---------- EMPLOYEES (especialización de people) ----------
create table if not exists public.employees (
  person_id uuid primary key references public.people(id) on delete cascade,
  job_title varchar(100) not null,
  hire_date date not null,
  salary    numeric(10,2),
  status    public.entity_status default 'active'
);

-- ---------- GUESTS (especialización de people) ----------
create table if not exists public.guests (
  person_id         uuid primary key references public.people(id) on delete cascade,
  online_account_id varchar(255) unique,
  country_code      char(3),
  city              varchar(100),
  wants_offers      boolean default false,
  passport_number   varchar(50)
);

-- ---------- ROOM_TYPES (tipos de habitación) ----------
create table if not exists public.room_types (
  id            uuid primary key default gen_random_uuid(),
  name          varchar(100) not null unique,
  base_price_bs numeric(10,2) not null check (base_price_bs > 0),
  max_occupancy integer not null check (max_occupancy > 0),
  description   text
);

-- ---------- BED_TYPES (tipos de cama) ----------
create table if not exists public.bed_types (
  id   uuid primary key default gen_random_uuid(),
  name varchar(50) not null unique
);

-- ---------- ROOMS (habitaciones) ----------
create table if not exists public.rooms (
  id           uuid primary key default gen_random_uuid(),
  room_number  varchar(10) not null unique,
  floor        integer,
  has_patio    boolean default false,
  room_type_id uuid not null references public.room_types(id),
  status       public.entity_status default 'active'
);
create index if not exists idx_rooms_type on public.rooms (room_type_id);

-- ---------- ROOM_BED_ASSIGNMENTS (camas por habitación) ----------
create table if not exists public.room_bed_assignments (
  room_id     uuid not null references public.rooms(id) on delete cascade,
  bed_type_id uuid not null references public.bed_types(id) on delete cascade,
  quantity    integer not null default 1 check (quantity > 0),
  primary key (room_id, bed_type_id)
);

-- ---------- RESERVATIONS (reservas) ----------
create table if not exists public.reservations (
  id                 uuid primary key default gen_random_uuid(),
  guest_id           uuid not null references public.guests(person_id),
  room_id            uuid references public.rooms(id),
  room_type_id       uuid not null references public.room_types(id),
  check_in_date      date not null,
  check_out_date     date not null,
  reservation_method varchar(50) default 'web',
  payment_method     varchar(50),
  payment_status     varchar(20) default 'pending'
                     check (payment_status in ('pending','paid','refunded','failed')),
  total_amount_bs    numeric(10,2),
  status             varchar(20) default 'confirmed'
                     check (status in ('confirmed','checked_in','checked_out','cancelled')),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint check_dates_order check (check_out_date > check_in_date)
);
create index if not exists idx_reservations_dates on public.reservations (check_in_date, check_out_date);
create index if not exists idx_reservations_guest on public.reservations (guest_id);

create trigger set_people_timestamp before update on public.people
  for each row execute function public.trigger_set_timestamp();
create trigger set_reservations_timestamp before update on public.reservations
  for each row execute function public.trigger_set_timestamp();

-- =====================================================================
-- ROW LEVEL SECURITY — activado en todas las tablas.
-- Políticas TEMPORALES de desarrollo (MVP sin auth todavía).
-- ⚠️ TODO FASE 6: reemplazar por políticas basadas en auth.uid() / rol.
-- =====================================================================
alter table public.people               enable row level security;
alter table public.employees            enable row level security;
alter table public.guests               enable row level security;
alter table public.room_types           enable row level security;
alter table public.bed_types            enable row level security;
alter table public.rooms                enable row level security;
alter table public.room_bed_assignments enable row level security;
alter table public.reservations         enable row level security;

create policy "dev_all_people"    on public.people               for all using (true) with check (true);
create policy "dev_all_employees" on public.employees            for all using (true) with check (true);
create policy "dev_all_guests"    on public.guests               for all using (true) with check (true);
create policy "dev_all_rtypes"    on public.room_types           for all using (true) with check (true);
create policy "dev_all_btypes"    on public.bed_types            for all using (true) with check (true);
create policy "dev_all_rooms"     on public.rooms                for all using (true) with check (true);
create policy "dev_all_rba"       on public.room_bed_assignments for all using (true) with check (true);
create policy "dev_all_resv"      on public.reservations         for all using (true) with check (true);
