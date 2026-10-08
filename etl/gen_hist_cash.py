"""
Generador de la carga de `hist_cash_movements` (caja histórica de `Hotel/`).

Los archivos de caja se solapan: el libro acumulativo 2015-04..2016-11 fue
re-guardado con 8 nombres, octubre 2014 existe en dos versiones y los
archivos mensuales arrancan con los últimos días del mes anterior. NO se
deduplica fila por fila (fusionaría dos cobros legítimos idénticos del mismo
día): cada mes se toma de UN solo archivo, por decisión humana registrada en
`etl/cash_month_sources.csv` (trackeado, solo rutas, sin PII).

Dos pasos:

1. `python -m etl.gen_hist_cash --propose` -> `etl/output/cash_month_sources_proposal.csv`:
   por mes, cada archivo candidato con su cantidad de movimientos y cuántos
   de ellos NO están en el candidato propuesto (el de más movimientos).
2. Un humano completa `etl/cash_month_sources.csv` (month, chosen_path,
   decided_by, decided_on, note, flag) y
   `python -m etl.gen_hist_cash --load` escribe `stg_hist_cash_movements.csv`
   + `load_hist_cash_movements.sql` (delete-by-source + inserts vía
   `etl/loader.py`, sin truncate) + `cash_issues.csv`.

Un mes con movimientos y sin decisión, o una decisión que apunta a un
archivo sin movimientos ese mes, es un error explícito (`CashMonthSourceError`).

Esta caja NO es el ingreso del hotel: desde mediados de 2015 la planilla
registra pocos movimientos y casi ningún egreso (ver etl/README.md).
"""
from __future__ import annotations

import argparse
import csv
import json
import os
from collections import Counter, defaultdict
from dataclasses import asdict
from pathlib import Path

from etl.loader import generate_load_sql
from etl.parsers.caja import CashMovement, parse_workbook

ETL_DIR = Path(__file__).resolve().parent
OUT_DIR = str(ETL_DIR / "output")
HOTEL_ROOT = ETL_DIR.parent / "Hotel"
INVENTORY_PATH = ETL_DIR / "output" / "inventory.json"
DECISIONS_PATH = str(ETL_DIR / "cash_month_sources.csv")
SOURCE = "hotel_archive"

PROPOSAL_NAME = "cash_month_sources_proposal.csv"
STAGING_NAME = "stg_hist_cash_movements.csv"
ISSUES_NAME = "cash_issues.csv"
SQL_NAME = "load_hist_cash_movements.sql"

DECISION_COLS = ["month", "chosen_path", "decided_by", "decided_on", "note", "flag"]

# (columna destino en hist_cash_movements, columna origen, tipo)
COLS = [
    ("movement_date", "movement_date", "date"),
    ("kind", "kind", "str"),
    ("currency", "currency", "str"),
    ("amount", "amount", "num"),
    ("concept", "concept", "str"),
    ("receipt_ref", "receipt_ref", "str"),
    ("receptionist", "receptionist", "str"),
    ("observations", "observations", "str"),
    ("source", "_source", "str"),
    ("source_file", "source_file", "str"),
    ("source_hash", "source_hash", "str"),
    ("sheet_name", "sheet_name", "str"),
    ("source_row", "source_row", "int"),
    ("quality_flags", "quality_flags", "str"),
]


class CashMonthSourceError(ValueError):
    """Decisión de fuente por mes faltante o inválida: nunca se ignora."""


def _month(m: CashMovement) -> str:
    return m.movement_date.strftime("%Y-%m")


def _key(m: CashMovement) -> tuple:
    return (m.movement_date, m.kind, m.currency, m.amount)


def _by_month_and_file(movements: list[CashMovement]) -> dict[str, dict[str, list[CashMovement]]]:
    grouped: dict[str, dict[str, list[CashMovement]]] = defaultdict(lambda: defaultdict(list))
    for m in movements:
        grouped[_month(m)][m.source_file].append(m)
    return grouped


def propose_month_sources(movements: list[CashMovement]) -> list[dict]:
    """Por mes y archivo candidato: movimientos, si es el propuesto (el de más
    movimientos; empate -> ruta mayor, determinista) y cuántos de sus
    movimientos faltan en el propuesto (comparación como multiconjunto de
    fecha+tipo+moneda+monto, nunca fusiona cobros idénticos)."""
    rows: list[dict] = []
    for month, files in sorted(_by_month_and_file(movements).items()):
        proposed = max(files, key=lambda path: (len(files[path]), path))
        proposed_keys = Counter(_key(m) for m in files[proposed])
        for path in sorted(files):
            absent = Counter(_key(m) for m in files[path]) - proposed_keys
            rows.append({
                "month": month,
                "candidate_path": path,
                "movements": len(files[path]),
                "proposed": path == proposed,
                "absent_from_proposed": sum(absent.values()),
            })
    return rows


