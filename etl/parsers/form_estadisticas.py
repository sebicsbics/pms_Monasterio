"""Parser de FORM ESTADISTICAS (Formulario Nº 6, Viceministerio de Turismo).

Ver spec/design #451/#452/#453 y evidencia de campos relevada en el apply de
la Slice 3b (muestreo de `.xls` reales en `Hotel/Night Audit/PARTES DIARIOS
- ESTADISTICAS/`, `Hotel/2015/Estadisticas 2015/`, `Hotel/Night Audit/
ESTADISTICAS HOTELERAS/` y `Hotel/Sergio (Revisar)/`).

El formulario NO calcula un % de ocupación: solo reporta, día a día, en la
hoja "Ocup. Hotelera", dos columnas ("Habitaciones ocupadas por noche" y
"Numero de Personas que la Ocuparon") con un total mensual en la fila
"Total". La capacidad declarada (fija, "Total Nº de Hb.__36") vive en la
primera hoja del workbook junto con "Mes X" / "Año Y". El % reportado se
deriva acá como:

    room_nights_reported / (room_count_reported * días_del_mes) * 100

Solo se procesan registros canónicos del inventario (`is_canonical=True`)
cuya familia o ruta contiene "ESTADISTICAS" -- la precedencia de duplicados
byte-idénticos ya la resolvió `etl.extractor.inventory` (Requirement
"Duplicate precedence"). Cuando DOS archivos canónicos distintos reportan el
mismo (year, month) con contenido distinto (ej. una copia editada a mano en
"Sergio (Revisar)" vs la copia "oficial" en "Night Audit"), NINGUNO se
descarta en silencio: ambos quedan en la salida y el mes aparece además en
`etl/output/form_estadisticas_conflicts.csv`.
"""
from __future__ import annotations

import calendar
import csv
import json
from collections import defaultdict
from dataclasses import asdict, dataclass, fields
from pathlib import Path

from etl.parsers.guest_nights import MONTHS, _strip_accents_lower

ETL_DIR = Path(__file__).resolve().parent.parent
OUT_DIR = ETL_DIR / "output"
INVENTORY_PATH = OUT_DIR / "inventory.json"
OUTPUT_PATH = OUT_DIR / "stg_form_estadisticas.csv"
CONFLICTS_PATH = OUT_DIR / "form_estadisticas_conflicts.csv"

_MONTH_NAME_BY_NUM = {v: k for k, v in MONTHS.items()}


@dataclass
class FormEstadisticaRecord:
    year: int | None
    month: int | None
    room_nights_reported: float | None
    pax_reported: float | None
    room_count_reported: int | None
    source_file: str
    quality_flags: str


def _cell_flags_join(flags: list[str]) -> str:
    return ";".join(sorted(set(flags)))


def parse_month_label(text: object) -> int | None:
    """'Mes MARZO' -> 3. None si no matchea."""
    if not isinstance(text, str):
        return None
    stripped = text.strip()
    if not _strip_accents_lower(stripped).startswith("mes "):
        return None
    token = _strip_accents_lower(stripped)[4:].strip()
    return MONTHS.get(token)


def parse_year_label(text: object) -> int | None:
    """'Año 2016' -> 2016. None si no matchea."""
    if not isinstance(text, str):
        return None
    stripped = _strip_accents_lower(text.strip())
    if not stripped.startswith("ano "):
        return None
    token = stripped[4:].strip()
    return int(token) if token.isdigit() else None


def parse_room_count_label(text: object) -> int | None:
    """'Total Nº de Hb.__36' -> 36. None si no matchea."""
    if not isinstance(text, str):
        return None
    stripped = _strip_accents_lower(text.strip())
    if "total n" not in stripped or " de hb" not in stripped:
        return None
    digits = "".join(ch for ch in stripped if ch.isdigit())
    return int(digits) if digits else None


