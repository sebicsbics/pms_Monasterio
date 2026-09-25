-- =====================================================================
-- Agrega columna `source` a historical_stays para poder cargar/rollback
-- por fuente (md, hotel_archive, ...) sin truncar la tabla completa.
-- Solo esquema, sin datos (PII) — ver etl/README.md.
-- =====================================================================

alter table public.historical_stays
  add column if not exists source varchar(20) not null default 'md';

create index if not exists idx_hs_source on public.historical_stays (source);
