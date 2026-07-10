-- =====================================================================
-- MÓDULO MANTENIMIENTO — categorías como tabla de referencia.
--
-- Antes eran un CHECK hardcodeado en dos tablas: agregar/renombrar una obligaba
-- una migración de schema. Ahora son datos: un INSERT alcanza. Mismo patrón que
-- reservation_channels y payment_methods.
--
-- Cambios respecto del set inicial: se quitan 'ac' y no se agrega 'ascensores'
-- (el hotel no tiene ninguno). Se suman gas, tecnología, acabados, industriales,
-- seguridad, jardinería y control de plagas. Cerrajería va dentro de Seguridad.
-- =====================================================================

create table if not exists public.maintenance_categories (
  code       varchar(20) primary key,
  label      varchar(60) not null,
  sort_order integer not null default 100,
  is_active  boolean not null default true
);

insert into public.maintenance_categories (code, label, sort_order) values
  ('plumbing',   'Plomería',               10),
  ('electrical', 'Eléctrico',              20),
  ('appliance',  'Electrodoméstico',       30),
  ('furniture',  'Mobiliario',             40),
  ('structural', 'Estructural',            50),
  ('gas',        'Gas',                    60),
  ('tech',       'Tecnología y Redes',     70),
  ('finishes',   'Acabados y Estética',    80),
  ('industrial', 'Equipos Industriales',   90),
  ('safety',     'Seguridad y Prevención', 100),
  ('grounds',    'Jardinería y Exteriores',110),
  ('pest',       'Control de Plagas',      120),
  ('other',      'Otro',                   999)
on conflict (code) do nothing;

alter table public.maintenance_categories enable row level security;
create policy "dev_all_maintenance_categories"
  on public.maintenance_categories for all using (true) with check (true);

-- ---------- Migrar tickets y agendas de CHECK a FK ----------
-- 1) Quitar el CHECK viejo.
alter table public.maintenance_tickets
  drop constraint if exists maintenance_tickets_category_check;
alter table public.maintenance_schedules
  drop constraint if exists maintenance_schedules_category_check;

-- 2) Remapear categorías que ya no existen (ej: 'ac') a 'other' para no romper el FK.
update public.maintenance_tickets
  set category = 'other'
  where category not in (select code from public.maintenance_categories);
update public.maintenance_schedules
  set category = 'other'
  where category not in (select code from public.maintenance_categories);

-- 3) Cambiar el default 'ac'->'other' (ya era 'other', pero lo dejamos explícito).
alter table public.maintenance_tickets  alter column category set default 'other';
alter table public.maintenance_schedules alter column category set default 'other';

-- 4) Enganchar el FK a la tabla de referencia.
alter table public.maintenance_tickets
  add constraint fk_mt_category
  foreign key (category) references public.maintenance_categories(code);
alter table public.maintenance_schedules
  add constraint fk_msch_category
  foreign key (category) references public.maintenance_categories(code);
