"""
Generador de la migración que carga stg_estadias.csv a Supabase.

Crea la tabla `historical_stays` (una fila por estadía canónica) y la siembra con
INSERT multi-fila en lotes. Reproducible: si el ETL cambia, se re-corre.

Salida: supabase/migrations/20260703150000_load_historical_stays.sql
"""

from __future__ import annotations

import csv
import os

BASE = os.path.dirname(__file__)
STG = os.path.join(BASE, "output", "stg_estadias.csv")
MIGRATION = os.path.join(
    BASE, "..", "supabase", "migrations",
    "20260703150000_load_historical_stays.sql",
)
CHUNK = 500  # filas por INSERT

# (columna destino, columna origen en el csv, tipo)
COLS = [
    ("guest_name", "guest_name", "str"),
    ("room", "room", "int"),
    ("pax", "pax", "int"),
    ("check_in", "check_in", "date"),
    ("check_out", "check_out", "date"),
    ("nights", "nights", "int"),
    ("rate_bs", "rate_bs", "num"),
    ("total_bs", "total_bs", "num"),
    ("total_source", "total_source", "str"),
    ("payment", "payment", "str"),
    ("channel_raw", "channel", "str"),
    ("country", "country", "str"),
    ("is_multi_guest", "is_multi_guest", "bool"),
    ("quality_flags", "quality_flags", "str"),
]


def lit(val: str, kind: str) -> str:
    v = (val or "").strip()
    if v == "" or v.lower() in ("nan", "none"):
        return "NULL"
    if kind == "str":
        return "'" + v.replace("'", "''") + "'"
    if kind == "bool":
        return "true" if v.lower() in ("true", "1") else "false"
    if kind in ("int", "num"):
        try:
            return str(int(float(v))) if kind == "int" else str(float(v))
        except ValueError:
            return "NULL"
    if kind == "date":
        return "'" + v[:10] + "'"
    return "NULL"


def run() -> None:
    rows = list(csv.DictReader(open(STG, encoding="utf-8")))
    dest = ", ".join(c[0] for c in COLS)

    parts = [f"""-- =====================================================================
-- Carga de estadías históricas a Supabase (capa canónica del ETL).
-- Generado por etl/gen_historical_stays.py desde etl/output/stg_estadias.csv.
-- {len(rows):,} estadías. NO editar a mano: regenerar con el script.
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

-- Idempotencia: la carga es un snapshot; se vacía y recarga.
truncate public.historical_stays restart identity;

alter table public.historical_stays enable row level security;
create policy "dev_all_historical_stays"
  on public.historical_stays for all using (true) with check (true);
"""]

    for i in range(0, len(rows), CHUNK):
        chunk = rows[i:i + CHUNK]
        vals = ",\n".join(
            "  (" + ", ".join(lit(r[src], k) for _, src, k in COLS) + ")"
            for r in chunk
        )
        parts.append(
            f"\ninsert into public.historical_stays ({dest}) values\n{vals};\n"
        )

    with open(MIGRATION, "w", encoding="utf-8") as fh:
        fh.write("".join(parts))
    print(f"Migración escrita: {os.path.normpath(MIGRATION)}")
    print(f"  {len(rows):,} filas en lotes de {CHUNK}")


if __name__ == "__main__":
    run()
