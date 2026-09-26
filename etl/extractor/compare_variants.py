"""CLI: `python -m etl.extractor.compare_variants`.

Para cada grupo `needs_manual_review` de `etl/output/inventory.json`, imprime
una comparación lado a lado por archivo (ruta relativa, tamaño, mtime si
está disponible y, para hojas de cálculo: cantidad de hojas, primera/última
hoja, el rango de fechas que resuelve el fechado de hojas de la Slice 2a
-- reutilizando `etl.parsers.guest_nights` sin duplicar su lógica --,
cantidad de filas de huésped no vacías y si las noches resueltas de un
archivo son superconjunto de las del archivo base del grupo) y escribe
`etl/output/variant_comparison.csv`.

NUNCA imprime nombres de huésped -- solo conteos y fechas. La decisión de
a cuál archivo quedarse pertenece a un humano (ver `etl/variant_decisions.csv`
y `etl.extractor.inventory.apply_variant_decisions`), nunca a una regla
automática (decisión #471).
"""
from __future__ import annotations

import csv
import json
from dataclasses import dataclass, fields
from datetime import datetime
from pathlib import Path

from etl.parsers.guest_nights import (
    _read_xls_sheets,
    _read_xlsx_sheets,
    extract_night_observations,
    find_header_row,
    sequential_sheet_dates,
)

ETL_DIR = Path(__file__).resolve().parent.parent
OUT_DIR = ETL_DIR / "output"
INVENTORY_JSON = OUT_DIR / "inventory.json"
COMPARISON_CSV = OUT_DIR / "variant_comparison.csv"


def load_needs_review_groups(inventory_path: Path) -> dict[str, list[dict]]:
    """Filtra las filas `needs_manual_review` del manifest y las agrupa por
    `variant_group` (orden determinístico por `path`)."""
    inventory_path = Path(inventory_path)
    if not inventory_path.exists():
        return {}
    rows = json.loads(inventory_path.read_text(encoding="utf-8"))
    groups: dict[str, list[dict]] = {}
    for row in rows:
        if row.get("reason") == "needs_manual_review" and row.get("variant_group"):
            groups.setdefault(row["variant_group"], []).append(row)
    for rows_in_group in groups.values():
        rows_in_group.sort(key=lambda r: r["path"])
    return groups


def _is_spreadsheet(path: Path) -> bool:
    return path.suffix.lower() in (".xls", ".xlsx")


def _read_sheets(path: Path) -> list[tuple[str, list[list]]]:
    suffix = path.suffix.lower()
    if suffix == ".xlsx":
        return _read_xlsx_sheets(path)
    if suffix == ".xls":
        return _read_xls_sheets(path)
    return []


def spreadsheet_metrics_from_sheets(
    sheets: list[tuple[str, list[list]]]
) -> tuple[dict, set[tuple[str, int]]]:
    """Métricas de hojas de cálculo a partir de `(nombre_hoja, filas)` ya
    leídas. Reusa el fechado de hojas y la extracción de filas de huésped de
    `etl.parsers.guest_nights` (Slice 2a) sin duplicar su lógica.

    Devuelve `(metrics, nights)` donde `nights` es el set de
    `(fecha_iso, habitacion)` resuelto -- nunca nombres de huésped.
    """
    if not sheets:
        return {}, set()
    sheet_names = [name for name, _rows in sheets]
    dated, _flags = sequential_sheet_dates(sheet_names, None, None)
    known_dates = [d for d in dated if d is not None]

    nights: set[tuple[str, int]] = set()
    guest_row_count = 0
    for i, (name, rows) in enumerate(sheets):
        header_idx = find_header_row(rows)
        if header_idx is None:
            continue
        for obs in extract_night_observations(rows, header_idx, dated[i], name, i, "", set()):
            guest_row_count += 1
            if obs.night_date is not None and obs.room is not None:
                nights.add((obs.night_date.isoformat(), obs.room))

    metrics = {
        "sheet_count": len(sheets),
        "first_sheet": sheet_names[0],
        "last_sheet": sheet_names[-1],
        "date_range_start": min(known_dates).isoformat() if known_dates else None,
        "date_range_end": max(known_dates).isoformat() if known_dates else None,
        "guest_row_count": guest_row_count,
    }
    return metrics, nights


