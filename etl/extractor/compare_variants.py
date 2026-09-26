"""CLI: `python -m etl.extractor.compare_variants`.

Para cada grupo `needs_manual_review` de `etl/output/inventory.json`, imprime
una comparación lado a lado por archivo (ruta relativa, tamaño, mtime si
está disponible y, para hojas de cálculo: cantidad de hojas, primera/última
hoja, el rango de fechas real que resuelve el fechado de hojas de la Slice
2a -- con el MISMO year-hint que usa `process_workbook` (nombre de archivo
o año del inventario), nunca un default arbitrario -- cantidad de filas de
huésped no vacías, y la relación de conjuntos de noches `(fecha, room)`
resueltas contra el archivo base del grupo: idéntico / A⊂B / B⊂A /
overlapping / disjoint, con conteos de noches solo-en-A, solo-en-B, en
ambos y en conflicto (mismo día+room, huésped distinto)) y escribe
`etl/output/variant_comparison.csv`.

Reusa `etl.parsers.guest_nights.process_workbook` (Slice 2a) para las
observaciones -- NUNCA reimplementa su lógica de fechado/extracción.

NUNCA imprime nombres de huésped -- solo conteos y fechas. La decisión de
a cuál archivo quedarse pertenece a un humano (ver `etl/variant_decisions.csv`
y `etl.extractor.inventory.apply_variant_decisions`), nunca a una regla
automática (decisión #471).
"""
from __future__ import annotations

import csv
import json
from dataclasses import dataclass, fields
from datetime import date, datetime
from pathlib import Path

