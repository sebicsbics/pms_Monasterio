"""Extractor de NOCHES de huéspedes (`Hotel/`, ~2013-2019).

Workbooks ACUMULATIVOS (una hoja/noche, copiadas de un libro al siguiente):
la noche se repite entre archivos, muchas hojas sin mes. El nombre de archivo
NO es una fuente confiable del año (los libros se siguieron llenando durante
años después de su nombre nominal).

Cada hoja se fecha resolviendo un ANCLA firme (la primera hoja de la
secuencia con día+mes explícitos, usando el weekday declarado —si lo hay—
para desambiguar el año entre los candidatos de esa combinación día/mes
dentro de la ventana plausible [2012-01-01, 2017-12-31]) y propagando esa
ancla hacia atrás y hacia adelante en el orden del libro, con saltos acotados
(<=45 días) entre hojas consecutivas. El weekday declarado es una AYUDA de
desambiguación, no solo una validación: cuando hay varios candidatos de
calendario posibles para una hoja, se prefiere el que coincide con el
weekday declarado; si ninguno coincide, se conserva el mejor candidato por
fecha y se marca `weekday_mismatch`. Sin deduplicar entre archivos (eso es
2b): `etl/output/stg_guest_nights.csv`.
"""
from __future__ import annotations

import csv, difflib, json, os, re
from dataclasses import asdict, dataclass, field, fields
from datetime import date
from pathlib import Path

from etl.stg_estadias import normalize_payment

ETL_DIR = Path(__file__).resolve().parent.parent
OUT_DIR = ETL_DIR / "output"
HOTEL_ROOT = ETL_DIR.parent / "Hotel"

MONTHS = {
    "enero": 1, "febrero": 2, "marzo": 3, "abril": 4, "mayo": 5, "junio": 6,
    "julio": 7, "agosto": 8, "septiembre": 9, "setiembre": 9, "octubre": 10,
    "noviembre": 11, "diciembre": 12,
}
_MONTH_ABBR = {
    "ene": 1, "feb": 2, "mar": 3, "abr": 4, "may": 5, "jun": 6,
    "jul": 7, "ago": 8, "sep": 9, "set": 9, "oct": 10, "nov": 11, "dic": 12,
}
# lunes=0 .. domingo=6, igual que date.weekday()
WEEKDAYS = ["lunes", "martes", "miercoles", "jueves", "viernes", "sabado", "domingo"]
_HOJA_TEMPLATE_RE = re.compile(r"^hoja\s*\d*$")

def _strip_accents_lower(text: str) -> str:
    import unicodedata
    normalized = unicodedata.normalize("NFKD", str(text))
    return "".join(ch for ch in normalized if not unicodedata.combining(ch)).lower()

def _month_from_token(tok: str) -> int | None:
    return MONTHS.get(tok) or _MONTH_ABBR.get(tok[:3])

_DIGIT_RE = re.compile(r"\d{1,2}")
_ALPHA_RE = re.compile(r"[a-z]+")

def _match_weekday(tok: str) -> int | None:
    """Matchea el token contra WEEKDAYS, tolerando typos frecuentes del archivo
    ('Domigno', 'Doomingo', 'dOMINGO' -> ya normalizado a minúsculas acá)."""
    if tok in WEEKDAYS:
        return WEEKDAYS.index(tok)
    if len(tok) >= 5:
        close = difflib.get_close_matches(tok, WEEKDAYS, n=1, cutoff=0.75)
        if close:
            return WEEKDAYS.index(close[0])
    return None

def _parse_sheet_tokens(sheet_name: str) -> tuple[int | None, int | None, int | None]:
    """Devuelve (día, mes_explícito, weekday_declarado) sin resolver la fecha."""
    norm = _strip_accents_lower(sheet_name).strip()
    if _HOJA_TEMPLATE_RE.match(norm):
        return None, None, None
    digit_m = _DIGIT_RE.search(norm)
    day = int(digit_m.group(0)) if digit_m else None
    month = None
    weekday = None
    tokens = _ALPHA_RE.findall(norm)
    weekday_tokens: set[str] = set()
    for tok in tokens:
        wd = _match_weekday(tok)
        if wd is not None:
            weekday = wd
            weekday_tokens.add(tok)
    for tok in tokens:
        if tok in weekday_tokens:
            continue  # evita que el prefijo de un día de semana matchee un mes (martes ~ mar)
        if month is None:
            month = _month_from_token(tok)
    return day, month, weekday

