"""Tests de dedupe de noches + fusión en estadías (etl/parsers/guest_stays.py).

Fixtures sintéticas. Nunca lee datos reales de Hotel/.
"""
from __future__ import annotations

from datetime import date

from etl.parsers.guest_nights import NightObservation
from etl.parsers.guest_stays import (
    dedupe_nights,
    invalid_room_stays,
    merge_nights_into_stays,
    nights_per_year_report,
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


def test_merge_flags_rate_varies_when_nights_have_different_rates():
    nights = [
        _obs(date(2014, 4, 1), 5, "JUAN PEREZ", "f.xlsx", rate=100),
        _obs(date(2014, 4, 2), 5, "JUAN PEREZ", "f.xlsx", rate=150),
    ]
    stays = merge_nights_into_stays(nights)
    assert len(stays) == 1
    assert "rate_varies" in stays[0].quality_flags
    assert stays[0].rate_bs == 100  # se toma la tarifa de la primera noche


def test_merge_does_not_flag_rate_varies_when_rate_is_constant():
    nights = [
        _obs(date(2014, 4, 1), 5, "JUAN PEREZ", "f.xlsx", rate=100),
        _obs(date(2014, 4, 2), 5, "JUAN PEREZ", "f.xlsx", rate=100),
    ]
    stays = merge_nights_into_stays(nights)
    assert "rate_varies" not in stays[0].quality_flags


def test_merge_flags_name_not_person_for_curated_override():
    nights = [_obs(date(2014, 4, 1), 5, "DELEGACIÓN", "f.xlsx")]
    stays = merge_nights_into_stays(nights)
    assert len(stays) == 1
    assert "name_not_person" in stays[0].quality_flags


def test_merge_does_not_flag_name_not_person_for_real_guest():
    nights = [_obs(date(2014, 4, 1), 5, "JUAN PEREZ", "f.xlsx")]
    stays = merge_nights_into_stays(nights)
    assert "name_not_person" not in stays[0].quality_flags


def test_merge_flags_room_change_for_same_guest_next_night():
    nights = [
        _obs(date(2014, 4, 1), 5, "JUAN PEREZ", "f.xlsx"),
        _obs(date(2014, 4, 2), 7, "JUAN PEREZ", "f.xlsx"),
    ]
    stays = merge_nights_into_stays(nights)
    assert len(stays) == 2
    assert "room_change" in stays[1].quality_flags


def _stay(room, check_in=date(2016, 4, 1), check_out=date(2016, 4, 2), nights=1, guest_name="G"):
    from etl.parsers.guest_stays import Stay
    return Stay(
        guest_name=guest_name, room=room, pax=1, check_in=check_in, check_out=check_out,
        nights=nights, rate_bs=100, total_bs=100, total_source="recomputed",
        payment=None, channel=None, country=None, is_multi_guest=False,
        source_file="f.xlsx", quality_flags=[],
    )


def test_invalid_room_stays_flags_rooms_outside_valid_set():
    # 13 no existe (superstición del hotel) y 99 no existe: ambos invalidos.
    stays = [_stay(5), _stay(13), _stay(99)]
    invalid = invalid_room_stays(stays)
    assert {s.room for s in invalid} == {13, 99}


def test_invalid_room_stays_empty_when_all_rooms_valid():
    assert invalid_room_stays([_stay(1), _stay(36)]) == []


def test_nights_per_year_report_reports_without_asserting_capacity():
    stays = [
        _stay(1, check_in=date(2016, 4, 1), check_out=date(2016, 4, 3), nights=2),
        _stay(2, check_in=date(2017, 1, 1), check_out=date(2017, 1, 2), nights=1),
    ]
    report = nights_per_year_report(stays)
    assert report[2016] == 2
    assert report[2017] == 1
