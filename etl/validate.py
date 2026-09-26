"""CLI: `python -m etl.validate`.

Compara la ocupación mensual RECONSTRUIDA (a partir de
`etl/output/stg_estadias_archive.csv`, y `etl/output/stg_estadias.csv` si
cubre el mismo mes) contra la ocupación REPORTADA en FORM ESTADISTICAS
(`etl/output/stg_form_estadisticas.csv`), usando la MISMA definición que usa
el hotel en su propio formulario: room-nights vendidos / (capacidad fija
declarada * días del mes). Ver evidencia de esa definición en el reporte de
apply de la Slice 3b -- el formulario Nº 6 no excluye habitaciones
bloqueadas de su capacidad ("Total Nº de Hb.__36" es fijo), así que la
reconstrucción tampoco usa `stg_room_blocks.csv`: solo cuenta noches de
estadías reales, igual que el hotel solo cuenta habitaciones con huésped.

Este script SOLO reporta -- nunca falla la suite, nunca bloquea la carga de
otros meses. Ver Requirement "Validación de ocupación mensual" (#451).

## Definición del Formulario Nº 6 (evidencia real, Slice 3b)
El formulario oficial (Viceministerio de Turismo, "FORM ESTADISTICAS") NO
calcula ningún %. Reporta, día a día, en la hoja "Ocup. Hotelera":
"Habitaciones ocupadas por noche" y "Numero de Personas que la Ocuparon",
con una fila "Total" mensual. La capacidad ("Total Nº de Hb.__36") es fija
y NO excluye habitaciones bloqueadas -- por eso la reconstrucción tampoco
usa `stg_room_blocks.csv`. `reported_pct = room_nights_reported /
(room_count_reported * días_del_mes) * 100`.

## Hallazgo (confirmado por el usuario, decisión #471, 2026-09-26)
2014 (agosto, octubre, noviembre) coincide dentro de 1% con la
reconstrucción -- valida el método. De 2015 en adelante el formulario
oficial SUBREPORTA sistemáticamente frente a los registros de recepción (20
de 22 meses, hasta 2-4x por debajo), confirmado por el usuario como un
problema de la fuente oficial, no del ETL. Los meses fuera de ±5% en
2015-2017 quedan documentados como tales (`notes`), NO se fuerza la
tolerancia ni se trata como bug. Meses sin ninguna noche reconstruida (ej.
2014-09: variante de registro de huéspedes pendiente de revisión manual;
2014-12: no hay registro de recepción en el archivo para ese mes) se
marcan con `notes="no_reconstruction"` en vez de mostrar 0% reconstruido
como si fuera un dato real.

## Duplicados y conflictos entre archivos FORM ESTADISTICAS del mismo mes
`etl.parsers.form_estadisticas` ya reporta conflictos de contenido en
`form_estadisticas_conflicts.csv`, pero sigue emitiendo una fila en
`stg_form_estadisticas.csv` POR ARCHIVO -- dos archivos canónicos del mismo
mes (con o sin el mismo contenido) generaban dos filas de validación
duplicadas para ese mes (bug real detectado en `validation_report.csv`,
2016-04). `dedupe_form_rows` colapsa por (year, month) ANTES de construir
las filas: valores idénticos -> una sola fila; valores distintos -> una
sola fila con `conflicting_reports` en `quality_flags` y AMBOS valores
listados en el reporte de conflictos (nunca se promedian ni se descarta
uno en silencio).
"""
from __future__ import annotations

import calendar
import csv
from collections import defaultdict
from dataclasses import dataclass
from datetime import date, timedelta
from pathlib import Path

ETL_DIR = Path(__file__).resolve().parent
OUT_DIR = ETL_DIR / "output"
FORM_ESTADISTICAS_CSV = OUT_DIR / "stg_form_estadisticas.csv"
ESTADIAS_ARCHIVE_CSV = OUT_DIR / "stg_estadias_archive.csv"
ESTADIAS_MD_CSV = OUT_DIR / "stg_estadias.csv"
VALIDATION_REPORT_CSV = OUT_DIR / "validation_report.csv"
VALIDATION_CONFLICTS_CSV = OUT_DIR / "validation_conflicts.csv"

