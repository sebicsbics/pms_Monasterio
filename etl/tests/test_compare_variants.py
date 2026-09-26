"""Tests de etl/extractor/compare_variants.py.

Fixtures 100% sintéticas (celdas inventadas). Nunca lee datos reales de
Hotel/ ni imprime nombres de huésped.
"""
from __future__ import annotations

import csv
import json
from pathlib import Path

from etl.extractor.compare_variants import (
    load_needs_review_groups,
    spreadsheet_metrics_from_sheets,
    build_group_comparison,
    write_comparison_csv,
)


def _inventory_row(path, family, variant_group, reason="needs_manual_review"):
    return {
        "path": path, "md5": "x" * 32, "size": 100, "family": family,
        "year": 2015, "is_canonical": False, "reason": reason,
        "variant_group": variant_group,
    }


def test_load_needs_review_groups_filters_and_groups_by_variant_group(tmp_path):
    inv = tmp_path / "inventory.json"
    inv.write_text(json.dumps([
        _inventory_row("2015/huespedes/a.xls", "huespedes", "g1"),
        _inventory_row("2015/huespedes/b.xls", "huespedes", "g1"),
        _inventory_row("2015/caja/c.xls", "caja", None, reason=None),
    ]), encoding="utf-8")

    groups = load_needs_review_groups(inv)

    assert list(groups) == ["g1"]
    assert len(groups["g1"]) == 2
    assert groups["g1"][0]["path"] == "2015/huespedes/a.xls"


def test_load_needs_review_groups_missing_file_returns_empty(tmp_path):
    assert load_needs_review_groups(tmp_path / "no_existe.json") == {}


def test_spreadsheet_metrics_from_sheets_reports_sheet_count_and_range():
    sheets = [
        ("1 de abril", [["Nombre", "Hab."], ["Ana", 1], ["", None]]),
        ("2 de abril", [["Nombre", "Hab."], ["Bruno", 2]]),
    ]
    metrics, nights = spreadsheet_metrics_from_sheets(sheets)

    assert metrics["sheet_count"] == 2
    assert metrics["first_sheet"] == "1 de abril"
    assert metrics["last_sheet"] == "2 de abril"
    # sin año/mes hint, sequential_sheet_dates ancla al candidato mas antiguo
    # de la ventana plausible (2012-01-01..2017-12-31); no es el año real,
    # es el mismo comportamiento reusado sin modificar de guest_nights.
    assert metrics["date_range_start"] == "2012-04-01"
    assert metrics["date_range_end"] == "2012-04-02"
    assert metrics["guest_row_count"] == 2
    assert nights == {("2012-04-01", 1), ("2012-04-02", 2)}


def test_spreadsheet_metrics_from_sheets_no_header_returns_zero_guest_rows():
    sheets = [("hoja1", [["frigobar", "monto"], ["coca cola", 10]])]
    metrics, nights = spreadsheet_metrics_from_sheets(sheets)

    assert metrics["sheet_count"] == 1
    assert metrics["guest_row_count"] == 0
    assert nights == set()


def test_spreadsheet_metrics_from_sheets_empty_sheets_returns_empty():
    assert spreadsheet_metrics_from_sheets([]) == ({}, set())


def test_build_group_comparison_flags_superset_against_baseline(monkeypatch):
    baseline_sheets = [("1 de abril", [["Nombre"], ["Ana"]])]
    other_sheets = [
        ("1 de abril", [["Nombre"], ["Ana"]]),
        ("2 de abril", [["Nombre"], ["Bruno"]]),
    ]

    def fake_read_sheets(path):
        return other_sheets if "b.xls" in str(path) else baseline_sheets

    import etl.extractor.compare_variants as cv
    monkeypatch.setattr(cv, "_read_sheets", fake_read_sheets)

    rows = [
        _inventory_row("2015/huespedes/a.xls", "huespedes", "g1"),
        _inventory_row("2015/huespedes/b.xls", "huespedes", "g1"),
    ]
    comparisons = build_group_comparison("g1", rows, Path("/fake/Hotel"))

    assert comparisons[0].is_baseline is True
    assert comparisons[1].is_baseline is False
    assert comparisons[1].superset_of_baseline is True
    assert comparisons[1].guest_row_count == 2


def test_write_comparison_csv_writes_rows(tmp_path):
    from etl.extractor.compare_variants import FileComparison

    rows = [FileComparison(
        variant_group="g1", family="huespedes", path="2015/a.xls", size_bytes=10,
        mtime_iso=None, sheet_count=1, first_sheet="s1", last_sheet="s1",
        date_range_start=None, date_range_end=None, guest_row_count=0,
        is_baseline=True, superset_of_baseline=None, subset_of_baseline=None,
    )]
    out = tmp_path / "variant_comparison.csv"
    write_comparison_csv(rows, out)

    with open(out, encoding="utf-8") as fh:
        read_rows = list(csv.DictReader(fh))
    assert read_rows[0]["variant_group"] == "g1"
    assert read_rows[0]["path"] == "2015/a.xls"
