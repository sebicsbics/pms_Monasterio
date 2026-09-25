"""
Generador de la carga de estadías históricas a Supabase, por fuente.

La tabla `historical_stays` la crea la migración 20260703150000 (solo esquema)
+ 20260925000000 (agrega columna `source`). Este script produce el SQL de
DATOS vía `etl/loader.py` (delete-by-source + inserts multi-fila, sin
truncate) para una fuente a la vez:

- `--source md`: lee `etl/output/stg_estadias.csv` -> `load_historical_stays_md.sql`.
- `--source hotel_archive`: lee `etl/output/stg_estadias_archive.csv`, le
  aplica dedupe local contra `stg_estadias.csv` (misma room + rango de fechas
  [check_in, check_out) que se solapa; el rango real de solape es 2015-2016,
  ver `etl/output/dedupe_report.csv`) y carga el resto ->
  `load_historical_stays_hotel_archive.sql`. md siempre gana el solape (ya
  está cargado y es el dataset canónico; hotel_archive es complementario).

Los datos llevan nombres de huéspedes (PII): la salida va a etl/output/, que
está en .gitignore. NUNCA escribirla en supabase/migrations/.
"""

from __future__ import annotations

import argparse
import csv
import os
from datetime import date

from etl.loader import generate_load_sql

BASE = os.path.dirname(__file__)
OUT_DIR = os.path.join(BASE, "output")
STG_MD = os.path.join(OUT_DIR, "stg_estadias.csv")
STG_ARCHIVE = os.path.join(OUT_DIR, "stg_estadias_archive.csv")
DEDUPE_REPORT = os.path.join(OUT_DIR, "dedupe_report.csv")

# (columna destino en historical_stays, columna origen en el csv, tipo)
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
    ("source", "_source", "str"),
]


def _read_csv(path: str) -> list[dict]:
    with open(path, encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def _parse_date(s: str) -> date | None:
    s = (s or "").strip()
    return date.fromisoformat(s[:10]) if s else None


def _overlaps(a_in: date, a_out: date, b_in: date, b_out: date) -> bool:
    """Rangos semiabiertos [in, out): se solapan si a_in < b_out y b_in < a_out."""
    return a_in < b_out and b_in < a_out


def local_dedupe(archive_rows: list[dict], md_rows: list[dict]) -> tuple[list[dict], list[dict]]:
    """Excluye de archive_rows las estadías que solapan (misma room + rango de
    fechas superpuesto) con una estadía de md_rows. md siempre gana: ya está
    cargado y es el dataset canónico. Filas sin room/check_in/check_out en
    alguno de los lados no se comparan (se mantienen, no se pierden en
    silencio). Devuelve (kept, dedupe_report)."""
    by_room: dict[int, list[tuple[int, dict]]] = {}
    for i, r in enumerate(md_rows):
        if not r.get("room") or not r.get("check_in") or not r.get("check_out"):
            continue
        by_room.setdefault(int(r["room"]), []).append((i, r))

    kept: list[dict] = []
    report: list[dict] = []
    for r in archive_rows:
        if not r.get("room") or not r.get("check_in") or not r.get("check_out"):
            kept.append(r)
            continue
        room = int(r["room"])
        a_in, a_out = _parse_date(r["check_in"]), _parse_date(r["check_out"])
        match = None
        for i, mr in by_room.get(room, []):
            b_in, b_out = _parse_date(mr["check_in"]), _parse_date(mr["check_out"])
            if _overlaps(a_in, a_out, b_in, b_out):
                match = (i, mr)
                break
        if match is None:
            kept.append(r)
            continue
        i, mr = match
        report.append({
            "room": room,
            "archive_guest_name": r.get("guest_name"),
            "archive_check_in": r["check_in"],
            "archive_check_out": r["check_out"],
            "md_row_index": i,
            "md_guest_name": mr.get("guest_name"),
            "md_check_in": mr["check_in"],
            "md_check_out": mr["check_out"],
        })
    return kept, report


def _write_dedupe_report(report: list[dict]) -> None:
    cols = ["room", "archive_guest_name", "archive_check_in", "archive_check_out",
            "md_row_index", "md_guest_name", "md_check_in", "md_check_out"]
    with open(DEDUPE_REPORT, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(cols)
        for r in report:
            w.writerow([r[c] for c in cols])


def run(source: str) -> None:
    os.makedirs(OUT_DIR, exist_ok=True)

    if source == "md":
        rows = _read_csv(STG_MD)
    else:
        archive_rows = _read_csv(STG_ARCHIVE)
        md_rows = _read_csv(STG_MD)
        rows, report = local_dedupe(archive_rows, md_rows)
        _write_dedupe_report(report)
        print(f"Dedupe local: {len(archive_rows):,} estadías hotel_archive -> "
              f"{len(rows):,} tras excluir {len(report):,} solapadas con md "
              f"(reporte: {os.path.normpath(DEDUPE_REPORT)})")

    for r in rows:
        r["_source"] = source

    out_path = os.path.join(OUT_DIR, f"load_historical_stays_{source}.sql")
    sql = generate_load_sql(
        "public.historical_stays", COLS, rows, f"source = '{source}'",
    )
    header = (
        "-- =====================================================================\n"
        "-- Carga de estadías históricas (datos, contiene PII — no commitear).\n"
        f"-- Generado por etl/gen_historical_stays.py --source {source}.\n"
        f"-- {len(rows):,} estadías. Requiere las migraciones 20260703150000 y\n"
        "-- 20260925000000 aplicadas. Rollback por fuente:\n"
        f"--   delete from public.historical_stays where source = '{source}';\n"
        "-- =====================================================================\n\n"
    )
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(header + sql)
    print(f"Carga escrita: {os.path.normpath(out_path)}")
    print(f"  {len(rows):,} filas, fuente '{source}'")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", choices=["md", "hotel_archive"], required=True)
    args = parser.parse_args()
    run(args.source)


if __name__ == "__main__":
    main()