def select_movements(movements: list[CashMovement], decisions: list[dict]) -> list[CashMovement]:
    """Movimientos de los meses decididos, solo del archivo elegido, con el
    `flag` de la decisión agregado a sus quality_flags."""
    grouped = _by_month_and_file(movements)
    by_month = {d["month"]: d for d in decisions}
    missing = sorted(set(grouped) - set(by_month))
    if missing:
        raise CashMonthSourceError(
            f"meses con movimientos de caja sin decisión en cash_month_sources.csv: {missing}"
        )
    stale = sorted(set(by_month) - set(grouped))
    if stale:
        raise CashMonthSourceError(
            f"decisiones para meses sin movimientos de caja (borrar del csv): {stale}"
        )
    selected: list[CashMovement] = []
    for month in sorted(grouped):
        decision = by_month[month]
        chosen = decision["chosen_path"]
        if chosen not in grouped[month]:
            raise CashMonthSourceError(
                f"{month}: {chosen} no tiene movimientos ese mes "
                f"(candidatos: {sorted(grouped[month])})"
            )
        extra = (decision.get("flag") or "").strip()
        for m in grouped[month][chosen]:
            if extra:
                m.quality_flags = ";".join(filter(None, [m.quality_flags, extra]))
            selected.append(m)
    return selected


def _is_cash_file(record: dict) -> bool:
    path = record["path"]
    name = os.path.basename(path)
    return (
        bool(record.get("is_canonical"))
        and "caja" in f"{record.get('family') or ''} {path}".lower()
        and name.lower().endswith((".xls", ".xlsx"))
        and not name.startswith("~$")  # lock-file temporal de Excel
    )


def parse_cash_files(hotel_root: Path, inventory_path: Path) -> tuple[list[CashMovement], list[dict], dict[str, str]]:
    """(movimientos, issues, md5 por ruta) de todos los archivos de caja
    canónicos. Un archivo sin encabezado de caja (falso positivo del filtro
    por nombre) no aporta nada."""
    with open(inventory_path, encoding="utf-8") as fh:
        records = [r for r in json.load(fh) if _is_cash_file(r)]
    movements: list[CashMovement] = []
    issues: list[dict] = []
    hashes: dict[str, str] = {}
    for record in sorted(records, key=lambda r: r["path"]):
        m, i = parse_workbook(hotel_root, record["path"])
        movements.extend(m)
        issues.extend(i)
        hashes[record["path"]] = record["md5"]
    return movements, issues, hashes


def _read_decisions(path: str) -> list[dict]:
    with open(path, encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def _write_csv(path: str, cols: list[str], rows: list[dict]) -> None:
    with open(path, "w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=cols)
        writer.writeheader()
        for r in rows:
            writer.writerow({c: r.get(c) for c in cols})


def run(
    mode: str,
    out_dir: str = OUT_DIR,
    decisions_path: str = DECISIONS_PATH,
    hotel_root: Path = HOTEL_ROOT,
    inventory_path: Path = INVENTORY_PATH,
) -> None:
    os.makedirs(out_dir, exist_ok=True)
    movements, issues, hashes = parse_cash_files(hotel_root, inventory_path)

    if mode == "propose":
        rows = propose_month_sources(movements)
        out = os.path.join(out_dir, PROPOSAL_NAME)
        _write_csv(out, ["month", "candidate_path", "movements", "proposed", "absent_from_proposed"], rows)
        months = len({r["month"] for r in rows})
        contested = sorted({r["month"] for r in rows if not r["proposed"]})
        print(f"Propuesta: {months} meses, {len(contested)} con más de un archivo candidato -> {out}")
        return

    selected = select_movements(movements, _read_decisions(decisions_path))
    staged = []
    for m in selected:
        row = asdict(m)
        row["source_hash"] = hashes.get(m.source_file)
        row["_source"] = SOURCE
        staged.append(row)
    chosen_files = {m.source_file for m in selected}

    _write_csv(os.path.join(out_dir, STAGING_NAME), [src for _, src, _ in COLS if src != "_source"], staged)
    _write_csv(os.path.join(out_dir, ISSUES_NAME), ["source_file", "sheet_name", "source_row", "reason"],
               [i for i in issues if i["source_file"] in chosen_files])

    sql = generate_load_sql("public.hist_cash_movements", COLS, staged, f"source = '{SOURCE}'")
    header = (
        "-- =====================================================================\n"
        "-- Carga de la caja histórica (datos con nombres del personal — no commitear).\n"
        "-- Generado por etl/gen_hist_cash.py --load.\n"
        f"-- {len(staged):,} movimientos. Rollback:\n"
        f"--   delete from public.hist_cash_movements where source = '{SOURCE}';\n"
        "-- =====================================================================\n\n"
    )
    sql_path = os.path.join(out_dir, SQL_NAME)
    with open(sql_path, "w", encoding="utf-8") as fh:
        fh.write(header + sql)
    print(f"Carga escrita: {os.path.normpath(sql_path)}")
    print(f"  {len(staged):,} movimientos de {len(chosen_files)} archivos, fuente '{SOURCE}'")


def main() -> None:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--propose", action="store_true")
    group.add_argument("--load", action="store_true")
    args = parser.parse_args()
    run("propose" if args.propose else "load")


if __name__ == "__main__":
    main()
