"""
Generador de la carga de stg_estadias.csv a Supabase.

La tabla `historical_stays` la crea la migración 20260703150000 (solo esquema).
Este script produce el SQL de DATOS: vacía la tabla y la siembra con INSERT
multi-fila en lotes, dentro de una transacción. Reproducible: si el ETL cambia,
se re-corre.

Los datos llevan nombres de huéspedes (PII): la salida va a etl/output/, que
está en .gitignore. NUNCA escribirla en supabase/migrations/.

Salida: etl/output/load_historical_stays.sql
"""

from __future__ import annotations

import csv
import os

BASE = os.path.dirname(__file__)
STG = os.path.join(BASE, "output", "stg_estadias.csv")
OUT = os.path.join(BASE, "output", "load_historical_stays.sql")
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
-- Carga de estadías históricas (datos, contiene PII — no commitear).
-- Generado por etl/gen_historical_stays.py desde etl/output/stg_estadias.csv.
-- {len(rows):,} estadías. Requiere la migración 20260703150000 aplicada.
-- =====================================================================

begin;

-- Idempotencia: la carga es un snapshot; se vacía y recarga.
truncate public.historical_stays restart identity;
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

    parts.append("\ncommit;\n")

    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write("".join(parts))
    print(f"Carga escrita: {os.path.normpath(OUT)}")
    print(f"  {len(rows):,} filas en lotes de {CHUNK}")


if __name__ == "__main__":
    run()
