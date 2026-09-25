-- =====================================================================
-- Tabla de estadías históricas (capa canónica del ETL).
--
-- Solo esquema. Los datos traen nombres de huéspedes (PII) y NO viven en
-- git: se generan con `python3 etl/gen_historical_stays.py` en
-- etl/output/load_historical_stays.sql (gitignored) y se cargan aparte
-- (ver etl/README.md). Hasta que se cargan, la tabla queda vacía.
--
-- Esta migración ya corrió en los ambientes remotos con los datos
-- incluidos; vaciarla no cambia nada allá, solo en bases nuevas.
-- =====================================================================

create table if not exists public.historical_stays (
  id             bigserial primary key,
  guest_name     text,
  room           integer,
  pax            integer,
  check_in       date,
  check_out      date,
  nights         integer,
  rate_bs        numeric(10,2),
  total_bs       numeric(10,2),
  total_source   varchar(12),
  payment        varchar(20),
  channel_raw    varchar(120),
  country        varchar(60),
  is_multi_guest boolean,
  quality_flags  text
);
create index if not exists idx_hs_checkin on public.historical_stays (check_in);
create index if not exists idx_hs_room    on public.historical_stays (room);

alter table public.historical_stays enable row level security;
create policy "dev_all_historical_stays"
  on public.historical_stays for all using (true) with check (true);
