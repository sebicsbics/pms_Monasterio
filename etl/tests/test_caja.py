"""Tests del parser de registros de caja (etl/parsers/caja.py).

Fixtures sintéticas con la plantilla real (FECHA | RECEPCIONISTA | INGRESO
Bs/$us | Nº REC-FACT | EGRESO Bs/$us | Nº REC-FACT | DETALLE | TOTAL... |
OBSERVACIONES). Nunca lee archivos reales de Hotel/.
"""
from __future__ import annotations

from datetime import date, datetime

from etl.parsers.caja import (
    extract_cash_movements,
    find_cash_header,
    parse_amount,
    parse_date_cell,
)

HEADER = ["FECHA", "RECEPCIONISTA", "INGRESO", None, "Nº REC-FACT", "EGRESO", None,
          "Nº REC-FACT", "DETALLE", "TOTAL (solo hospd)", None,
          "TOTAL (solo caja y otros)", None, "OBSERVACIONES"]
SUBHEADER = [None, None, "Bs.-", "$u$", None, "Bs.-", "$u$", None, None,
             "Bs.-", "$u$", "Bs.-", "$u$", None]


def _row(fecha=None, recep=None, ing_bs=None, ing_us=None, ing_ref=None,
         egr_bs=None, egr_us=None, egr_ref=None, detalle=None,
         tot_h=None, tot_c=None, obs=None):
    return [fecha, recep, ing_bs, ing_us, ing_ref, egr_bs, egr_us, egr_ref,
            detalle, tot_h, None, tot_c, None, obs]


def _sheet(*rows):
    return [HEADER, SUBHEADER, *rows]


# ---------------------------------------------------------------- header

def test_find_cash_header_maps_columns_by_name_and_currency_subheader():
    cols = find_cash_header(_sheet())
    assert cols is not None
    assert cols.header_row == 0
    assert (cols.date, cols.receptionist, cols.detail, cols.observations) == (0, 1, 8, 13)
    assert (cols.income_bs, cols.income_usd, cols.income_ref) == (2, 3, 4)
    assert (cols.expense_bs, cols.expense_usd, cols.expense_ref) == (5, 6, 7)
    assert cols.flags == []


def test_find_cash_header_on_second_row_like_some_2013_sheets():
    cols = find_cash_header([[None, "REGISTRO DE CAJA"], HEADER, SUBHEADER])
    assert cols is not None and cols.header_row == 1


def test_find_cash_header_none_for_non_cash_sheet():
    assert find_cash_header([["Nº", "HABITACION", "NOMBRE"], [1, 5, "x"]]) is None


def test_find_cash_header_swapped_currency_subheader_is_honored():
    sub = list(SUBHEADER)
    sub[2], sub[3] = "$u$", "Bs.-"
    cols = find_cash_header([HEADER, sub])
    assert (cols.income_bs, cols.income_usd) == (3, 2)


def test_find_cash_header_without_subheader_assumes_bs_first_and_flags():
    cols = find_cash_header([HEADER, _row(fecha=datetime(2014, 7, 1))])
    assert (cols.income_bs, cols.income_usd) == (2, 3)
    assert "currency_order_assumed" in cols.flags


# ---------------------------------------------------------------- cells

def test_parse_amount_numbers_text_and_blanks():
    assert parse_amount(200) == (200.0, True)
    assert parse_amount("64.80") == (64.8, True)
    assert parse_amount("64,80") == (64.8, True)
    assert parse_amount(None) == (None, True)
    assert parse_amount("  ") == (None, True)
    assert parse_amount("-") == (None, True)
    assert parse_amount("doscientos") == (None, False)


def test_parse_date_cell_datetime_and_text_with_trailing_name():
    assert parse_date_cell(datetime(2014, 9, 30, 0, 0)) == date(2014, 9, 30)
    # caso real CAJA (OCTUBRE).xlsx.xls: fecha pegada al nombre del turno
    assert parse_date_cell("30/09/2014  TURNO") == date(2014, 9, 30)
    assert parse_date_cell("SALDO") is None
    assert parse_date_cell(None) is None


# ---------------------------------------------------------------- movements