# Ventana plausible del archivo completo (el hotel cambió de sistema ~2017;
# los nombres de archivo por sí solos NO son confiables como año).
_WINDOW_START = date(2012, 1, 1)
_WINDOW_END = date(2017, 12, 31)
_MAX_GAP_DAYS = 45

def _day_month_candidates(day: int, month: int | None) -> list[date]:
    """Fechas de calendario válidas con ese día (y mes, si se conoce) en la ventana."""
    candidates: list[date] = []
    months = [month] if month else range(1, 13)
    for year in range(_WINDOW_START.year, _WINDOW_END.year + 1):
        for m in months:
            try:
                d = date(year, m, day)
            except ValueError:
                continue
            if _WINDOW_START <= d <= _WINDOW_END:
                candidates.append(d)
    return sorted(candidates)

def _filter_by_weekday(candidates: list[date], weekday: int | None) -> tuple[list[date], bool]:
    """Si algún candidato coincide con el weekday declarado, se queda solo con
    esos (desambiguación); si no hay coincidencia, degrada a todos los
    candidatos y señala que habrá que marcar `weekday_mismatch`."""
    if weekday is None:
        return candidates, False
    matches = [d for d in candidates if d.weekday() == weekday]
    if matches:
        return matches, False
    return candidates, True

def _pick_anchor(candidates: list[date], hint_year: int | None) -> date:
    """Elige el candidato ANCLA. `hint_year` es el año declarado en el
    NOMBRE del archivo (ver `process_workbook`); el docstring del módulo ya
    advierte que el nombre de archivo NO es confiable (los libros son
    acumulativos y se siguieron llenando años después de su nombre nominal).
    Por eso `hint_year` se usa solo como DESEMPATE DE ÚLTIMA INSTANCIA
    cuando el weekday declarado no alcanza para elegir entre varios
    candidatos día/mes igualmente válidos dentro de la ventana -- es una
    excepción aceptada explícitamente (no una fuente de verdad), documentada
    acá porque es la única función que todavía consulta el año del nombre
    de archivo."""
    if hint_year is not None:
        exact = [d for d in candidates if d.year == hint_year]
        if exact:
            return exact[0]
        return min(candidates, key=lambda d: abs(d.year - hint_year))
    return candidates[0]

def _pick_nearest(
    candidates: list[date], ref_date: date, weekday: int | None, prefer_forward: bool
) -> tuple[date | None, bool]:
    """Candidato más cercano a `ref_date` dentro del salto máximo permitido
    (o, si ninguno cae en esa ventana, el más cercano de todo el rango). El
    weekday declarado desambigua ENTRE esos candidatos locales, sin permitir
    saltar de año. No exige que la fecha avance monótonamente: las hojas
    reales a veces están fuera de orden (se insertaron días salteados), y
    forzar solo-adelante producía falsos `weekday_mismatch`; en empates de
    distancia se prefiere la dirección `prefer_forward` para no perder el
    sentido general de avance del libro."""
    if not candidates:
        return None, False
    within_gap = [d for d in candidates if abs((d - ref_date).days) <= _MAX_GAP_DAYS]
    pool = within_gap or candidates

    def sort_key(d: date):
        distance = abs((d - ref_date).days)
        tie_break = 0 if (d >= ref_date) == prefer_forward else 1
        return (distance, tie_break)

    if weekday is None:
        return min(pool, key=sort_key), False
    matches = [d for d in pool if d.weekday() == weekday]
    if matches:
        return min(matches, key=sort_key), False
    return min(pool, key=sort_key), True