TOLERANCE_PCT = 5.0  # diferencia RELATIVA (spec #451: "diferencia relativa ≤5%")
ROOM_COUNT_DEFAULT = 36


def _parse_date(value: str) -> date | None:
    if not value:
        return None
    try:
        y, m, d = value.split("-")
        return date(int(y), int(m), int(d))
    except (ValueError, AttributeError):
        return None


def nights_by_month(stay_rows: list[dict]) -> dict[tuple[int, int], float]:
    """Atribuye cada NOCHE de cada estadía a su propio (año, mes) calendario.

    Una estadía que cruza fin de mes (ej. check_in 30-ene, check_out 3-feb)
    aporta noches a AMBOS meses -- nunca se le atribuye entera al mes del
    check_in (mismo bug de atribución por año que #469, a nivel mes).
    """
    totals: dict[tuple[int, int], float] = defaultdict(float)
    for row in stay_rows:
        check_in = _parse_date(row.get("check_in", ""))
        check_out = _parse_date(row.get("check_out", ""))
        if check_in is None or check_out is None or check_out <= check_in:
            continue
        current = check_in
        while current < check_out:
            totals[(current.year, current.month)] += 1
            current += timedelta(days=1)
    return dict(totals)


def compute_diff(reported_pct: float, reconstructed_pct: float) -> tuple[float, float, bool]:
    """(diff_pp, diff_pct_relativo, within_tolerance).

    diff_pp: diferencia en puntos porcentuales (reconstruido - reportado),
    informativa. within_tolerance se decide por diferencia RELATIVA (spec
    #451: "la diferencia relativa es ≤5%"), no por puntos porcentuales,
    porque un desvío de 2pp sobre un 8% reportado es enorme (25%) mientras
    que 2pp sobre un 90% reportado es marginal (2.2%).
    """
    diff_pp = reconstructed_pct - reported_pct
    if reported_pct == 0:
        diff_pct = float("inf") if reconstructed_pct != 0 else 0.0
    else:
        diff_pct = abs(diff_pp) / abs(reported_pct) * 100
    within_tolerance = diff_pct <= TOLERANCE_PCT
    return diff_pp, diff_pct, within_tolerance


