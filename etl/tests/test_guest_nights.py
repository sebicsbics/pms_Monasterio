"""Tests del extractor de noches (etl/parsers/guest_nights.py).

Fixtures sintéticas (celdas/listas). Nunca lee datos reales de Hotel/.
"""
from __future__ import annotations

from datetime import date

from etl.parsers.guest_nights import (
    NightObservation,
    capacity_violations,
    extract_night_observations,
    sequential_sheet_dates,
)

def test_sequential_sheet_dates_explicit_month_sets_cursor():
    names = ["1 de abril", "2 de abril", "3 de abril"]
    dated, flags = sequential_sheet_dates(names, 2014, None)
    assert dated == [date(2014, 4, 1), date(2014, 4, 2), date(2014, 4, 3)]
    assert flags == [set(), set(), set()]

def test_sequential_sheet_dates_inherits_month_and_rolls_on_day_drop():
    names = ["1 de abril", "abril 30", "1"]
    dated, _ = sequential_sheet_dates(names, 2014, None)
    assert dated == [date(2014, 4, 1), date(2014, 4, 30), date(2014, 5, 1)]

def test_sequential_sheet_dates_rollover_year_on_december_to_january():
    names = ["30 de diciembre", "31 de diciembre", "1 de enero"]
    dated, _ = sequential_sheet_dates(names, 2015, None)
    assert dated == [date(2015, 12, 30), date(2015, 12, 31), date(2016, 1, 1)]

def test_sequential_sheet_dates_flags_weekday_mismatch():
    # 2014-04-01 es martes: "lunes" no coincide, "martes" sí
    dated, flags = sequential_sheet_dates(["lunes 1 de abril", "miercoles 2 de abril"], 2014, None)
    assert dated == [date(2014, 4, 1), date(2014, 4, 2)]
    assert "weekday_mismatch" in flags[0]
    assert flags[1] == set()

def test_sequential_sheet_dates_returns_none_when_no_month_established():
    names = ["viernes 27", "1 de abril"]
    dated, flags = sequential_sheet_dates(names, 2014, None)
    assert dated[0] is None
    assert "date_unknown" in flags[0]
    assert dated[1] == date(2014, 4, 1)

def test_extract_night_observations_extracts_occupied_rooms():
    header = ["HABITACIONES", None, "Nombre", "Empresa", "Nacionalidad", "Pax",
              "Tarifa", None, "Tarjeta en Bs.-", "Forma de pago", "Ingreso "]
    rows = [
        header,
        [1, None, None, None, None, None, None, None, None, None, None],
        [2, None, "JUAN PEREZ", "EMPRESA X", "BOLIVIA", 2, 150, None, None, "EFECTIVO", None],
    ]
    obs = extract_night_observations(
        rows, header_idx=0,
        night_date=date(2014, 4, 1), sheet_name="1 de abril", sheet_index=0,
        source_file="HUESPEDES.xlsx", flags=set(),
    )
    assert len(obs) == 1
    o = obs[0]
    assert o.room == 2
    assert o.guest_name == "JUAN PEREZ"
    assert o.night_date == date(2014, 4, 1)
    assert o.sheet_index == 0

def _obs(r, d=date(2014, 4, 1)):
    return NightObservation(
        night_date=d, room=r, guest_name=f"G{r}", pax=1, rate=100,
        payment="EFECTIVO", company=None, country=None, source_file="f.xlsx",
        sheet_name="1 de abril", sheet_index=0, quality_flags=[],
    )

def test_capacity_violations_flags_over_36_rooms_same_date():
    obs = [_obs(r) for r in range(1, 38)]  # 37 habitaciones: imposible
    violations = capacity_violations(obs)
    assert len(violations) == 1
    assert violations[0][2] == 37

def test_capacity_violations_passes_within_36_rooms():
    assert capacity_violations([_obs(r) for r in range(1, 37)]) == []