def sequential_sheet_dates(
    sheet_names: list[str], initial_year: int | None, initial_month: int | None
) -> tuple[list[date | None], list[set[str]]]:
    """Fecha cada hoja resolviendo un ancla firme y propagándola en ambas
    direcciones de la secuencia del libro; ver docstring del módulo."""
    parsed = [_parse_sheet_tokens(name) for name in sheet_names]
    n = len(parsed)
    dated: list[date | None] = [None] * n
    flags: list[set[str]] = [set() for _ in range(n)]

    anchor_idx = next(
        (i for i, (day, month, _wd) in enumerate(parsed) if day is not None and month is not None),
        None,
    )
    if anchor_idx is None:
        for i in range(n):
            flags[i] = {"date_unknown"}
        return dated, flags

    def _resolve(day: int, month: int | None, weekday: int | None, hint_year: int | None) -> tuple[date | None, bool]:
        candidates = _day_month_candidates(day, month)
        if not candidates:
            return None, False
        filtered, mismatch = _filter_by_weekday(candidates, weekday)
        return _pick_anchor(filtered, hint_year), mismatch

    day, month, weekday = parsed[anchor_idx]
    anchor_date, mismatch = _resolve(day, month, weekday, initial_year)
    if anchor_date is None:
        flags[anchor_idx] = {"date_unknown"}
    else:
        dated[anchor_idx] = anchor_date
        if mismatch and weekday is not None and anchor_date.weekday() != weekday:
            flags[anchor_idx].add("weekday_mismatch")

    if anchor_date is not None:
        next_date = anchor_date
        for i in range(anchor_idx - 1, -1, -1):
            day, month, weekday = parsed[i]
            if day is None:
                flags[i].add("date_unknown")
                continue
            candidates = _day_month_candidates(day, month)
            picked, mismatch = _pick_nearest(candidates, next_date, weekday, prefer_forward=False)
            if picked is None:
                flags[i].add("date_unknown")
                continue
            if mismatch:
                flags[i].add("weekday_mismatch")
            dated[i] = picked
            next_date = picked

        prev_date = anchor_date
        for i in range(anchor_idx + 1, n):
            day, month, weekday = parsed[i]
            if day is None:
                flags[i].add("date_unknown")
                continue
            candidates = _day_month_candidates(day, month)
            picked, mismatch = _pick_nearest(candidates, prev_date, weekday, prefer_forward=True)
            if picked is None:
                flags[i].add("date_unknown")
                continue
            if mismatch:
                flags[i].add("weekday_mismatch")
            dated[i] = picked
            prev_date = picked

    return dated, flags

def find_header_row(rows: list[list]) -> int | None:
    for i, row in enumerate(rows):
        joined = " ".join(_strip_accents_lower(c) for c in row if c is not None)
        if "nombre" in joined:
            return i
    return None

_COLUMN_KEYWORDS: list[tuple[str, tuple[str, ...]]] = [
    ("name", ("nombre",)),
    ("company", ("empresa",)),
    ("nationality", ("nacional",)),
    ("pax", ("pax",)),
    ("rate", ("tarifa",)),
    ("payment", ("forma de pago", "forma pago", "pago")),
    ("room", ("habitacion", "hab.", "nro", "no.", "n°", "no", "num")),
]

def detect_columns(header_row: list) -> dict[str, int]:
    cols: dict[str, int] = {}
    for i, cell in enumerate(header_row):
        if cell is None:
            continue
        norm = _strip_accents_lower(cell).strip()
        if not norm:
            continue
        for key, keywords in _COLUMN_KEYWORDS:
            if key in cols:
                continue
            if any(kw in norm for kw in keywords):
                cols[key] = i
                break
    if "room" not in cols:
        cols["room"] = 0
    return cols

def _to_int(v):
    try:
        return int(float(v)) if v is not None else None
    except (ValueError, TypeError):
        return None

def _to_float(v):
    try:
        return float(v) if v is not None else None
    except (ValueError, TypeError):
        return None

def _to_str(v):
    return (str(v).strip() or None) if v is not None else None