def spreadsheet_metrics(path: Path) -> tuple[dict, set[tuple[str, int]]]:
    return spreadsheet_metrics_from_sheets(_read_sheets(path))


@dataclass
class FileComparison:
    variant_group: str
    family: str
    path: str
    size_bytes: int | None
    mtime_iso: str | None
    sheet_count: int | None
    first_sheet: str | None
    last_sheet: str | None
    date_range_start: str | None
    date_range_end: str | None
    guest_row_count: int | None
    is_baseline: bool
    superset_of_baseline: bool | None
    subset_of_baseline: bool | None


def build_group_comparison(
    group_key: str, rows: list[dict], hotel_root: Path
) -> list[FileComparison]:
    """Compara cada archivo del grupo contra un BASELINE (el primero, en
    orden determinístico de `load_needs_review_groups`) sin promediar ni
    descartar ninguno -- la elección final la hace un humano."""
    hotel_root = Path(hotel_root)
    family = rows[0].get("family", "unknown")
    baseline_path = hotel_root / rows[0]["path"]
    baseline_metrics, baseline_nights = (
        spreadsheet_metrics(baseline_path) if _is_spreadsheet(baseline_path) else ({}, set())
    )

    comparisons: list[FileComparison] = []
    for idx, row in enumerate(rows):
        path = hotel_root / row["path"]
        is_baseline = idx == 0
        metrics: dict = baseline_metrics if is_baseline else {}
        nights: set = baseline_nights if is_baseline else set()
        if not is_baseline and _is_spreadsheet(path):
            metrics, nights = spreadsheet_metrics(path)

        mtime_iso = None
        if path.exists():
            mtime_iso = datetime.fromtimestamp(path.stat().st_mtime).isoformat()

        superset = subset = None
        if not is_baseline and _is_spreadsheet(path):
            superset = nights.issuperset(baseline_nights)
            subset = nights.issubset(baseline_nights)

        comparisons.append(FileComparison(
            variant_group=group_key, family=family, path=row["path"],
            size_bytes=row.get("size"), mtime_iso=mtime_iso,
            sheet_count=metrics.get("sheet_count"), first_sheet=metrics.get("first_sheet"),
            last_sheet=metrics.get("last_sheet"),
            date_range_start=metrics.get("date_range_start"),
            date_range_end=metrics.get("date_range_end"),
            guest_row_count=metrics.get("guest_row_count"),
            is_baseline=is_baseline, superset_of_baseline=superset,
            subset_of_baseline=subset,
        ))
    return comparisons


_CSV_FIELDS = [f.name for f in fields(FileComparison)]


def write_comparison_csv(rows: list[FileComparison], output_path: Path = COMPARISON_CSV) -> None:
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=_CSV_FIELDS)
        writer.writeheader()
        for r in rows:
            writer.writerow({field: getattr(r, field) for field in _CSV_FIELDS})


def _print_group(group_key: str, comparisons: list[FileComparison]) -> None:
    print(f"\n== {group_key} ({len(comparisons)} archivos) ==")
    for c in comparisons:
        tag = "BASELINE" if c.is_baseline else (
            f"superset={c.superset_of_baseline} subset={c.subset_of_baseline}"
        )
        print(f"  {c.path}")
        print(f"    size={c.size_bytes} mtime={c.mtime_iso} {tag}")
        if c.sheet_count is not None:
            print(
                f"    hojas={c.sheet_count} primera={c.first_sheet!r} ultima={c.last_sheet!r} "
                f"rango=[{c.date_range_start}..{c.date_range_end}] filas_huesped={c.guest_row_count}"
            )


def main() -> None:
    groups = load_needs_review_groups(INVENTORY_JSON)
    if not groups:
        print(f"Sin grupos needs_manual_review en {INVENTORY_JSON}")
        return

    hotel_root = ETL_DIR.parent / "Hotel"
    all_rows: list[FileComparison] = []
    for group_key in sorted(groups):
        comparisons = build_group_comparison(group_key, groups[group_key], hotel_root)
        _print_group(group_key, comparisons)
        all_rows.extend(comparisons)

    write_comparison_csv(all_rows)
    print(f"\n{len(groups)} grupos, {len(all_rows)} archivos -> {COMPARISON_CSV}")


if __name__ == "__main__":
    main()