def test_extract_forward_fills_date_within_the_shift():
    rows = _sheet(
        _row(fecha=datetime(2015, 1, 4), recep="A", ing_bs=165, detalle="HAB 5"),
        _row(ing_bs=10, detalle="LAVANDERIA"),
    )
    movements, issues = extract_cash_movements(rows, source_file="f.xlsx", sheet_name="Hoja1")
    assert [m.movement_date for m in movements] == [date(2015, 1, 4), date(2015, 1, 4)]
    assert issues == []


def test_extract_ignores_totals_and_balance_rows_without_amounts():
    rows = _sheet(
        _row(fecha=datetime(2015, 1, 1), detalle="SALDO DEL TURNO ANTERIOR", tot_h=71),
        _row(detalle="TOTAL EN CAJA", tot_h=185, tot_c=57),
    )
    movements, _ = extract_cash_movements(rows, source_file="f.xlsx", sheet_name="Hoja1")
    assert movements == []


def test_extract_keeps_real_amount_on_a_row_labelled_saldo():
    # Caso real 2015-01-07: "SALDO DEL TURNO ANTERIOR" con un ingreso de
    # 384 Bs. Se filtra por monto, nunca por la etiqueta.
    rows = _sheet(_row(fecha=datetime(2015, 1, 7), ing_bs=384,
                       detalle="SALDO DEL TURNO ANTERIOR", tot_h=384))
    movements, _ = extract_cash_movements(rows, source_file="f.xlsx", sheet_name="Hoja1")
    assert [(m.kind, m.amount) for m in movements] == [("income", 384.0)]


def test_extract_splits_row_with_income_and_expense_into_two_movements():
    rows = _sheet(_row(fecha=datetime(2015, 1, 5), recep="B", ing_bs=185, ing_ref="2230",
                       egr_bs=27, egr_ref="F-11", detalle="HAB 3 / COMPRA PAN", obs="ok"))
    movements, _ = extract_cash_movements(rows, source_file="f.xlsx", sheet_name="Hoja1")
    got = [(m.kind, m.currency, m.amount, m.receipt_ref) for m in movements]
    assert got == [("income", "BOB", 185.0, "2230"), ("expense", "BOB", 27.0, "F-11")]
    for m in movements:
        assert (m.concept, m.receptionist, m.observations) == ("HAB 3 / COMPRA PAN", "B", "ok")
        assert (m.source_file, m.sheet_name, m.source_row) == ("f.xlsx", "Hoja1", 3)


def test_extract_usd_amounts_get_usd_currency():
    rows = _sheet(_row(fecha=datetime(2015, 1, 5), ing_us=200, detalle="PAGO EN DOLARES"))
    [m] = extract_cash_movements(rows, source_file="f.xlsx", sheet_name="Hoja1")[0]
    assert (m.kind, m.currency, m.amount) == ("income", "USD", 200.0)


def test_extract_negative_amount_is_kept_and_flagged():
    rows = _sheet(_row(fecha=datetime(2013, 8, 2), egr_bs=-200, detalle="CORRECCION"))
    [m] = extract_cash_movements(rows, source_file="f.xlsx", sheet_name="Hoja1")[0]
    assert m.amount == -200.0
    assert "negative_amount" in m.quality_flags


def test_extract_amount_before_any_date_goes_to_issues_not_movements():
    rows = _sheet(_row(ing_bs=50, detalle="SIN FECHA"))
    movements, issues = extract_cash_movements(rows, source_file="f.xlsx", sheet_name="Hoja1")
    assert movements == []
    assert [i["reason"] for i in issues] == ["no_date"]


def test_extract_unparseable_amount_goes_to_issues():
    rows = _sheet(_row(fecha=datetime(2014, 7, 1), ing_bs="doscientos"))
    movements, issues = extract_cash_movements(rows, source_file="f.xlsx", sheet_name="Hoja1")
    assert movements == []
    assert [i["reason"] for i in issues] == ["unparseable_amount"]


def test_extract_date_outside_archive_window_goes_to_issues():
    rows = _sheet(_row(fecha=datetime(2104, 7, 1), ing_bs=10))
    movements, issues = extract_cash_movements(rows, source_file="f.xlsx", sheet_name="Hoja1")
    assert movements == []
    assert [i["reason"] for i in issues] == ["date_out_of_window"]


# ------------------------------------------- casos reales del libro 2015-2016

