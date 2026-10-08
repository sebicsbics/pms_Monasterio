"""Tests de etl/gen_hist_cash.py: una fuente por mes (decisión humana),
nunca dedupe por fila. Fixtures sintéticas, nunca datos reales."""
from __future__ import annotations

import csv
from datetime import date

import pytest

import etl.gen_hist_cash as gc
from etl.parsers.caja import CashMovement


def _mv(d: date, amount: float, source_file: str, kind: str = "income") -> CashMovement:
    return CashMovement(
        movement_date=d, kind=kind, currency="BOB", amount=float(amount), concept="HAB 5",
        receipt_ref=None, receptionist="R", observations=None,
        source_file=source_file, sheet_name="Hoja1", source_row=3, quality_flags="",
    )


def _decision(month: str, path: str, flag: str = "") -> dict:
    return {"month": month, "chosen_path": path, "decided_by": "Sebas",
            "decided_on": "2026-10-07", "note": "", "flag": flag}


# ------------------------------------------------------------ propuesta

def test_propose_picks_candidate_with_most_movements_and_reports_absent_ones():
    movements = [
        _mv(date(2015, 5, 1), 100, "acumulado.xls"),
        _mv(date(2015, 5, 2), 50, "acumulado.xls"),
        _mv(date(2015, 5, 1), 100, "abril.xlsx"),
        _mv(date(2015, 5, 3), 999, "abril.xlsx"),  # no está en el acumulado
    ]
    rows = gc.propose_month_sources(movements)
    by_path = {r["candidate_path"]: r for r in rows}
    assert by_path["acumulado.xls"]["proposed"] is True
    assert by_path["abril.xlsx"]["proposed"] is False
    assert by_path["abril.xlsx"]["absent_from_proposed"] == 1
    assert by_path["acumulado.xls"]["absent_from_proposed"] == 0


def test_propose_counts_identical_movements_as_a_multiset():
    # Dos cobros legítimos de 200 el mismo día no se fusionan.
    movements = [
        _mv(date(2014, 7, 1), 200, "a.xlsx"), _mv(date(2014, 7, 1), 200, "a.xlsx"),
        _mv(date(2014, 7, 1), 200, "b.xlsx"),
    ]
    by_path = {r["candidate_path"]: r for r in gc.propose_month_sources(movements)}
    assert by_path["a.xlsx"]["movements"] == 2
    assert by_path["b.xlsx"]["absent_from_proposed"] == 0


# ------------------------------------------------------------ selección

def test_select_keeps_only_the_chosen_file_for_each_month():
    movements = [
        _mv(date(2014, 9, 30), 10, "septiembre.xlsx"),
        _mv(date(2014, 9, 30), 10, "octubre.xls"),  # borde de mes en otro archivo
        _mv(date(2014, 10, 1), 20, "octubre.xls"),
    ]
    decisions = [_decision("2014-09", "septiembre.xlsx"), _decision("2014-10", "octubre.xls")]
    selected = gc.select_movements(movements, decisions)
    assert [(m.movement_date, m.source_file) for m in selected] == [
        (date(2014, 9, 30), "septiembre.xlsx"), (date(2014, 10, 1), "octubre.xls"),
    ]


def test_select_appends_the_decision_flag_to_that_month():
    movements = [_mv(date(2016, 12, 5), 10, "informe.xlsx")]
    [m] = gc.select_movements(movements, [_decision("2016-12", "informe.xlsx", "source_curated_report")])
    assert "source_curated_report" in m.quality_flags.split(";")


def test_select_month_without_decision_is_an_explicit_error():
    movements = [_mv(date(2014, 9, 30), 10, "septiembre.xlsx")]
    with pytest.raises(gc.CashMonthSourceError, match="2014-09"):
        gc.select_movements(movements, [])


def test_select_decision_pointing_to_file_without_movements_that_month_is_an_error():
    movements = [_mv(date(2014, 9, 30), 10, "septiembre.xlsx")]
    with pytest.raises(gc.CashMonthSourceError, match="otro.xlsx"):
        gc.select_movements(movements, [_decision("2014-09", "otro.xlsx")])


# ------------------------------------------------------------ orquestación

def test_run_load_writes_staging_and_sql_into_injected_out_dir(tmp_path, monkeypatch):
    out_dir = tmp_path / "output"
    decisions_path = tmp_path / "cash_month_sources.csv"
    with open(decisions_path, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(_decision("x", "y")))
        w.writeheader()
        w.writerow(_decision("2014-07", "caja.xlsx"))

    movements = [_mv(date(2014, 7, 1), 200, "caja.xlsx"),
                 _mv(date(2014, 7, 1), 15, "caja.xlsx", kind="expense")]
    monkeypatch.setattr(gc, "parse_cash_files", lambda hotel_root, inventory_path: (
        movements, [], {"caja.xlsx": "abc123"}))

    gc.run("load", out_dir=str(out_dir), decisions_path=str(decisions_path))

    staged = list(csv.DictReader(open(out_dir / "stg_hist_cash_movements.csv", encoding="utf-8")))
    assert [(r["kind"], r["amount"], r["source_hash"]) for r in staged] == [
        ("income", "200.0", "abc123"), ("expense", "15.0", "abc123")]
    sql = (out_dir / "load_hist_cash_movements.sql").read_text(encoding="utf-8")
    assert "delete from public.hist_cash_movements where source = 'hotel_archive'" in sql
    assert "truncate" not in sql.lower()


def test_select_decision_for_month_without_movements_is_an_error():
    # Una decisión vieja (el mes dejó de existir tras corregir fechas) no se
    # ignora en silencio.
    movements = [_mv(date(2014, 9, 30), 10, "septiembre.xlsx")]
    decisions = [_decision("2014-09", "septiembre.xlsx"), _decision("2013-03", "viejo.xlsx")]
    with pytest.raises(gc.CashMonthSourceError, match="2013-03"):
        gc.select_movements(movements, decisions)
