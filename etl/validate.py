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
`dedupe_form_rows` (implementada en `etl.parsers.form_estadisticas`, ÚNICA
copia de esta lógica -- este módulo solo la re-exporta) colapsa por
(year, month) ANTES de construir las filas: valores idénticos -> una sola
fila; valores distintos -> una sola fila con `conflicting_reports` en
`quality_flags` y AMBOS valores listados en el reporte de conflictos (nunca
se promedian ni se descarta uno en silencio). Bug real que la motivó: dos
archivos canónicos del mismo mes duplicaban la fila de validación
(`validation_report.csv`, 2016-04).

## Doble conteo archive/md (bug real, corregido)
`stg_estadias_archive.csv` (crudo) y `stg_estadias.csv` (md) pueden reportar
la MISMA estadía (mismo huésped/room/rango de fechas real, capturado en dos
fuentes distintas del hotel). `etl.gen_historical_stays.local_dedupe` ya
excluye esos solapes (md gana) al generar la carga -- pero antes esa
dedupe se aplicaba SOLO en memoria y `validate.py` seguía leyendo el csv
archive crudo, contando esas noches DOS VECES (59 estadías / 123 noches en
2016-11 y 2016-12, inflando 2016-12 de ~14.7% real a 25.72% reportado en
`validation_report.csv`). Corregido: el dedupe se persiste en
`etl/output/stg_estadias_archive_deduped.csv` (ver "Orden del pipeline" en
`etl/README.md`) y este módulo lee EXCLUSIVAMENTE ese archivo -- nunca el
crudo, nunca vuelve a aplicar el dedupe por su cuenta. Si el archivo
deduplicado no existe, `main()` rechaza correr con un error explícito (no
corre con datos parcialmente deduplicados en silencio).
"""
from __future__ import annotations

import calendar
import csv
from collections import defaultdict
from dataclasses import dataclass
from datetime import date, timedelta
from pathlib import Path

from etl.parsers.form_estadisticas import dedupe_form_rows

ETL_DIR = Path(__file__).resolve().parent
OUT_DIR = ETL_DIR / "output"
FORM_ESTADISTICAS_CSV = OUT_DIR / "stg_form_estadisticas.csv"
# ÚNICA fuente de verdad de estadías archive: el dedupe local contra md
# (`etl.gen_historical_stays.local_dedupe`) ya se aplicó y persistió acá.
# NUNCA leer `stg_estadias_archive.csv` (crudo) acá -- eso duplicaba noches
# que solapan con md (bug real: 59 estadías / 123 noches en 2016-11/12).
ESTADIAS_ARCHIVE_CSV = OUT_DIR / "stg_estadias_archive_deduped.csv"
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

        if room_count <= 0:
            # Guard: un room_count_reported inválido (ej. "0", typo del
            # formulario) no debe tumbar la corrida ni bloquear otros meses
            # -- se reporta el mes como no calculable y se sigue.
            notes.append("invalid_room_count")
            rows.append(ValidationRow(
                year=year, month=month, reported=0.0, reconstructed=0.0,
                diff_pp=0.0, diff_pct=0.0, within_tolerance=False,
                notes="; ".join(notes),
            ))
            continue

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
        # Formulario cargado solo en parte (ej. 2016-03: días 1-7): su total no
        # es comparable con el mes completo, así que va como nota propia.
        partial = [f for f in flags.split(";") if f.startswith("partial_form:")]
        if partial:
            notes.extend(partial)
            flags = ";".join(f for f in flags.split(";") if not f.startswith("partial_form:"))
        if flags:
            notes.append(f"quality_flags={flags}")

        diff_pp, diff_pct, within = compute_diff(reported_pct, reconstructed_pct)

        # Hallazgo confirmado por el usuario (#471): de 2015 en adelante el
        # formulario oficial subreporta sistemáticamente frente a los
        # registros de recepción. Un mes de esos años fuera de tolerancia
        # queda documentado como tal, no tratado como un bug del ETL. Un
        # formulario parcial no es subreporte: ahí la diferencia es de cobertura.
        if year >= 2015 and not within and not no_reconstruction and not partial:
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
    if not ESTADIAS_ARCHIVE_CSV.exists():
        raise SystemExit(
            f"No existe {ESTADIAS_ARCHIVE_CSV}. Corré primero "
            "`python -m etl.gen_historical_stays --source hotel_archive` "
            "(persiste el dedupe archive/md que este validador necesita como "
            "única fuente de verdad; ver 'Orden del pipeline' en etl/README.md)."
        )
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