def extract_month_metadata(cells: list[tuple[int, int, object]]) -> dict:
    """Escanea las celdas de la hoja índice 0 buscando mes/año/capacidad.

    `cells` es una lista de (row, col, value) -- típicamente todas las
    celdas de la hoja, en cualquier orden. Robusto a drift de posición
    porque matchea por prefijo de texto, no por (row, col) fija.
    """
    month = year = room_count = None
    for _row, _col, value in cells:
        if month is None:
            m = parse_month_label(value)
            if m is not None:
                month = m
        if year is None:
            y = parse_year_label(value)
            if y is not None:
                year = y
        if room_count is None:
            rc = parse_room_count_label(value)
            if rc is not None:
                room_count = rc
    return {"month": month, "year": year, "room_count": room_count}


def _find_occupancy_header(rows: list[list]) -> tuple[int | None, int | None, int | None]:
    """(fila de encabezado, columna de habitaciones, columna de personas) de
    la hoja 'Ocup. Hotelera'; None donde no se encuentra."""
    header_row_idx = None
    room_col = pax_col = None
    for idx, row in enumerate(rows):
        for c, value in enumerate(row):
            if isinstance(value, str):
                norm = _strip_accents_lower(value)
                if "habitaciones ocupadas" in norm:
                    room_col = c
                    header_row_idx = idx
                elif "numero de personas" in norm:
                    pax_col = c
        if header_row_idx is not None and room_col is not None:
            break
    return header_row_idx, room_col, pax_col


def _is_number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _is_filled_count(value: object) -> bool:
    """Celda de conteo cargada: número, o número tipeado como texto ("0")."""
    if _is_number(value):
        return True
    if isinstance(value, str):
        try:
            float(value.strip())
        except ValueError:
            return False
        return True
    return False


def missing_form_days(rows: list[list], days_in_month: int) -> list[int]:
    """Días del mes cuya fila existe en la plantilla de 'Ocup. Hotelera' pero
    con la celda de habitaciones en blanco: nadie los cargó.

    Un 0 explícito es un día sin huéspedes (dato real), no un faltante. Las
    filas de la plantilla más allá del fin de mes (29-31 en febrero) no
    cuentan. Sin columna 'Día' no se puede juzgar y devuelve [] (caso real
    2016-03: formulario guardado el día 7, días 8-31 en blanco)."""
    header_row_idx, room_col, _pax_col = _find_occupancy_header(rows)
    if header_row_idx is None or room_col is None:
        return []
    day_col = next(
        (c for c, v in enumerate(rows[header_row_idx])
         if isinstance(v, str) and _strip_accents_lower(v.strip()) == "dia"),
        None,
    )
    if day_col is None:
        return []

    missing: set[int] = set()
    for row in rows[header_row_idx + 1:]:
        if day_col >= len(row) or not _is_number(row[day_col]):
            continue
        day = row[day_col]
        if day != int(day) or not 1 <= day <= days_in_month:
            continue
        value = row[room_col] if room_col < len(row) else ""
        if not _is_filled_count(value):
            missing.add(int(day))
    return sorted(missing)


def extract_occupancy_totals(rows: list[list]) -> tuple[float | None, float | None, list[str]]:
    """Busca la fila de encabezado ('Habitaciones ocupadas por noche' /
    'Numero de Personas que la Ocuparon') en la hoja 'Ocup. Hotelera' y
    devuelve los valores de la fila 'Total' en esas mismas columnas.
    """
    flags: list[str] = []
    header_row_idx, room_col, pax_col = _find_occupancy_header(rows)
    if header_row_idx is None or room_col is None:
        flags.append("missing_occupancy_header")
        return None, None, flags

    total_row = None
    for row in rows[header_row_idx + 1:]:
        if row and isinstance(row[0], str) and _strip_accents_lower(row[0].strip()) == "total":
            total_row = row
            break
    if total_row is None:
        # Fallback: la etiqueta "Total" puede estar en la columna del día
        # (col 1) en vez de la col 0.
        for row in rows[header_row_idx + 1:]:
            for value in row[:2]:
                if isinstance(value, str) and _strip_accents_lower(value.strip()) == "total":
                    total_row = row
                    break
            if total_row is not None:
                break
    if total_row is None:
        flags.append("missing_total_row")
        return None, None, flags

    def _num(col):
        if col is None or col >= len(total_row):
            return None
        val = total_row[col]
        try:
            return float(val)
        except (TypeError, ValueError):
            return None

    room_nights = _num(room_col)
    pax = _num(pax_col)
    if room_nights is None:
        flags.append("missing_room_nights_total")
    if pax is None:
        flags.append("missing_pax_total")
    return room_nights, pax, flags


