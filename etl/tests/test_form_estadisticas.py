"""Tests del parser de FORM ESTADISTICAS (etl/parsers/form_estadisticas.py).

Fixtures sintéticas. Nunca lee archivos reales de Hotel/.
"""
from __future__ import annotations

from etl.parsers.form_estadisticas import (
    build_record,
    extract_month_metadata,
    extract_occupancy_totals,
    missing_form_days,
    parse_month_label,
    parse_room_count_label,
    parse_year_label,
)


def test_parse_month_label():
    assert parse_month_label("Mes MARZO") == 3
    assert parse_month_label("Mes OCTUBRE") == 10
    assert parse_month_label("") is None
    assert parse_month_label(None) is None
    assert parse_month_label("Año 2016") is None


def test_parse_year_label():
    assert parse_year_label("Año 2016") == 2016
    assert parse_year_label("Año 2013") == 2013
    assert parse_year_label("Mes MARZO") is None


def test_parse_room_count_label():
    assert parse_room_count_label("Total Nº de Hb.__36") == 36
    assert parse_room_count_label("Total Nº de Plazas_68") is None
    assert parse_room_count_label("Total Numero de Empleados_5") is None


def test_extract_month_metadata_ignores_position():
    # Drift de posición: mismas etiquetas, filas/columnas distintas al
    # layout real -- debe matchear por prefijo de texto, no por celda fija.
    cells = [
        (9, 1, "Mes JULIO"),
        (9, 5, "Año 2015"),
        (12, 20, "Total Nº de Hb.__36"),
        (0, 0, "ruido"),
    ]
    meta = extract_month_metadata(cells)
    assert meta == {"month": 7, "year": 2015, "room_count": 36}


def test_extract_occupancy_totals_finds_total_row():
    rows = [
        ["", "OCUPACION HOTELERA"],
        ["", "Día", "Habitaciones ocupadas por noche", "Numero de Personas que la Ocuparon"],
        ["", 1.0, 3.0, 5.0],
        ["", 2.0, 4.0, 5.0],
        ["", "Total", 7.0, 10.0],
    ]
    room_nights, pax, flags = extract_occupancy_totals(rows)
    assert room_nights == 7.0
    assert pax == 10.0
    assert flags == []


def test_extract_occupancy_totals_missing_header_flags():
    rows = [["", "algo distinto"], ["", "sin datos"]]
    room_nights, pax, flags = extract_occupancy_totals(rows)
    assert room_nights is None
    assert pax is None
    assert "missing_occupancy_header" in flags


def test_extract_occupancy_totals_missing_total_row_flags():
    rows = [
        ["", "Día", "Habitaciones ocupadas por noche", "Numero de Personas que la Ocuparon"],
        ["", 1.0, 3.0, 5.0],
    ]
    room_nights, pax, flags = extract_occupancy_totals(rows)
    assert room_nights is None
    assert "missing_total_row" in flags


def test_build_record_happy_path():
    cells = [(2, 3, "Mes OCTUBRE"), (2, 9, "Año 2016"), (5, 34, "Total Nº de Hb.__36")]
    occ_rows = [
        ["", "Día", "Habitaciones ocupadas por noche", "Numero de Personas que la Ocuparon"],
        ["", 1.0, 3.0, 5.0],
        ["", "Total", 192.0, 248.0],
    ]
    rec = build_record(cells, occ_rows, source_file="f.xls")
    assert rec.year == 2016
    assert rec.month == 10
    assert rec.room_nights_reported == 192.0
    assert rec.pax_reported == 248.0
    assert rec.room_count_reported == 36
    assert rec.quality_flags == ""


def test_build_record_flags_room_count_drift_and_uses_path_fallback():
    cells = [(2, 3, "Mes MARZO")]  # sin "Año", sin "Total Nº de Hb"
    occ_rows = [
        ["", "Día", "Habitaciones ocupadas por noche", "Numero de Personas que la Ocuparon"],
        ["", "Total", 100.0, 150.0],
    ]
    rec = build_record(cells, occ_rows, source_file="2015/f.xls", fallback_year=2015)
    assert rec.year == 2015
    assert "missing_year_label" in rec.quality_flags
    assert "year_from_path_fallback" in rec.quality_flags
    assert "missing_room_count_label" in rec.quality_flags


