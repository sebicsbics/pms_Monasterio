"""
Parser de los registros de caja de recepción del archivo `Hotel/` (2013-2016).

Plantilla real (una hoja por mes, o el libro acumulativo 2015-04..2016-11):

    FECHA | RECEPCIONISTA | INGRESO Bs/$us | Nº REC-FACT | EGRESO Bs/$us |
    Nº REC-FACT | DETALLE | TOTAL (solo hospd) Bs/$us |
    TOTAL (solo caja y otros) Bs/$us | OBSERVACIONES

con un subencabezado `Bs.- | $u$` debajo de cada bloque de montos.

Reglas (verificadas contra los archivos reales, ver etl/README.md):

- La plata está SOLO en INGRESO/EGRESO. Las columnas TOTAL son un arqueo del
  cajón llevado a mano dentro del turno, con huecos: nunca son movimientos.
- Se filtra por MONTO, nunca por la etiqueta: hay filas "SALDO DEL TURNO
  ANTERIOR" con ingresos reales (2015-01-07: 384 Bs).
- La fecha va en la primera fila del turno y se arrastra hacia abajo. Una
  celda de fecha fuera de la ventana del archivo corta el arrastre: las
  filas siguientes van a `issues` hasta la próxima fecha válida, nunca
  heredan en silencio la fecha anterior.
- Una fila con ingreso y egreso a la vez da DOS movimientos (formato largo,
  alineado con `cash_movements`: kind income/expense + currency BOB/USD).
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import date, datetime
from pathlib import Path

from etl.parsers.guest_nights import (
    MONTHS,
    _WINDOW_END,
    _WINDOW_START,
    _read_xlsx_sheets,
    _strip_accents_lower,
)

_HEADER_SCAN_ROWS = 6
_SHEET_YEAR_RE = re.compile(r"(20\d\d)")
_SHEET_WORD_RE = re.compile(r"[a-z]+")
_TEXT_DATE_RE = re.compile(r"^\s*(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})")
_EMPTY_AMOUNT_TOKENS = {"", "-", "--", ".."}


@dataclass
class CashColumns:
    header_row: int
    date: int
    receptionist: int | None
    income_bs: int
    income_usd: int
    income_ref: int | None
    expense_bs: int
    expense_usd: int
    expense_ref: int | None
    detail: int | None
    observations: int | None
    data_start: int = 0  # primera fila de datos (saltea el subencabezado Bs/$us)
    flags: list[str] = field(default_factory=list)


@dataclass
class CashMovement:
    movement_date: date
    kind: str            # 'income' | 'expense'
    currency: str        # 'BOB' | 'USD'
    amount: float
    concept: str | None
    receipt_ref: str | None
    receptionist: str | None
    observations: str | None
    source_file: str
    sheet_name: str
    source_row: int      # fila 1-based dentro de la hoja
    quality_flags: str


def _norm(value: object) -> str:
    return _strip_accents_lower(str(value)).strip() if value is not None else ""


def _currency_of(label: object) -> str | None:
    norm = _norm(label).replace(" ", "")
    if norm.startswith("bs"):
        return "BOB"
    if "$" in norm or norm.startswith("us"):
        return "USD"
    return None


def _pair_columns(first: int, subheader: list | None, flags: list[str]) -> tuple[int, int]:
    """(columna Bs, columna $us) de un bloque INGRESO/EGRESO de 2 columnas."""
    if subheader is not None:
        a = _currency_of(subheader[first]) if first < len(subheader) else None
        b = _currency_of(subheader[first + 1]) if first + 1 < len(subheader) else None
        if (a, b) == ("BOB", "USD"):
            return first, first + 1
        if (a, b) == ("USD", "BOB"):
            return first + 1, first
    if "currency_order_assumed" not in flags:
        flags.append("currency_order_assumed")
    return first, first + 1


def find_cash_header(rows: list[list]) -> CashColumns | None:
    """Ubica el encabezado de caja (fila con INGRESO y EGRESO) por nombre de
    columna, nunca por posición fija. None si la hoja no es de caja."""
    for idx, row in enumerate(rows[:_HEADER_SCAN_ROWS]):
        labels = [_norm(v) for v in row]
        if "ingreso" not in labels or "egreso" not in labels or "fecha" not in labels:
            continue

        def find(pred, start: int = 0, stop: int | None = None) -> int | None:
            end = len(labels) if stop is None else min(stop, len(labels))
            return next((c for c in range(start, end) if pred(labels[c])), None)

        income = labels.index("ingreso")
        expense = labels.index("egreso")
        detail = find(lambda s: s == "detalle")
        is_ref = lambda s: "rec" in s or "fact" in s  # noqa: E731 - "Nº REC-FACT"
        flags: list[str] = []
        subheader = rows[idx + 1] if idx + 1 < len(rows) else None
        has_subheader = subheader is not None and any(
            _currency_of(subheader[c]) for c in (income, income + 1) if c < len(subheader)
        )
        income_bs, income_usd = _pair_columns(income, subheader, flags)
        expense_bs, expense_usd = _pair_columns(expense, subheader, flags)
        return CashColumns(
            header_row=idx,
            date=labels.index("fecha"),
            receptionist=find(lambda s: s.startswith("recepcion")),
            income_bs=income_bs,
            income_usd=income_usd,
            income_ref=find(is_ref, income + 2, expense),
            expense_bs=expense_bs,
            expense_usd=expense_usd,
            expense_ref=find(is_ref, expense + 2, detail),
            detail=detail,
            observations=find(lambda s: s.startswith("observacion")),
            data_start=idx + (2 if has_subheader else 1),
            flags=flags,
        )
    return None


def parse_amount(value: object) -> tuple[float | None, bool]:
    """(monto, ok). Celda vacía o '-' -> (None, True); texto no numérico ->
    (None, False). Acepta '64.80', '64,80' y '1.234,50'."""
    if value is None or isinstance(value, bool):
        return None, True
    if isinstance(value, (int, float)):
        return float(value), True
    text = str(value).strip().strip("\"'").lower()
    text = text.replace("bs", "").replace("$", "").replace(" ", "")
    if text in _EMPTY_AMOUNT_TOKENS:
        return None, True
    if "," in text and "." in text:
        if text.rfind(",") > text.rfind("."):
            text = text.replace(".", "").replace(",", ".")
        else:
            text = text.replace(",", "")
    elif "," in text:
        text = text.replace(",", ".")
    try:
        return float(text), True
    except ValueError:
        return None, False


def parse_date_cell(value: object) -> date | None:
    """Fecha de la celda FECHA: datetime/date, o texto 'dd/mm/aaaa ...' (caso
    real: la fecha pegada al nombre del turno). None si no es una fecha."""
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    if isinstance(value, str):
        m = _TEXT_DATE_RE.match(value)
        if m:
            day, month, year = (int(g) for g in m.groups())
            if year < 100:
                year += 2000
            elif _is_year_typo(m.group(3)):
                year = 2000 + year % 100
            try:
                return date(year, month, day)
            except ValueError:
                return None
    return None


def _is_year_typo(year_text: str) -> bool:
    """'216' por '2016' (caso real: 31 celdas en 2016-01..04)."""
    return len(year_text) == 3 and year_text.startswith("2")


def _date_cell_flags(value: object) -> list[str]:
    if isinstance(value, str):
        m = _TEXT_DATE_RE.match(value)
        if m and _is_year_typo(m.group(3)):
            return ["date_year_typo_corrected"]
    return []


_STALE_MONTH_MAX_GAP_DAYS = 2


def sheet_month_anchor(sheet_name: str) -> tuple[int, int] | None:
    """(año, mes) de una hoja nombrada 'Mes Año' ('Junio 2013'). Sin mes
    completo Y año explícitos no hay ancla ('caja julio', 'Hoja1')."""
    norm = _strip_accents_lower(sheet_name)
    year = _SHEET_YEAR_RE.search(norm)
    months = [MONTHS[w] for w in _SHEET_WORD_RE.findall(norm) if w in MONTHS]
    if year is None or len(set(months)) != 1:
        return None
    return int(year.group(1)), months[0]


def _sheet_anchor_fix(cell_date: date, previous: date | None, anchor: tuple[int, int] | None) -> date | None:
    """El mismo día en el mes que declara el nombre de la hoja, si la fecha
    escrita cae en otro mes o en otro año y el día corregido queda 0..2 días
    después de la fila anterior (casos reales: '2013-03-17' en 'Junio 2013',
    y años tipeados 2001/2012/2023 en hojas de 2013). Las colas del mes anterior al inicio
    de la hoja y la cabeza del siguiente al final no encajan y no se tocan."""
    if anchor is None or previous is None or (cell_date.year, cell_date.month) == anchor:
        return None
    try:
        candidate = date(anchor[0], anchor[1], cell_date.day)
    except ValueError:
        return None
    if 0 <= (candidate - previous).days <= _STALE_MONTH_MAX_GAP_DAYS:
        return candidate
    return None


def _month_index(d: date) -> int:
    return d.year * 12 + d.month - 1


def _stale_month_fix(cell_date: date, previous: date) -> date | None:
    """El mismo día con el mes/año de `previous` (o del mes siguiente, por si
    el turno cruzó fin de mes), si queda 0..2 días después de `previous`.

    Solo cuando la fecha escrita está EXACTAMENTE un mes atrás de `previous`
    (plantilla copiada del mes anterior). Saltos mayores (meses o un año
    atrás) pueden ser legítimos -- INFORME CAJA DICIEMBRE abarca 2015-12 a
    2016-12 -- y nunca se corrigen."""
    if _month_index(previous) - _month_index(cell_date) != 1:
        return None
    for year, month in ((previous.year, previous.month),
                        (previous.year + previous.month // 12, previous.month % 12 + 1)):
        try:
            candidate = date(year, month, cell_date.day)
        except ValueError:
            continue
        if 0 <= (candidate - previous).days <= _STALE_MONTH_MAX_GAP_DAYS:
            return candidate
    return None


def _cell(row: list, col: int | None) -> object:
    return row[col] if col is not None and col < len(row) else None


def _text(value: object) -> str | None:
    if value is None:
        return None
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    return str(value).strip() or None


def _is_template_row(row: list, cols: CashColumns) -> bool:
    """Encabezado o subencabezado Bs/$us re-pegado a mitad de hoja (caso
    real: la plantilla copiada al empezar otro mes en el mismo libro)."""
    cells = [_cell(row, c) for c in (cols.income_bs, cols.income_usd, cols.expense_bs, cols.expense_usd)]
    texts = [c for c in cells if isinstance(c, str) and c.strip()]
    if any(ch.isdigit() for c in texts for ch in c):
        return False  # 'Bs 50' es un monto en texto, no la plantilla
    return bool(texts) and all(
        _norm(c) in ("ingreso", "egreso") or _currency_of(c) for c in texts
    ) and not any(_is_number(c) for c in cells)


def _is_number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _in_window(d: date) -> bool:
    return _WINDOW_START <= d <= _WINDOW_END


def extract_cash_movements(
    rows: list[list], source_file: str, sheet_name: str
) -> tuple[list[CashMovement], list[dict]]:
    """Movimientos de una hoja de caja + filas con monto que no se pudieron
    ubicar (`issues`, con `reason`: no_date | date_out_of_window |
    unparseable_amount). Hoja sin encabezado de caja -> ([], [])."""
    cols = find_cash_header(rows)
    if cols is None:
        return [], []

    movements: list[CashMovement] = []
    issues: list[dict] = []
    anchor = sheet_month_anchor(sheet_name)
    current: date | None = None
    shift_flags: list[str] = []  # aplican a todas las filas que heredan la fecha
    out_of_window = False

    for idx in range(cols.data_start, len(rows)):
        row = rows[idx]
        source_row = idx + 1
        if _is_template_row(row, cols):
            continue
        raw_date = _cell(row, cols.date)
        cell_date = parse_date_cell(raw_date)
        if cell_date is not None:
            shift_flags = _date_cell_flags(raw_date)
            # El nombre de la hoja ('Junio 2013') es un dato explícito del
            # archivo: manda sobre el mes escrito si el día encaja.
            anchored = _sheet_anchor_fix(cell_date, current, anchor)
            if anchored is not None:
                cell_date = anchored
                shift_flags.append("date_corrected_to_sheet_month")
            out_of_window = not _in_window(cell_date)
            # La hoja es cronológica: un salto hacia atrás de más de un día es
            # un typo. Si con el mes/año de la fila anterior el día queda en
            # secuencia (plantilla copiada del mes anterior, caso real jun-jul
            # 2015) se corrige; si no, se conserva la fecha escrita y se marca.
            if (anchored is None and current is not None and not out_of_window
                    and (current - cell_date).days > 1):
                fixed = _stale_month_fix(cell_date, current)
                if fixed is not None:
                    cell_date = fixed
                    shift_flags.append("date_month_typo_corrected")
                else:
                    shift_flags.append("date_out_of_sequence")
            current = None if out_of_window else cell_date

        amounts = []
        unparseable = False
        for kind, currency, col in (
            ("income", "BOB", cols.income_bs), ("income", "USD", cols.income_usd),
            ("expense", "BOB", cols.expense_bs), ("expense", "USD", cols.expense_usd),
        ):
            amount, ok = parse_amount(_cell(row, col))
            unparseable |= not ok
            if amount:
                amounts.append((kind, currency, amount))
        if not amounts and not unparseable:
            continue

        def issue(reason: str) -> None:
            issues.append({"source_file": source_file, "sheet_name": sheet_name,
                           "source_row": source_row, "reason": reason})

        if unparseable:
            issue("unparseable_amount")
            continue
        if out_of_window:
            issue("date_out_of_window")
            continue
        if current is None:
            issue("no_date")
            continue

        row_flags = list(cols.flags) + shift_flags
        if cell_date is None and _text(raw_date) is not None:
            row_flags.append("date_inherited_over_unparsed_cell")
        for kind, currency, amount in amounts:
            flags = row_flags + (["negative_amount"] if amount < 0 else [])
            movements.append(CashMovement(
                movement_date=current,
                kind=kind,
                currency=currency,
                amount=amount,
                concept=_text(_cell(row, cols.detail)),
                receipt_ref=_text(_cell(row, cols.income_ref if kind == "income" else cols.expense_ref)),
                receptionist=_text(_cell(row, cols.receptionist)),
                observations=_text(_cell(row, cols.observations)),
                source_file=source_file,
                sheet_name=sheet_name,
                source_row=source_row,
                quality_flags=";".join(flags),
            ))
    return movements, issues


def _read_xls_sheets_with_dates(path: Path) -> list[tuple[str, list[list]]]:
    """Como guest_nights._read_xls_sheets, pero las celdas de fecha salen como
    datetime (allá no hacían falta; acá la fecha es por fila)."""
    import xlrd

    wb = xlrd.open_workbook(str(path))
    sheets = []
    for ws in wb.sheets():
        rows = []
        for r in range(ws.nrows):
            row = []
            for c in range(ws.ncols):
                cell = ws.cell(r, c)
                if cell.ctype == xlrd.XL_CELL_DATE:
                    try:
                        row.append(datetime(*xlrd.xldate_as_tuple(cell.value, wb.datemode)))
                    except (ValueError, xlrd.xldate.XLDateError):
                        row.append(cell.value)
                else:
                    row.append(cell.value)
            rows.append(row)
        sheets.append((ws.name, rows))
    return sheets


def parse_workbook(hotel_root: Path, rel_path: str) -> tuple[list[CashMovement], list[dict]]:
    path = hotel_root / rel_path
    reader = _read_xls_sheets_with_dates if path.suffix.lower() == ".xls" else _read_xlsx_sheets
    movements: list[CashMovement] = []
    issues: list[dict] = []
    for sheet_name, rows in reader(path):
        m, i = extract_cash_movements(rows, source_file=rel_path, sheet_name=sheet_name)
        movements.extend(m)
        issues.extend(i)
    return movements, issues