def build_record(
    cells: list[tuple[int, int, object]],
    occupancy_rows: list[list],
    source_file: str,
    fallback_year: int | None = None,
) -> FormEstadisticaRecord:
    meta = extract_month_metadata(cells)
    room_nights, pax, flags = extract_occupancy_totals(occupancy_rows)

    year = meta["year"] or fallback_year
    if meta["month"] is None:
        flags.append("missing_month_label")
    if meta["year"] is None:
        flags.append("missing_year_label")
        if fallback_year is not None:
            flags.append("year_from_path_fallback")
    if meta["room_count"] is None:
        flags.append("missing_room_count_label")
    elif meta["room_count"] != 36:
        flags.append(f"room_count_not_36:{meta['room_count']}")
    if year is not None and meta["month"] is not None:
        days_in_month = calendar.monthrange(year, meta["month"])[1]
        missing = missing_form_days(occupancy_rows, days_in_month)
        if missing:
            flags.append(f"partial_form:{days_in_month - len(missing)}/{days_in_month}")

    return FormEstadisticaRecord(
        year=year,
        month=meta["month"],
        room_nights_reported=room_nights,
        pax_reported=pax,
        room_count_reported=meta["room_count"],
        source_file=source_file,
        quality_flags=_cell_flags_join(flags),
    )


def dedupe_form_rows(form_rows: list[dict]) -> tuple[list[dict], list[dict]]:
    """Colapsa `form_rows` a UNA fila por (year, month) -- ÚNICA implementación
    de esta regla en el ETL (reusada tal cual por `etl.validate`, que la
    re-exporta en vez de mantener una copia propia).

    Si dos o más archivos canónicos reportan el mismo mes con el MISMO
    `room_nights_reported`, se queda con el primero sin marcar nada. Si
    reportan valores DISTINTOS, se queda con el primero pero le agrega
    `conflicting_reports` a `quality_flags` (nunca promedia, nunca descarta
    en silencio) y además devuelve una fila de conflicto listando TODOS los
    `source_file` y valores vistos para ese mes.
    """
    groups: dict[tuple[int, int], list[dict]] = defaultdict(list)
    passthrough: list[dict] = []
    for row in form_rows:
        try:
            key = (int(row["year"]), int(row["month"]))
        except (TypeError, ValueError, KeyError):
            passthrough.append(row)
            continue
        groups[key].append(row)

    deduped: list[dict] = list(passthrough)
    conflicts: list[dict] = []
    for (year, month), rows in groups.items():
        if len(rows) == 1:
            deduped.append(rows[0])
            continue
        values = {r.get("room_nights_reported") for r in rows}
        first = dict(rows[0])
        if len(values) > 1:
            existing_flags = first.get("quality_flags") or ""
            first["quality_flags"] = ";".join(
                f for f in (existing_flags, "conflicting_reports") if f
            )
            conflicts.append({
                "year": year,
                "month": month,
                "source_files": ";".join(r.get("source_file", "") for r in rows),
                "room_nights_values": ";".join(str(r.get("room_nights_reported")) for r in rows),
            })
        deduped.append(first)
    return deduped, conflicts


def _is_form_estadisticas_path(path: str) -> bool:
    return "form estadisticas" in _strip_accents_lower(path)


