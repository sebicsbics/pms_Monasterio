"""Tests de etl/gen_historical_stays.py: mapeo de columnas + orquestación
--source md / --source hotel_archive. Fixtures sintéticas (CSVs en tmp_path),
nunca datos reales."""
from __future__ import annotations

import csv

import etl.gen_historical_stays as gh


def _write_csv(path, rows, cols):
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(cols)
        for r in rows:
            w.writerow([r.get(c, "") for c in cols])


MD_COLS = ["guest_name", "room", "pax", "check_in", "check_out", "nights",
           "rate_bs", "total_bs", "total_source", "payment", "channel",
           "country", "is_multi_guest", "quality_flags"]


def test_run_md_writes_source_literal_and_no_truncate(tmp_path, monkeypatch):
    out_dir = tmp_path / "output"
    out_dir.mkdir()
    stg_md = out_dir / "stg_estadias.csv"
    _write_csv(stg_md, [{"guest_name": "JUAN", "room": "5", "pax": "1",
                          "check_in": "2015-01-01", "check_out": "2015-01-03",
                          "nights": "2", "rate_bs": "100", "total_bs": "200",
                          "total_source": "reported", "payment": "EFECTIVO",
                          "channel": "DIRECTO", "country": "BO",
                          "is_multi_guest": "false", "quality_flags": ""}], MD_COLS)

    monkeypatch.setattr(gh, "OUT_DIR", str(out_dir))
    monkeypatch.setattr(gh, "STG_MD", str(stg_md))
    monkeypatch.setattr(gh, "DEDUPE_REPORT", str(out_dir / "dedupe_report.csv"))

    gh.run("md")

    out_path = out_dir / "load_historical_stays_md.sql"
    sql = out_path.read_text(encoding="utf-8")
    assert "truncate" not in sql.lower()
    assert "source = 'md'" in sql
    assert "'JUAN'" in sql
    assert ", 'md')" in sql  # última columna insertada es el literal de fuente


def test_run_hotel_archive_dedupes_against_md(tmp_path, monkeypatch):
    out_dir = tmp_path / "output"
    out_dir.mkdir()
    stg_md = out_dir / "stg_estadias.csv"
    stg_archive = out_dir / "stg_estadias_archive.csv"
    _write_csv(stg_md, [{"guest_name": "JUAN", "room": "5",
                          "check_in": "2016-04-01", "check_out": "2016-04-03",
                          "nights": "2"}], MD_COLS)
    _write_csv(stg_archive, [
        {"guest_name": "JUAN P.", "room": "5",
         "check_in": "2016-04-02", "check_out": "2016-04-04"},  # solapa -> excluida
        {"guest_name": "MARIA", "room": "6",
         "check_in": "2016-04-02", "check_out": "2016-04-04"},  # no solapa -> se carga
    ], MD_COLS)

    monkeypatch.setattr(gh, "OUT_DIR", str(out_dir))
    monkeypatch.setattr(gh, "STG_MD", str(stg_md))
    monkeypatch.setattr(gh, "STG_ARCHIVE", str(stg_archive))
    monkeypatch.setattr(gh, "DEDUPE_REPORT", str(out_dir / "dedupe_report.csv"))

    gh.run("hotel_archive")

    sql = (out_dir / "load_historical_stays_hotel_archive.sql").read_text(encoding="utf-8")
    assert "'MARIA'" in sql
    assert "'JUAN P.'" not in sql
    assert "source = 'hotel_archive'" in sql

    report_rows = list(csv.DictReader(open(out_dir / "dedupe_report.csv", encoding="utf-8")))
    assert len(report_rows) == 1
    assert report_rows[0]["archive_guest_name"] == "JUAN P."
    assert report_rows[0]["md_guest_name"] == "JUAN"