def dedupe_form_rows(form_rows: list[dict]) -> tuple[list[dict], list[dict]]:
    """Colapsa `form_rows` a UNA fila por (year, month).

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


@dataclass
class ValidationRow:
    year: int
    month: int
    reported: float
    reconstructed: float
    diff_pp: float
    diff_pct: float
    within_tolerance: bool
    notes: str


def _read_csv(path: Path) -> list[dict]:
    if not path.exists():
        return []
    with open(path, encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def build_validation_rows(
    form_rows: list[dict],
    archive_stays: list[dict],
    md_stays: list[dict],
) -> list[ValidationRow]:
    form_rows, _conflicts = dedupe_form_rows(form_rows)

    reconstructed = defaultdict(float)
    for month_key, count in nights_by_month(archive_stays).items():
        reconstructed[month_key] += count
    for month_key, count in nights_by_month(md_stays).items():
        reconstructed[month_key] += count

    rows: list[ValidationRow] = []
    for form in form_rows:
        notes = []
        try:
            year = int(form["year"])
            month = int(form["month"])
        except (TypeError, ValueError, KeyError):
            continue
        room_nights_raw = form.get("room_nights_reported")
        if room_nights_raw in (None, "", "None"):
            notes.append("sin room_nights_reported, mes omitido")
            continue
        room_count_raw = form.get("room_count_reported")
        room_count = ROOM_COUNT_DEFAULT
        if room_count_raw not in (None, "", "None"):
            room_count = int(float(room_count_raw))
        else:
            notes.append(f"room_count_reported ausente, se asume {ROOM_COUNT_DEFAULT}")

        days_in_month = calendar.monthrange(year, month)[1]
        reported_room_nights = float(room_nights_raw)
        reported_pct = reported_room_nights / (room_count * days_in_month) * 100

        recon_room_nights = reconstructed.get((year, month), 0.0)
        reconstructed_pct = recon_room_nights / (room_count * days_in_month) * 100

        no_reconstruction = (year, month) not in reconstructed
        if no_reconstruction:
            notes.append("no_reconstruction")

        flags = form.get("quality_flags") or ""
        if "conflicting_reports" in flags:
            notes.append("conflicting_reports")
            flags = ";".join(f for f in flags.split(";") if f != "conflicting_reports")
        if flags:
            notes.append(f"quality_flags={flags}")

        diff_pp, diff_pct, within = compute_diff(reported_pct, reconstructed_pct)

        # Hallazgo confirmado por el usuario (#471): de 2015 en adelante el
        # formulario oficial subreporta sistemáticamente frente a los
        # registros de recepción. Un mes de esos años fuera de tolerancia
        # queda documentado como tal, no tratado como un bug del ETL.
        if year >= 2015 and not within and not no_reconstruction:
            notes.append("official_form_underreports_2015_2017")
        rows.append(ValidationRow(
            year=year, month=month, reported=round(reported_pct, 2),
            reconstructed=round(reconstructed_pct, 2), diff_pp=round(diff_pp, 2),
            diff_pct=round(diff_pct, 2) if diff_pct != float("inf") else diff_pct,
            within_tolerance=within, notes="; ".join(notes),
        ))
    rows.sort(key=lambda r: (r.year, r.month))
    return rows


def write_report(rows: list[ValidationRow], output_path: Path = VALIDATION_REPORT_CSV) -> None:
    output_path = Path(output_path)
    if not str(output_path.resolve()).startswith(str(OUT_DIR.resolve())):
        raise ValueError("validate solo puede escribir dentro de etl/output/")
    with open(output_path, "w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(["year", "month", "reported", "reconstructed", "diff_pp", "diff_pct", "within_tolerance", "notes"])
        for r in rows:
            writer.writerow([r.year, r.month, r.reported, r.reconstructed, r.diff_pp, r.diff_pct, r.within_tolerance, r.notes])


def write_conflicts(conflicts: list[dict], output_path: Path = VALIDATION_CONFLICTS_CSV) -> None:
    output_path = Path(output_path)
    if not str(output_path.resolve()).startswith(str(OUT_DIR.resolve())):
        raise ValueError("validate solo puede escribir dentro de etl/output/")
    if not conflicts:
        return
    with open(output_path, "w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=["year", "month", "source_files", "room_nights_values"])
        writer.writeheader()
        writer.writerows(conflicts)


def main() -> None:
    form_rows = _read_csv(FORM_ESTADISTICAS_CSV)
    archive_stays = _read_csv(ESTADIAS_ARCHIVE_CSV)
    md_stays = _read_csv(ESTADIAS_MD_CSV)
    _deduped, conflicts = dedupe_form_rows(form_rows)
    write_conflicts(conflicts)
    rows = build_validation_rows(form_rows, archive_stays, md_stays)
    write_report(rows)

    within = [r for r in rows if r.within_tolerance]
    worst = sorted(rows, key=lambda r: (r.diff_pct if r.diff_pct != float("inf") else 1e9), reverse=True)[:5]

    print(f"Meses comparados: {len(rows)}")
    print(f"Dentro de tolerancia (±{TOLERANCE_PCT}% relativo): {len(within)}/{len(rows)}")
    print(f"-> {VALIDATION_REPORT_CSV}")
    print("Peores 5 meses (mayor diferencia relativa):")
    for r in worst:
        print(f"  {r.year}-{r.month:02d}: reportado={r.reported}% reconstruido={r.reconstructed}% diff={r.diff_pct}% {'OK' if r.within_tolerance else 'FUERA'}")


if __name__ == "__main__":
    main()
