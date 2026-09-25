"""Tests de dedupe de noches + fusión en estadías (etl/parsers/guest_stays.py).

Fixtures sintéticas. Nunca lee datos reales de Hotel/.
"""
from __future__ import annotations

from datetime import date

from etl.parsers.guest_nights import NightObservation
from etl.parsers.guest_stays import (
    capacity_violations_final,
    dedupe_nights,
    merge_nights_into_stays,
)


def _obs(night_date, room, guest_name, source_file, **kw):
    return NightObservation(
        night_date=night_date, room=room, guest_name=guest_name,
        pax=kw.get("pax"), rate=kw.get("rate", 100), payment=kw.get("payment"),
        company=kw.get("company"), country=kw.get("country"),
        source_file=source_file, sheet_name=kw.get("sheet_name", "s"),
        sheet_index=kw.get("sheet_index", 0), quality_flags=kw.get("quality_flags", []),
    )


def test_dedupe_nights_no_dup_when_single_observation():
    obs = [_obs(date(2016, 4, 1), 5, "JUAN PEREZ", "HUESPEDES ABRIL 2016.xls")]
    kept, report = dedupe_nights(obs)
    assert kept == obs
    assert report == []


def test_dedupe_nights_prefers_file_matching_nominal_month():
    a = _obs(date(2016, 4, 1), 5, "JUAN PEREZ", "HUESPEDES ABRIL 2016.xls")
    b = _obs(date(2016, 4, 1), 5, "JUAN PEREZ", "HUESPEDES NOVIEMBRE 2016.xls")
    kept, report = dedupe_nights([a, b])
    assert kept == [a]
    assert len(report) == 1
    assert report[0]["discarded_source"] == "HUESPEDES NOVIEMBRE 2016.xls"


def test_dedupe_nights_prefers_latest_dated_file_when_no_month_match():
    a = _obs(date(2016, 4, 1), 5, "JUAN PEREZ", "HUESPEDES JUNIO 2016.xls")
    b = _obs(date(2016, 4, 1), 5, "JUAN PEREZ", "HUESPEDES SEPTIEMBRE 2016.xls")
    kept, _ = dedupe_nights([a, b])
    assert kept == [b]  # septiembre > junio: gana el más tardío


def test_dedupe_nights_flags_conflict_when_names_differ():
    a = _obs(date(2016, 4, 1), 5, "JUAN PEREZ", "HUESPEDES ABRIL 2016.xls")
    b = _obs(date(2016, 4, 1), 5, "MARIA LOPEZ", "HUESPEDES NOVIEMBRE 2016.xls")
    _, report = dedupe_nights([a, b])
    assert report[0]["night_conflict"] is True


def test_merge_nights_into_stays_consecutive_same_room_guest():
    nights = [
        _obs(date(2014, 4, 1), 5, "JUAN PEREZ", "f.xlsx"),
        _obs(date(2014, 4, 2), 5, "JUAN PEREZ", "f.xlsx"),
        _obs(date(2014, 4, 3), 5, "JUAN PEREZ", "f.xlsx"),
    ]
    stays = merge_nights_into_stays(nights)
    assert len(stays) == 1
    assert stays[0].check_in == date(2014, 4, 1)
    assert stays[0].check_out == date(2014, 4, 4)
    assert stays[0].nights == 3


def test_merge_breaks_on_gap_and_guest_change():
    nights = [
        _obs(date(2014, 4, 1), 5, "JUAN PEREZ", "f.xlsx"),
        _obs(date(2014, 4, 3), 5, "JUAN PEREZ", "f.xlsx"),  # hueco
        _obs(date(2014, 4, 4), 5, "MARIA LOPEZ", "f.xlsx"),  # cambio de huésped
    ]
    stays = merge_nights_into_stays(nights)
    assert len(stays) == 3


def test_merge_flags_room_change_for_same_guest_next_night():
    nights = [
        _obs(date(2014, 4, 1), 5, "JUAN PEREZ", "f.xlsx"),
        _obs(date(2014, 4, 2), 7, "JUAN PEREZ", "f.xlsx"),
    ]
    stays = merge_nights_into_stays(nights)
    assert len(stays) == 2
    assert "room_change" in stays[1].quality_flags


def test_capacity_violations_final_flags_over_36_rooms_same_date():
    from etl.parsers.guest_stays import Stay
    stays = [
        Stay(guest_name=f"G{r}", room=r, pax=1, check_in=date(2016, 4, 1),
             check_out=date(2016, 4, 2), nights=1, rate_bs=100, total_bs=100,
             total_source="recomputed", payment=None, channel=None, country=None,
             is_multi_guest=False, source_file="f.xlsx", quality_flags=[])
        for r in range(1, 38)
    ]
    violations = capacity_violations_final(stays)
    assert len(violations) == 1
    assert violations[0][1] == 37