def _load_canonical_inventory(inventory_path: Path = INVENTORY_PATH) -> list[dict]:
    with open(inventory_path, encoding="utf-8") as fh:
        records = json.load(fh)
    return [
        r for r in records
        if r.get("is_canonical") and _is_form_estadisticas_path(r["path"])
    ]


def _parse_workbook(hotel_root: Path, rel_path: str) -> FormEstadisticaRecord:
    import xlrd

    abs_path = hotel_root / rel_path
    wb = xlrd.open_workbook(str(abs_path))
    meta_sheet = wb.sheet_by_index(0)
    cells = [
        (r, c, meta_sheet.cell_value(r, c))
        for r in range(meta_sheet.nrows)
        for c in range(meta_sheet.ncols)
    ]

    occupancy_rows: list[list] = []
    for name in wb.sheet_names():
        if "ocup" in _strip_accents_lower(name):
            sheet = wb.sheet_by_name(name)
            occupancy_rows = [
                [sheet.cell_value(r, c) for c in range(sheet.ncols)]
                for r in range(sheet.nrows)
            ]
            break

    year_from_path = None
    for part in Path(rel_path).parts:
        if part.isdigit() and len(part) == 4:
            year_from_path = int(part)
            break

    return build_record(cells, occupancy_rows, source_file=rel_path, fallback_year=year_from_path)


def parse_all(hotel_root: Path, inventory_path: Path = INVENTORY_PATH) -> tuple[list[FormEstadisticaRecord], list[dict]]:
    """Parsea todos los FORM ESTADISTICAS canónicos. Devuelve (records, conflicts)."""
    canonical = _load_canonical_inventory(inventory_path)
    records: list[FormEstadisticaRecord] = []
    for entry in canonical:
        try:
            records.append(_parse_workbook(hotel_root, entry["path"]))
        except Exception as exc:  # noqa: BLE001 - se reporta, no se aborta el batch
            records.append(FormEstadisticaRecord(
                year=None, month=None, room_nights_reported=None, pax_reported=None,
                room_count_reported=None, source_file=entry["path"],
                quality_flags=f"parse_error:{exc.__class__.__name__}",
            ))

    # Detección de meses en conflicto: ÚNICA lógica de agrupación por
    # (year, month), reusada de `dedupe_form_rows` (la fila deduplicada se
    # descarta acá a propósito -- `stg_form_estadisticas.csv` sigue
    # escribiendo una fila POR ARCHIVO, ver `write_csv`; solo se reusa la
    # detección de conflictos, nunca se duplica esa lógica).
    dict_rows = [asdict(rec) for rec in records if rec.year is not None and rec.month is not None]
    _deduped, conflicts = dedupe_form_rows(dict_rows)

    return records, conflicts


def write_csv(records: list[FormEstadisticaRecord], conflicts: list[dict], output_path: Path = OUTPUT_PATH, conflicts_path: Path = CONFLICTS_PATH) -> None:
    output_path = Path(output_path)
    if not str(output_path.resolve()).startswith(str(OUT_DIR.resolve())):
        raise ValueError("form_estadisticas solo puede escribir dentro de etl/output/")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    cols = [f.name for f in fields(FormEstadisticaRecord)]
    with open(output_path, "w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=cols)
        writer.writeheader()
        for rec in records:
            writer.writerow(asdict(rec))

    if conflicts:
        with open(conflicts_path, "w", newline="", encoding="utf-8") as fh:
            writer = csv.DictWriter(fh, fieldnames=["year", "month", "source_files", "room_nights_values"])
            writer.writeheader()
            writer.writerows(conflicts)


def main() -> None:
    hotel_root = ETL_DIR.parent / "Hotel"
    records, conflicts = parse_all(hotel_root)
    write_csv(records, conflicts)
    print(f"FORM ESTADISTICAS: {len(records)} archivos parseados, {len(conflicts)} meses en conflicto.")
    print(f"-> {OUTPUT_PATH}")
    if conflicts:
        print(f"-> {CONFLICTS_PATH}")


if __name__ == "__main__":
    main()
