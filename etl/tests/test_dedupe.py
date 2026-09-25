"""Tests del dedupe local CSV<->CSV (etl/gen_historical_stays.py: local_dedupe).

Sin DB: compara filas ya leídas de stg_estadias.csv (md) y
stg_estadias_archive.csv (hotel_archive). Fixtures sintéticas.
"""
from __future__ import annotations

from etl.gen_historical_stays import local_dedupe


def _row(room, check_in, check_out, guest_name="JUAN PEREZ", nights="2",
         quality_flags="", **kw):
    d = {"room": str(room), "check_in": check_in, "check_out": check_out,
         "guest_name": guest_name, "nights": nights, "quality_flags": quality_flags}
    d.update(kw)
    return d


def test_local_dedupe_excludes_overlapping_same_room():
    md = [_row(5, "2016-04-01", "2016-04-03")]
    archive = [_row(5, "2016-04-02", "2016-04-05", guest_name="JUAN P.")]
    kept, report = local_dedupe(archive, md)
    assert kept == []
    assert len(report) == 1
    assert report[0]["room"] == 5
    assert report[0]["md_guest_name"] == "JUAN PEREZ"
    assert report[0]["archive_guest_name"] == "JUAN P."


def test_local_dedupe_keeps_non_overlapping_same_room():
    md = [_row(5, "2016-04-01", "2016-04-03")]
    archive = [_row(5, "2016-04-03", "2016-04-05")]  # [in,out) adyacente, no solapa
    kept, report = local_dedupe(archive, md)
    assert kept == archive
    assert report == []


def test_local_dedupe_keeps_overlapping_different_room():
    md = [_row(5, "2016-04-01", "2016-04-03")]
    archive = [_row(6, "2016-04-02", "2016-04-05")]
    kept, report = local_dedupe(archive, md)
    assert kept == archive
    assert report == []


def test_local_dedupe_keeps_rows_missing_room_or_dates():
    md = [_row(5, "2016-04-01", "2016-04-03")]
    archive = [{"room": "", "check_in": "", "check_out": "", "guest_name": "SIN DATOS"}]
    kept, report = local_dedupe(archive, md)
    assert kept == archive
    assert report == []


def test_local_dedupe_md_always_wins_documents_precedence():
    md = [_row(5, "2016-04-01", "2016-04-03")]
    archive = [_row(5, "2016-04-02", "2016-04-04")]
    kept, report = local_dedupe(archive, md)
    # md nunca se excluye: solo se filtra archive_rows.
    assert kept == []
    assert report[0]["md_row_index"] == 0
    assert report[0]["reason"] == "overlap"


def test_local_dedupe_corrupt_md_row_does_not_exclude_archive_stays():
    # Caso real: fila de md con año typo (check_out un año adelantado) marcada
    # `stay_too_long` y sin `nights` -- su rango de 2 años "solapa" con
    # cualquier estadía de esa room, pero no es confiable como match.
    corrupt_md = _row(1, "2015-05-30", "2017-06-01", guest_name="TYPO",
                       nights="", quality_flags="stay_too_long")
    md = [corrupt_md]
    archive = [_row(1, "2015-06-10", "2015-06-12", guest_name="HUESPED REAL")]
    kept, report = local_dedupe(archive, md)
    assert kept == archive  # NO se excluye: el match de md no es confiable
    assert len(report) == 1
    assert report[0]["reason"] == "md_row_unreliable"
    assert report[0]["archive_guest_name"] == "HUESPED REAL"


def test_local_dedupe_reliable_md_row_still_excludes():
    md = [_row(5, "2016-04-01", "2016-04-03", nights="2", quality_flags="")]
    archive = [_row(5, "2016-04-02", "2016-04-04")]
    kept, report = local_dedupe(archive, md)
    assert kept == []
    assert report[0]["reason"] == "overlap"