@dataclass
class NightObservation:
    night_date: date
    room: int | None
    guest_name: str
    pax: int | None
    rate: float | None
    payment: str | None
    company: str | None
    country: str | None
    source_file: str
    sheet_name: str
    sheet_index: int
    quality_flags: list[str] = field(default_factory=list)

def extract_night_observations(
    rows: list[list], header_idx: int, night_date: date | None, sheet_name: str,
    sheet_index: int, source_file: str, flags: set[str],
) -> list[NightObservation]:
    """Una `NightObservation` por fila ocupada (con nombre) bajo el header."""
    col_map = detect_columns(rows[header_idx])
    obs: list[NightObservation] = []

    def g(row: list, key: str):
        idx = col_map.get(key)
        if idx is None or idx >= len(row):
            return None
        return row[idx]

    for row in rows[header_idx + 1:]:
        name = _to_str(g(row, "name"))
        if not name:
            continue
        row_flags = list(flags)
        payment_raw = _to_str(g(row, "payment"))
        obs.append(NightObservation(
            night_date=night_date, room=_to_int(g(row, "room")), guest_name=name,
            pax=_to_int(g(row, "pax")), rate=_to_float(g(row, "rate")),
            payment=normalize_payment(payment_raw) if payment_raw else None,
            company=_to_str(g(row, "company")), country=_to_str(g(row, "nationality")),
            source_file=source_file, sheet_name=sheet_name, sheet_index=sheet_index,
            quality_flags=row_flags,
        ))
    return obs

def capacity_violations(observations: list[NightObservation]) -> list[tuple[str, date, int]]:
    """(source_file, date, count) para fechas con más de 36 habitaciones ocupadas."""
    by_key: dict[tuple[str, date], set[int]] = {}
    for o in observations:
        if o.night_date is None or o.room is None:
            continue
        by_key.setdefault((o.source_file, o.night_date), set()).add(o.room)
    return sorted(
        (src, d, len(rooms)) for (src, d), rooms in by_key.items() if len(rooms) > 36
    )

def _read_xlsx_sheets(path: Path) -> list[tuple[str, list[list]]]:
    import openpyxl
    wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
    sheets = []
    for name in wb.sheetnames:
        ws = wb[name]
        if not hasattr(ws, "iter_rows"):
            continue
        sheets.append((name, [list(row) for row in ws.iter_rows(values_only=True)]))
    return sheets

def _read_xls_sheets(path: Path) -> list[tuple[str, list[list]]]:
    import xlrd
    wb = xlrd.open_workbook(str(path))
    return [(ws.name, [ws.row_values(r) for r in range(ws.nrows)]) for ws in wb.sheets()]

_FILENAME_YEAR_RE = re.compile(r"(20\d\d)")

def process_workbook(path: Path, inventory_year: int | None = None) -> list[NightObservation]:
    suffix = path.suffix.lower()
    if suffix == ".xlsx":
        sheets = _read_xlsx_sheets(path)
    elif suffix == ".xls":
        sheets = _read_xls_sheets(path)
    else:
        return []

    year_m = _FILENAME_YEAR_RE.search(path.name)
    initial_year = int(year_m.group(1)) if year_m else inventory_year

    sheet_names = [name for name, _rows in sheets]
    dated, flag_sets = sequential_sheet_dates(sheet_names, initial_year, None)

    observations: list[NightObservation] = []
    for i, (name, rows) in enumerate(sheets):
        header_idx = find_header_row(rows)
        if header_idx is None:
            continue
        observations.extend(extract_night_observations(
            rows, header_idx, dated[i], name, i, path.name, flag_sets[i],
        ))
    return observations

_EXCLUDED_FAMILY_KEYWORDS = ("movimientos diarios",)