def test_parse_amount_strips_literal_quotes():
    # caso real: el monto tipeado como '"1411"'
    assert parse_amount('"1411"') == (1411.0, True)
    assert parse_amount("???") == (None, False)


def test_parse_date_cell_three_digit_year_typo():
    # caso real: 31 celdas '24/01/216' en 2016-01..04
    assert parse_date_cell("24/01/216") == date(2016, 1, 24)


def test_extract_flags_corrected_year_typo_for_the_whole_shift():
    rows = _sheet(
        _row(fecha="24/01/216", ing_bs=210),
        _row(ing_bs=560),
    )
    movements, issues = extract_cash_movements(rows, source_file="f.xls", sheet_name="Hoja1")
    assert issues == []
    assert [m.movement_date for m in movements] == [date(2016, 1, 24)] * 2
    assert all("date_year_typo_corrected" in m.quality_flags for m in movements)


def test_extract_flags_backward_date_jump_but_keeps_written_date():
    # caso real: '24/01/216' tras el 2016-01-30. El día no encaja en la
    # secuencia, así que no se inventa la fecha: se conserva y se marca.
    rows = _sheet(
        _row(fecha=datetime(2016, 1, 30), ing_bs=100),
        _row(fecha=datetime(2016, 1, 24), ing_bs=50),
        _row(fecha=datetime(2016, 1, 31), ing_bs=70),
    )
    movements, _ = extract_cash_movements(rows, source_file="f.xls", sheet_name="Hoja1")
    by_amount = {m.amount: m for m in movements}
    assert by_amount[50.0].movement_date == date(2016, 1, 24)
    assert "date_out_of_sequence" in by_amount[50.0].quality_flags
    assert "date_out_of_sequence" not in by_amount[100.0].quality_flags
    assert "date_out_of_sequence" not in by_amount[70.0].quality_flags


def test_extract_previous_day_late_entry_is_not_out_of_sequence():
    rows = _sheet(
        _row(fecha=datetime(2016, 3, 11), ing_bs=100),
        _row(fecha=datetime(2016, 3, 10), ing_bs=50),
    )
    movements, _ = extract_cash_movements(rows, source_file="f.xls", sheet_name="Hoja1")
    assert all("date_out_of_sequence" not in m.quality_flags for m in movements)


def test_extract_corrects_stale_month_when_day_fits_the_sequence():
    # Caso real jun-jul 2015: plantilla copiada del mes anterior, el día es
    # correcto pero el mes quedó atrasado ('05-04' entre '06-03' y '06-04').
    rows = _sheet(
        _row(fecha=datetime(2015, 6, 3), ing_bs=100),
        _row(fecha=datetime(2015, 5, 4), ing_bs=50),
        _row(fecha=datetime(2015, 6, 5), ing_bs=70),
    )
    movements, _ = extract_cash_movements(rows, source_file="f.xls", sheet_name="Hoja1")
    by_amount = {m.amount: m for m in movements}
    assert by_amount[50.0].movement_date == date(2015, 6, 4)
    assert "date_month_typo_corrected" in by_amount[50.0].quality_flags
    assert "date_out_of_sequence" not in by_amount[50.0].quality_flags
    assert by_amount[70.0].quality_flags == ""


def test_extract_stale_month_correction_handles_year_boundary():
    rows = _sheet(
        _row(fecha=datetime(2016, 1, 2), ing_bs=100),
        _row(fecha=datetime(2015, 12, 3), ing_bs=50),
    )
    movements, _ = extract_cash_movements(rows, source_file="f.xls", sheet_name="Hoja1")
    assert {m.amount: m.movement_date for m in movements}[50.0] == date(2016, 1, 3)


def test_extract_skips_header_repeated_mid_sheet():
    # Caso real: la plantilla re-pegada al empezar otro mes en el mismo libro.
    rows = _sheet(
        _row(fecha=datetime(2014, 9, 30), ing_bs=10),
        HEADER,
        SUBHEADER,
        _row(fecha=datetime(2014, 10, 1), ing_bs=20),
    )
    movements, issues = extract_cash_movements(rows, source_file="f.xlsx", sheet_name="Hoja1")
    assert [m.amount for m in movements] == [10.0, 20.0]
    assert issues == []


def test_parse_amount_double_dot_placeholder_is_empty():
    assert parse_amount("..") == (None, True)


