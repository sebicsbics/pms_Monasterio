"""Tests de etl/validate.py: cálculo de % de diferencia y atribución de
noches por mes calendario. Fixtures sintéticas, nunca datos reales.
"""
from __future__ import annotations

from etl.validate import build_validation_rows, compute_diff, nights_by_month, dedupe_form_rows


def test_nights_by_month_single_month_stay():
    rows = [{"check_in": "2016-03-05", "check_out": "2016-03-08"}]
    assert nights_by_month(rows) == {(2016, 3): 3.0}


def test_nights_by_month_stay_crossing_month_end():
    # 30-ene a 3-feb: 4 noches -> 2 en enero (30,31) + 2 en febrero (1,2)
    rows = [{"check_in": "2016-01-30", "check_out": "2016-02-03"}]
    result = nights_by_month(rows)
    assert result == {(2016, 1): 2.0, (2016, 2): 2.0}


def test_nights_by_month_multiple_stays_accumulate():
    rows = [
        {"check_in": "2016-03-01", "check_out": "2016-03-02"},
        {"check_in": "2016-03-10", "check_out": "2016-03-12"},
    ]
    assert nights_by_month(rows) == {(2016, 3): 3.0}


def test_nights_by_month_ignores_invalid_rows():
    rows = [
        {"check_in": "", "check_out": "2016-03-02"},
        {"check_in": "2016-03-05", "check_out": "2016-03-05"},  # check_out == check_in
        {"check_in": "bad", "check_out": "2016-03-02"},
    ]
    assert nights_by_month(rows) == {}


def test_compute_diff_within_tolerance():
    # reportado 20%, reconstruido 20.5% -> diff relativo 2.5%, dentro de ±5%
    diff_pp, diff_pct, within = compute_diff(20.0, 20.5)
    assert round(diff_pp, 2) == 0.5
    assert round(diff_pct, 2) == 2.5
    assert within is True


def test_compute_diff_outside_tolerance():
    # reportado 8%, reconstruido 10% -> diff relativo 25%, fuera de ±5%
    diff_pp, diff_pct, within = compute_diff(8.0, 10.0)
    assert round(diff_pp, 2) == 2.0
    assert round(diff_pct, 2) == 25.0
    assert within is False


def test_compute_diff_zero_reported_nonzero_reconstructed_is_infinite_and_outside():
    diff_pp, diff_pct, within = compute_diff(0.0, 5.0)
    assert diff_pct == float("inf")
    assert within is False


def test_compute_diff_both_zero_is_within_tolerance():
    diff_pp, diff_pct, within = compute_diff(0.0, 0.0)
    assert diff_pct == 0.0
    assert within is True


def test_build_validation_rows_reports_month_without_blocking_others():
    form_rows = [
        {"year": "2016", "month": "3", "room_nights_reported": "301", "room_count_reported": "36", "quality_flags": ""},
        {"year": "2016", "month": "4", "room_nights_reported": "50", "room_count_reported": "36", "quality_flags": ""},
    ]
    # room-night individual (1 noche por fila): 301 en marzo (coincide con lo
    # reportado, dentro de tolerancia), 40 en abril (bien por debajo de lo
    # reportado, fuera de tolerancia) -- pero ambos meses aparecen igual.
    archive_stays = [{"check_in": "2016-03-01", "check_out": "2016-03-02"} for _ in range(301)]
    archive_stays += [{"check_in": "2016-04-01", "check_out": "2016-04-02"} for _ in range(40)]

    rows = build_validation_rows(form_rows, archive_stays, [])
    assert len(rows) == 2
    march = next(r for r in rows if r.month == 3)
    april = next(r for r in rows if r.month == 4)
    assert march.within_tolerance is True
    assert april.within_tolerance is False
    # El mes fuera de tolerancia no bloquea que el otro se reporte:
    assert march.reported == march.reconstructed


def test_dedupe_form_rows_identical_duplicates_collapse_to_one():
    # Dos archivos canónicos distintos reportando el mismo mes con los
    # MISMOS valores (ej. 2016-04 real: dos carpetas con el mismo form) no
    # deben duplicar la fila de validación.
    form_rows = [
        {"year": "2016", "month": "4", "room_nights_reported": "278", "room_count_reported": "36", "quality_flags": "", "source_file": "a.xls"},
        {"year": "2016", "month": "4", "room_nights_reported": "278", "room_count_reported": "36", "quality_flags": "", "source_file": "b.xls"},
    ]
    deduped, conflicts = dedupe_form_rows(form_rows)
    assert len(deduped) == 1
    assert deduped[0]["room_nights_reported"] == "278"
    assert conflicts == []


def test_dedupe_form_rows_conflicting_values_keeps_one_row_flagged_and_reports_both():
    form_rows = [
        {"year": "2015", "month": "6", "room_nights_reported": "60", "room_count_reported": "36", "quality_flags": "", "source_file": "a.xls"},
        {"year": "2015", "month": "6", "room_nights_reported": "90", "room_count_reported": "36", "quality_flags": "", "source_file": "b.xls"},
    ]
    deduped, conflicts = dedupe_form_rows(form_rows)
    assert len(deduped) == 1
    assert "conflicting_reports" in deduped[0]["quality_flags"]
    assert len(conflicts) == 1
    assert conflicts[0]["year"] == 2015 and conflicts[0]["month"] == 6
    assert conflicts[0]["source_files"] == "a.xls;b.xls"
    assert conflicts[0]["room_nights_values"] == "60;90"


def test_build_validation_rows_collapses_duplicate_month_into_single_row():
    # Bug real detectado en validation_report.csv: 2016-04 aparecía dos
    # veces con valores idénticos.
    form_rows = [
        {"year": "2016", "month": "4", "room_nights_reported": "278", "room_count_reported": "36", "quality_flags": "", "source_file": "a.xls"},
        {"year": "2016", "month": "4", "room_nights_reported": "278", "room_count_reported": "36", "quality_flags": "", "source_file": "b.xls"},
    ]
    rows = build_validation_rows(form_rows, [], [])
    assert len(rows) == 1


def test_build_validation_rows_conflicting_month_reports_both_values_in_notes():
    form_rows = [
        {"year": "2015", "month": "6", "room_nights_reported": "60", "room_count_reported": "36", "quality_flags": "", "source_file": "a.xls"},
        {"year": "2015", "month": "6", "room_nights_reported": "90", "room_count_reported": "36", "quality_flags": "", "source_file": "b.xls"},
    ]
    rows = build_validation_rows(form_rows, [], [])
    assert len(rows) == 1
    assert "conflicting_reports" in rows[0].notes