def _is_guest_register_path(rel_path: str) -> bool:
    """El nombre de ARCHIVO (no la carpeta) debe declarar que es un registro
    de huéspedes. Algunas carpetas se llaman 'HUESPEDES' pero contienen otra
    familia de archivos (ej. 'MOVIMIENTOS DIARIOS...xls') que hay que excluir
    explícitamente aunque vivan bajo esa carpeta."""
    filename = _strip_accents_lower(Path(rel_path).name)
    if any(kw in filename for kw in _EXCLUDED_FAMILY_KEYWORDS):
        return False
    return "huesp" in filename or "registro de hu" in filename

OBS_COLUMNS = [f.name for f in fields(NightObservation)]

def run() -> None:
    inventory_path = OUT_DIR / "inventory.json"
    if not inventory_path.exists():
        raise SystemExit(f"No existe {inventory_path} — correr primero el extractor (PR1)")

    inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
    canonical = [r for r in inventory if r["is_canonical"]]
    candidates = [r for r in canonical if _is_guest_register_path(r["path"])]
    excluded_wrong_family = [
        r["path"] for r in canonical
        if any(kw in _strip_accents_lower(Path(r["path"]).name) for kw in _EXCLUDED_FAMILY_KEYWORDS)
    ]

    all_obs: list[NightObservation] = []
    unparsed: list[str] = []
    for rec in candidates:
        path = HOTEL_ROOT / rec["path"]
        if path.suffix.lower() not in (".xlsx", ".xls"):
            unparsed.append(rec["path"])
            continue
        try:
            obs = process_workbook(path, inventory_year=rec.get("year"))
        except Exception as exc:  # noqa: BLE001
            unparsed.append(f"{rec['path']} ({exc})")
            continue
        if not obs:
            unparsed.append(rec["path"])
            continue
        all_obs.extend(obs)

    os.makedirs(OUT_DIR, exist_ok=True)
    csv_path = OUT_DIR / "stg_guest_nights.csv"
    with open(csv_path, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(OBS_COLUMNS)
        for o in all_obs:
            d = asdict(o)
            d["quality_flags"] = "|".join(o.quality_flags)
            w.writerow([d[c] for c in OBS_COLUMNS])

    violations = capacity_violations(all_obs)
    dated = [o for o in all_obs if o.night_date is not None]
    by_year: dict[int, int] = {}
    for o in dated:
        by_year[o.night_date.year] = by_year.get(o.night_date.year, 0) + 1
    weekday_mismatch = sum(1 for o in all_obs if "weekday_mismatch" in o.quality_flags)
    pct_unknown = 100 * (len(all_obs) - len(dated)) / len(all_obs) if all_obs else 0

    by_file: dict[str, list[NightObservation]] = {}
    for o in all_obs:
        by_file.setdefault(o.source_file, []).append(o)

    print(f"OK -> {csv_path}  ({len(all_obs):,} observaciones de noche)")
    print(f"Archivos excluidos por familia incorrecta (ej. 'movimientos diarios'): {len(excluded_wrong_family)}: {excluded_wrong_family}")
    print(f"Archivos sin filas parseables: {len(unparsed)}: {unparsed}")
    print(f"% date_unknown: {pct_unknown:.1f}%  weekday_mismatch: {weekday_mismatch} ({100 * weekday_mismatch / len(all_obs):.1f}%)" if all_obs else "Sin observaciones")
    print(f"Noches por año: {dict(sorted(by_year.items()))}")
    print("Peores archivos por % weekday_mismatch:")
    per_file_stats = sorted(
        (
            (
                src,
                100 * sum(1 for o in obs if "weekday_mismatch" in o.quality_flags) / len(obs),
                min((o.night_date for o in obs if o.night_date), default=None),
                max((o.night_date for o in obs if o.night_date), default=None),
            )
            for src, obs in by_file.items()
        ),
        key=lambda t: t[1], reverse=True,
    )
    for src, pct, dmin, dmax in per_file_stats[:10]:
        print(f"  - {src}: {pct:.1f}% mismatch, rango {dmin} .. {dmax}")
    print(f"Violaciones de capacidad (>36 hab. mismo día, mismo archivo): {len(violations)}")
    for src, d, n in violations[:20]:
        print(f"  - {src} {d}: {n} habitaciones")

if __name__ == "__main__":
    run()
