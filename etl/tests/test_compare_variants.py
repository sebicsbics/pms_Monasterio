"""Tests de etl/extractor/compare_variants.py.

Fixtures 100% sintéticas (celdas inventadas). Nunca lee datos reales de
Hotel/ ni imprime nombres de huésped.
"""
from __future__ import annotations

import csv
import json
from datetime import date
from pathlib import Path

from etl.parsers.guest_nights import NightObservation

from etl.extractor.compare_variants import (
    FileComparison,
    build_group_comparison,
    classify_relation,
    compare_nights,
    load_needs_review_groups,
    nights_map_from_observations,
    spreadsheet_metrics_from_observations,
    write_comparison_csv,
)


def _inventory_row(path, family, variant_group, year=2014, reason="needs_manual_review"):
    return {
        "path": path, "md5": "x" * 32, "size": 100, "family": family,
        "year": year, "is_canonical": False, "reason": reason,
        "variant_group": variant_group,
    }


def _obs(day, room, guest="ANON", month=9, year=2014):
    return NightObservation(
        night_date=date(year, month, day), room=room, guest_name=guest, pax=1,
        rate=None, payment=None, company=None, country=None,
        source_file="x", sheet_name="s", sheet_index=0, quality_flags=[],
    )


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


def test_spreadsheet_metrics_from_observations_reports_sheet_and_range():
    sheet_names = ["1 de sept", "2 de sept"]
    dated = [date(2014, 9, 1), date(2014, 9, 2)]
    observations = [_obs(1, 1, month=9, year=2014), _obs(2, 2, month=9, year=2014)]

    metrics = spreadsheet_metrics_from_observations(sheet_names, dated, observations)

    assert metrics["sheet_count"] == 2
    assert metrics["first_sheet"] == "1 de sept"
    assert metrics["last_sheet"] == "2 de sept"
    assert metrics["date_range_start"] == "2014-09-01"
    assert metrics["date_range_end"] == "2014-09-02"
    assert metrics["guest_row_count"] == 2


def test_spreadsheet_metrics_from_observations_empty_sheets():
    assert spreadsheet_metrics_from_observations([], [], []) == {}


def test_nights_map_from_observations_keys_by_date_room():
    observations = [_obs(1, 5, guest="A"), _obs(2, 6, guest="B")]
    m = nights_map_from_observations(observations)
    assert m == {("2014-09-01", 5): "A", ("2014-09-02", 6): "B"}


def test_classify_relation_identical():
    a = b = {("2014-09-01", 1)}
    assert classify_relation(a, b) == "identical"


def test_classify_relation_a_subset_of_b():
    a = {("2014-09-01", 1)}
    b = {("2014-09-01", 1), ("2014-09-02", 2)}
    assert classify_relation(a, b) == "A_subset_B"


def test_classify_relation_b_subset_of_a():
    a = {("2014-09-01", 1), ("2014-09-02", 2)}
    b = {("2014-09-01", 1)}
    assert classify_relation(a, b) == "B_subset_A"


def test_classify_relation_overlapping_different():
    a = {("2014-09-01", 1), ("2014-09-02", 2)}
    b = {("2014-09-02", 2), ("2014-09-03", 3)}
    assert classify_relation(a, b) == "overlapping_different"


def test_classify_relation_disjoint():
    a = {("2014-09-01", 1)}
    b = {("2014-09-03", 3)}
    assert classify_relation(a, b) == "disjoint"


def test_compare_nights_counts_only_in_each_and_conflicts():
    map_a = {("2014-09-01", 1): "ANA", ("2014-09-02", 2): "BRUNO"}
    map_b = {("2014-09-01", 1): "ANA", ("2014-09-02", 2): "OTRO", ("2014-09-03", 3): "CARLA"}

    result = compare_nights(map_a, map_b)

    assert result["relation"] == "A_subset_B"
    assert result["only_in_a"] == 0
    assert result["only_in_b"] == 1
    assert result["both_agree"] == 1
    assert result["conflicts"] == 1


def test_build_group_comparison_reuses_process_workbook_dating(monkeypatch):
    """El year-hint debe salir del MISMO camino que `process_workbook`
    (nombre de archivo o `inventory_year`), nunca quedar anclado a 2012 por
    default como el bug detectado en la ronda anterior."""
    import etl.extractor.compare_variants as cv

    sheets_by_file = {
        "a.xls": [("1 de sept", [["Nombre", "Hab."], ["Ana", 1]])],
        "b.xls": [
            ("1 de sept", [["Nombre", "Hab."], ["Ana", 1]]),
            ("2 de sept", [["Nombre", "Hab."], ["Bruno", 2]]),
        ],
    }

    def fake_read_sheets(path):
        return sheets_by_file[path.name]

    monkeypatch.setattr(cv, "_read_sheets", fake_read_sheets)

    rows = [
        _inventory_row("2014/huespedes/a.xls", "huespedes", "g1", year=2014),
        _inventory_row("2014/huespedes/b.xls", "huespedes", "g1", year=2014),
    ]
    comparisons = build_group_comparison("g1", rows, Path("/fake/Hotel"))

    baseline, other = comparisons
    assert baseline.date_range_start == "2014-09-01"
    assert other.date_range_start == "2014-09-01"
    assert other.date_range_end == "2014-09-02"
    assert other.nights_relation == "A_subset_B"
    assert other.nights_only_in_b == 1
    assert other.nights_conflicts == 0


def test_write_comparison_csv_writes_rows(tmp_path):
    rows = [FileComparison(
        variant_group="g1", family="huespedes", path="2015/a.xls", size_bytes=10,
        mtime_iso=None, sheet_count=1, first_sheet="s1", last_sheet="s1",
        date_range_start=None, date_range_end=None, guest_row_count=0,
        is_baseline=True, nights_relation=None, nights_only_in_a=None,
        nights_only_in_b=None, nights_both_agree=None, nights_conflicts=None,
    )]
    out = tmp_path / "variant_comparison.csv"
    write_comparison_csv(rows, out)

    with open(out, encoding="utf-8") as fh:
        read_rows = list(csv.DictReader(fh))
    assert read_rows[0]["variant_group"] == "g1"
    assert read_rows[0]["path"] == "2015/a.xls"