def test_build_record_flags_room_count_not_36():
    cells = [(2, 3, "Mes MARZO"), (2, 9, "Año 2016"), (5, 34, "Total Nº de Hb.__40")]
    occ_rows = [
        ["", "Día", "Habitaciones ocupadas por noche", "Numero de Personas que la Ocuparon"],
        ["", "Total", 100.0, 150.0],
    ]
    rec = build_record(cells, occ_rows, source_file="f.xls")
    assert rec.room_count_reported == 40
    assert "room_count_not_36:40" in rec.quality_flags


def _occ_rows_by_day(values: dict[int, object]) -> list[list]:
    """Hoja 'Ocup. Hotelera' sintética con la plantilla completa (días 1..31):
    `values` da la celda de habitaciones por día; el resto queda en blanco."""
    rows = [["Día", "Habitaciones ocupadas por noche", "Numero de Personas que la Ocuparon"]]
    for day in range(1, 32):
        v = values.get(day, "")
        rows.append([float(day), v, v])
    total = sum(v for v in values.values() if isinstance(v, float))
    rows.append(["Total", total, total])
    return rows


def test_missing_form_days_blank_is_missing_but_zero_is_reported():
    # Un 0 explícito es un día sin huéspedes (dato real); el blanco es un día
    # que nadie cargó.
    rows = _occ_rows_by_day({1: 0.0, 2: 3.0})
    assert missing_form_days(rows, days_in_month=5) == [3, 4, 5]


def test_missing_form_days_ignores_template_days_beyond_month_end():
    # Febrero 2015: la plantilla trae filas 29-31 en blanco, no son faltantes.
    rows = _occ_rows_by_day({d: 2.0 for d in range(1, 29)})
    assert missing_form_days(rows, days_in_month=28) == []


def test_missing_form_days_without_day_rows_cannot_judge():
    rows = [
        ["", "Día", "Habitaciones ocupadas por noche", "Numero de Personas que la Ocuparon"],
        ["", "Total", 100.0, 150.0],
    ]
    assert missing_form_days(rows, days_in_month=31) == []


def test_build_record_flags_partial_form_filled_only_first_week():
    # Caso real 2016-03: formulario guardado el día 7, días 8-31 en blanco.
    cells = [(2, 3, "Mes MARZO"), (2, 9, "Año 2016"), (5, 34, "Total Nº de Hb.__36")]
    occ_rows = _occ_rows_by_day({d: 4.0 for d in range(1, 8)})
    rec = build_record(cells, occ_rows, source_file="f.xls")
    assert "partial_form:7/31" in rec.quality_flags


def test_build_record_complete_month_with_zero_day_is_not_partial():
    cells = [(2, 3, "Mes FEBRERO"), (2, 9, "Año 2015"), (5, 34, "Total Nº de Hb.__36")]
    occ_rows = _occ_rows_by_day({d: (0.0 if d == 1 else 3.0) for d in range(1, 29)})
    rec = build_record(cells, occ_rows, source_file="f.xls")
    assert "partial_form" not in rec.quality_flags


def test_missing_form_days_numeric_text_counts_as_reported():
    # Un "0" o "3" tipeado como texto sigue siendo un dato cargado.
    rows = _occ_rows_by_day({1: "0", 2: " 3 ", 3: "-"})
    assert missing_form_days(rows, days_in_month=3) == [3]


def test_missing_form_days_duplicate_day_rows_count_once():
    rows = _occ_rows_by_day({1: 2.0})
    rows.insert(3, [2.0, "", ""])  # plantilla con la fila del día 2 repetida
    assert missing_form_days(rows, days_in_month=2) == [2]
