-- =====================================================================
-- Caja histórica de recepción (archivo Hotel/, 2013-2016).
--
-- Solo esquema. Los datos llevan nombres del personal y se generan con
-- `python -m etl.gen_hist_cash --load` en etl/output/ (gitignored); se
-- cargan aparte (ver etl/README.md). Hasta entonces la tabla queda vacía.
--
-- Tabla SEPARADA de `cash_movements` a propósito: mezclar el historial con
-- la caja viva metería movimientos de 2014 en los cierres, conciliaciones y
-- reportes del PMS, y recargar el historial tocaría datos de producción.
-- Las columnas de negocio usan los mismos nombres que `cash_movements`
-- (kind, amount, concept...) para que una vista `union all` alcance el día
-- que se quiera una serie 2013-hoy.
--
-- OJO al leerla: NO es el ingreso del hotel. Desde mediados de 2015 la
-- planilla registra pocos movimientos y casi ningún egreso (2016-02: ~6.000
-- Bs de caja contra ~33.000 Bs de hospedaje). Es un registro fiel de lo que
-- pasó por esa planilla, no la contabilidad.
--
-- Nace cerrada (lección de 20260812000000_close_public_reads, cuando
-- `anon` leía `historical_stays`): sin acceso para anon/PUBLIC, solo
-- lectura para el personal, sin políticas de escritura (la carga corre como
-- dueño de la tabla desde el SQL del ETL).
-- =====================================================================

create table if not exists public.hist_cash_movements (
  id             bigserial primary key,
  movement_date  date          not null,
  kind           text          not null check (kind in ('income', 'expense')),
  currency       char(3)       not null check (currency in ('BOB', 'USD')),
  -- Sin check de signo, a diferencia de cash_movements: el archivo trae
  -- correcciones con monto negativo y se conservan tal cual, marcadas con
  -- quality_flags 'negative_amount'.
  amount         numeric(12,2) not null,
  concept        text,                     -- columna DETALLE, texto libre
  receipt_ref    text,                     -- Nº REC-FACT, sin formato fijo
  receptionist   text,
  observations   text,
  category       text,                     -- reservada: clasificación curada futura
  source         varchar(20)   not null default 'hotel_archive',
  source_file    text          not null,   -- ruta relativa dentro de Hotel/
  source_hash    text,                     -- md5 del archivo (inventario)
  sheet_name     text,
  source_row     integer,                  -- fila 1-based en la hoja
  quality_flags  text
);

create index if not exists idx_hcm_date   on public.hist_cash_movements (movement_date);
create index if not exists idx_hcm_source on public.hist_cash_movements (source);

alter table public.hist_cash_movements enable row level security;

drop policy if exists hist_cash_movements_read on public.hist_cash_movements;
create policy hist_cash_movements_read on public.hist_cash_movements
  for select using (public.is_staff());

-- Dos barreras, no una: la RLS de arriba y además los permisos de tabla.
-- Los default privileges de 20260811000000 dan `all` a authenticated; acá
-- se deja solo `select`, y a anon/PUBLIC nada.
revoke all on table public.hist_cash_movements from public, anon, authenticated;
grant select on table public.hist_cash_movements to authenticated;
revoke all on sequence public.hist_cash_movements_id_seq from public, anon, authenticated;