from etl.parsers.guest_nights import (
    NightObservation,
    _FILENAME_YEAR_RE,
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


def _initial_year_hint(path: Path, inventory_year: int | None) -> int | None:
    """MISMO camino que `process_workbook`: año del nombre de archivo si
    está, si no el año del inventario -- nunca un default arbitrario."""
    m = _FILENAME_YEAR_RE.search(path.name)
    return int(m.group(1)) if m else inventory_year


def spreadsheet_metrics_from_observations(
    sheet_names: list[str], dated: list[date | None], observations: list[NightObservation]
) -> dict:
    """Métricas de hoja/fecha/filas a partir de nombres de hoja + fechas ya
    resueltas (por `sequential_sheet_dates`, con el mismo year-hint que
    `process_workbook`) + observaciones ya extraídas (por `process_workbook`).
    Función pura, testeable sin tocar el filesystem."""
    if not sheet_names:
        return {}
    known_dates = [d for d in dated if d is not None]
    return {
        "sheet_count": len(sheet_names),
        "first_sheet": sheet_names[0],
        "last_sheet": sheet_names[-1],
        "date_range_start": min(known_dates).isoformat() if known_dates else None,
        "date_range_end": max(known_dates).isoformat() if known_dates else None,
        "guest_row_count": len(observations),
    }


def nights_map_from_observations(observations: list[NightObservation]) -> dict[tuple[str, int], str]:
    """`(fecha_iso, room) -> guest_name` -- solo se usa para detectar
    CONFLICTOS (mismo día+room, huésped distinto); nunca se imprime el
    nombre, solo el conteo de conflictos."""
    result: dict[tuple[str, int], str] = {}
    for obs in observations:
        if obs.night_date is not None and obs.room is not None:
            key = (obs.night_date.isoformat(), obs.room)
            result.setdefault(key, obs.guest_name)
    return result


def classify_relation(a: set, b: set) -> str:
    """Relación de conjuntos de noches `(fecha, room)` de A contra B."""
    if a == b:
        return "identical"
    if a and a < b:
        return "A_subset_B"
    if b and b < a:
        return "B_subset_A"
    if a & b:
        return "overlapping_different"
    return "disjoint"


def compare_nights(map_a: dict[tuple[str, int], str], map_b: dict[tuple[str, int], str]) -> dict:
    """Relación + conteos entre dos mapas `(fecha,room)->guest`. `conflicts`
    = noches presentes en ambos con huésped DISTINTO (nunca se imprime el
    nombre, solo el conteo)."""
    keys_a, keys_b = set(map_a), set(map_b)
    common = keys_a & keys_b
    conflicts = sum(1 for k in common if map_a[k] != map_b[k])
    return {
        "relation": classify_relation(keys_a, keys_b),
        "only_in_a": len(keys_a - keys_b),
        "only_in_b": len(keys_b - keys_a),
        "both_agree": len(common) - conflicts,
        "conflicts": conflicts,
    }


def _extract_observations(sheets: list[tuple[str, list[list]]], dated: list[date | None]) -> list[NightObservation]:
    """Reusa `find_header_row` + `extract_night_observations` de
    `etl.parsers.guest_nights` -- exactamente lo que hace `process_workbook`
    por hoja, sin reabrir el archivo (ya fue leído una vez para las
    métricas de hoja)."""
    observations: list[NightObservation] = []
    for i, (name, rows) in enumerate(sheets):
        header_idx = find_header_row(rows)
        if header_idx is None:
            continue
        observations.extend(extract_night_observations(rows, header_idx, dated[i], name, i, "", set()))
    return observations


def spreadsheet_metrics(
    path: Path, inventory_year: int | None
) -> tuple[dict, dict[tuple[str, int], str]]:
    """Lee `path` y devuelve (métricas, mapa de noches). El year-hint es
    EXACTAMENTE el que usaría `process_workbook` (nombre de archivo, si no
    el año del inventario) -- nunca un default arbitrario -- y el fechado +
    extracción reusan sus mismas funciones (`sequential_sheet_dates`,
    `find_header_row`, `extract_night_observations`)."""
    sheets = _read_sheets(path)
    if not sheets:
        return {}, {}
    sheet_names = [name for name, _rows in sheets]
    initial_year = _initial_year_hint(path, inventory_year)
    dated, _flags = sequential_sheet_dates(sheet_names, initial_year, None)
    observations = _extract_observations(sheets, dated)
    metrics = spreadsheet_metrics_from_observations(sheet_names, dated, observations)
    return metrics, nights_map_from_observations(observations)


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
    nights_relation: str | None
    nights_only_in_a: int | None  # "a" = baseline
    nights_only_in_b: int | None  # "b" = este archivo (si no es el baseline)
    nights_both_agree: int | None
    nights_conflicts: int | None


def build_group_comparison(
    group_key: str, rows: list[dict], hotel_root: Path
) -> list[FileComparison]:
    """Compara cada archivo del grupo contra un BASELINE (el primero, en
    orden determinístico de `load_needs_review_groups`) sin promediar ni
    descartar ninguno -- la elección final la hace un humano."""
    hotel_root = Path(hotel_root)
    family = rows[0].get("family", "unknown")
    baseline_path = hotel_root / rows[0]["path"]
    baseline_year = rows[0].get("year")
    baseline_metrics, baseline_nights = (
        spreadsheet_metrics(baseline_path, baseline_year) if _is_spreadsheet(baseline_path) else ({}, {})
    )

    comparisons: list[FileComparison] = []
    for idx, row in enumerate(rows):
        path = hotel_root / row["path"]
        is_baseline = idx == 0
        metrics: dict = baseline_metrics if is_baseline else {}
        nights: dict = baseline_nights if is_baseline else {}
        if not is_baseline and _is_spreadsheet(path):
            metrics, nights = spreadsheet_metrics(path, row.get("year"))

        mtime_iso = None
        if path.exists():
            mtime_iso = datetime.fromtimestamp(path.stat().st_mtime).isoformat()

        relation = only_a = only_b = both_agree = conflicts = None
        if not is_baseline and _is_spreadsheet(path):
            cmp = compare_nights(baseline_nights, nights)
            relation, only_a, only_b = cmp["relation"], cmp["only_in_a"], cmp["only_in_b"]
            both_agree, conflicts = cmp["both_agree"], cmp["conflicts"]

        comparisons.append(FileComparison(
            variant_group=group_key, family=family, path=row["path"],
            size_bytes=row.get("size"), mtime_iso=mtime_iso,
            sheet_count=metrics.get("sheet_count"), first_sheet=metrics.get("first_sheet"),
            last_sheet=metrics.get("last_sheet"),
            date_range_start=metrics.get("date_range_start"),
            date_range_end=metrics.get("date_range_end"),
            guest_row_count=metrics.get("guest_row_count"),
            is_baseline=is_baseline, nights_relation=relation,
            nights_only_in_a=only_a, nights_only_in_b=only_b,
            nights_both_agree=both_agree, nights_conflicts=conflicts,
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
        tag = "BASELINE (A)" if c.is_baseline else (
            f"relacion={c.nights_relation} solo_A={c.nights_only_in_a} "
            f"solo_B={c.nights_only_in_b} ambos={c.nights_both_agree} "
            f"conflictos={c.nights_conflicts}"
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