def test_extract_does_not_correct_a_year_jump():
    # Revisión: INFORME CAJA DICIEMBRE abarca 2015-12..2016-12, así que un
    # 2015-12-10 tras 2016-12-09 puede ser legítimo. Nunca se mueve un año.
    rows = _sheet(
        _row(fecha=datetime(2016, 12, 9), ing_bs=100),
        _row(fecha=datetime(2015, 12, 10), ing_bs=50),
    )
    movements, _ = extract_cash_movements(rows, source_file="f.xlsx", sheet_name="Hoja1")
    m = {m.amount: m for m in movements}[50.0]
    assert m.movement_date == date(2015, 12, 10)
    assert "date_out_of_sequence" in m.quality_flags
    assert "date_month_typo_corrected" not in m.quality_flags


def test_extract_does_not_correct_a_month_stale_by_more_than_one():
    rows = _sheet(
        _row(fecha=datetime(2015, 7, 12), ing_bs=100),
        _row(fecha=datetime(2015, 4, 13), ing_bs=50),
    )
    movements, _ = extract_cash_movements(rows, source_file="f.xls", sheet_name="Hoja1")
    m = {m.amount: m for m in movements}[50.0]
    assert m.movement_date == date(2015, 4, 13)
    assert "date_out_of_sequence" in m.quality_flags


def test_extract_amount_text_with_currency_prefix_is_not_a_template_row():
    rows = _sheet(_row(fecha=datetime(2014, 7, 1), ing_bs="Bs 50"))
    movements, issues = extract_cash_movements(rows, source_file="f.xlsx", sheet_name="Hoja1")
    assert [m.amount for m in movements] == [50.0]
    assert issues == []


# ------------------------------------------- ancla en el nombre de la hoja

def test_sheet_month_anchor_parses_month_and_year_only_when_both_present():
    from etl.parsers.caja import sheet_month_anchor
    assert sheet_month_anchor("Junio 2013") == (2013, 6)
    assert sheet_month_anchor("Septiembre 2013") == (2013, 9)
    assert sheet_month_anchor("caja julio") is None
    assert sheet_month_anchor("Hoja1") is None


def test_extract_corrects_date_to_sheet_month_when_day_fits_sequence():
    # Casos reales: '2013-03-17' en la hoja "Junio 2013" entre filas del
    # 06-17, y '2012-09-18' en "Septiembre 2013" entre el 09-18 y el 09-19.
    rows = _sheet(
        _row(fecha=datetime(2013, 6, 17), ing_bs=100),
        _row(fecha=datetime(2013, 3, 17), ing_bs=1),
        _row(fecha=datetime(2012, 6, 18), ing_bs=40),
    )
    movements, _ = extract_cash_movements(rows, source_file="f.xlsx", sheet_name="Junio 2013")
    by_amount = {m.amount: m for m in movements}
    assert by_amount[1.0].movement_date == date(2013, 6, 17)
    assert by_amount[40.0].movement_date == date(2013, 6, 18)
    assert "date_corrected_to_sheet_month" in by_amount[1.0].quality_flags
    assert by_amount[100.0].quality_flags == ""


def test_extract_sheet_anchor_keeps_previous_month_tail_at_sheet_start():
    # Una hoja mensual arranca con los últimos días del mes anterior: no se tocan.
    rows = _sheet(
        _row(fecha=datetime(2013, 5, 30), ing_bs=10),
        _row(fecha=datetime(2013, 5, 31), ing_bs=20),
        _row(fecha=datetime(2013, 6, 1), ing_bs=30),
    )
    movements, _ = extract_cash_movements(rows, source_file="f.xlsx", sheet_name="Junio 2013")
    assert [m.movement_date for m in movements] == [date(2013, 5, 30), date(2013, 5, 31), date(2013, 6, 1)]
    assert all(m.quality_flags == "" for m in movements)


def test_extract_sheet_anchor_keeps_next_month_head_at_sheet_end():
    rows = _sheet(
        _row(fecha=datetime(2013, 6, 30), ing_bs=10),
        _row(fecha=datetime(2013, 7, 1), ing_bs=20),
    )
    movements, _ = extract_cash_movements(rows, source_file="f.xlsx", sheet_name="Junio 2013")
    assert [m.movement_date for m in movements] == [date(2013, 6, 30), date(2013, 7, 1)]
