"""Tests del extractor de noches (etl/parsers/guest_nights.py).

Fixtures sintéticas (celdas/listas). Nunca lee datos reales de Hotel/.
"""
from __future__ import annotations

from datetime import date

from etl.parsers.guest_nights import (
    NightObservation,
    _is_guest_register_path,
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
    # 2014-04-01 es martes: la hoja ancla declara "martes" (coincide) y la
    # siguiente declara "lunes" para el 2 de abril (no coincide con
    # miércoles real) -> weekday_mismatch, pero la fecha local (2 de abril,
    # el único candidato dentro del salto de 45 días) se conserva igual.
    dated, flags = sequential_sheet_dates(["martes 1 de abril", "lunes 2 de abril"], 2014, None)
    assert dated == [date(2014, 4, 1), date(2014, 4, 2)]
    assert flags[0] == set()
    assert "weekday_mismatch" in flags[1]

def test_sequential_sheet_dates_returns_none_when_no_firm_anchor():
    # Ninguna hoja trae mes explícito: no hay forma de anclar la secuencia.
    names = ["viernes 27", "sabado 28"]
    dated, flags = sequential_sheet_dates(names, 2014, None)
    assert dated == [None, None]
    assert flags == [{"date_unknown"}, {"date_unknown"}]

def test_sequential_sheet_dates_backfills_from_first_firm_anchor():
    # El ancla firme (mes+dia+weekday) se establece en la 5ta hoja y las
    # anteriores (solo dia/weekday) se resuelven propagando hacia atras.
    names = ["viernes 27", "sabado 28", "lunes 30", "martes 31", "01 ABRIL MIERCOLES"]
    dated, flags = sequential_sheet_dates(names, 2016, None)
    assert dated == [
        date(2015, 3, 27), date(2015, 3, 28), date(2015, 3, 30),
        date(2015, 3, 31), date(2015, 4, 1),
    ]
    assert all("date_unknown" not in f for f in flags)

def test_sequential_sheet_dates_febrero_workbook_sequence_real_case():
    # Reproduce (con huespedes inventados) el caso real de
    # "HUESPEDES ( FEBRERO 2016).xls": el nombre del archivo sugiere 2016
    # pero la secuencia real arranca en marzo/abril 2015 y llega hasta
    # el 29-feb-2016 (bisiesto), validado por el weekday declarado.
    names = [
        "viernes 27", "sabado 28", "lunes 30", "martes 31",
        "01 ABRIL MIERCOLES",
        "1 de mayo", "1 de junio", "1 de julio", "1 de agosto",
        "1 de septiembre", "1 de octubre", "1 de noviembre", "1 de diciembre",
        "1 de enero", "29-feb lunes",
    ]
    dated, flags = sequential_sheet_dates(names, 2016, None)
    assert dated[0] == date(2015, 3, 27)
    assert dated[4] == date(2015, 4, 1)
    assert dated[-1] == date(2016, 2, 29)
    assert "weekday_mismatch" not in flags[-1]

def test_sequential_sheet_dates_handles_weekday_typos():
    names = ["01 ABRIL MIERCOLES", "Doomingo 5", "Domigno 12"]
    dated, flags = sequential_sheet_dates(names, 2015, None)
    assert dated[0] == date(2015, 4, 1)
    assert dated[1] is not None
    assert dated[2] is not None

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

def test_is_guest_register_path_excludes_movimientos_diarios_even_under_huespedes_folder():
    # Carpeta llamada HUESPEDES pero el archivo es de otra familia (bug real).
    assert _is_guest_register_path("2015/HUESPEDES/MOVIMIENTOS DIARIOS 2015 HASTA JUNIO.xls") is False
    assert _is_guest_register_path("Sergio (Revisar)/MOVIMIENTOS DIARIOS 2015 HASTA OCT.xls") is False

def test_is_guest_register_path_accepts_true_guest_register_files():
    assert _is_guest_register_path("2014/ARCHIVOS (huespedes 2014)/HUESPEDES (abril 2014).xlsx") is True
    assert _is_guest_register_path("2013/ARCHIVO (Registros de huépedes)/REGISTRO DE HUESPEDES (DICEMBRE 2013).xlsx") is True
