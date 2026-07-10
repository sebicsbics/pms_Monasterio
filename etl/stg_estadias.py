"""
Capa canónica del ETL del hotel: stg_estadias.

Toma los archivos `Lista de Llegadas YYYY.md` (markdown exportado de Excel, con
drift de formato año a año) y produce UNA fila limpia por estadía.

Filosofía: no se descarta lo dudoso en silencio, se ETIQUETA con flags de
calidad. Cada regla de transformación está documentada donde se aplica.

Salida: etl/output/stg_estadias.csv  +  etl/output/stg_estadias_quality.txt
"""

from __future__ import annotations

import csv
import glob
import os
import re
from collections import Counter
from dataclasses import dataclass, field, asdict, fields
from datetime import date, datetime

MD_DIR = os.path.join(os.path.dirname(__file__), "..", "md")
OUT_DIR = os.path.join(os.path.dirname(__file__), "output")

# Índice de columnas por posición. Vale para 2018-2025 (13 cols con header) y
# para 2017 (14 cols sin header): las 12 primeras columnas coinciden en orden,
# 2017 solo agrega columnas basura (Unnamed) al final que ignoramos.
COL = {
    "name": 0, "hab": 1, "pax": 2, "checkin": 3, "checkout": 4,
    "noches": 5, "tarifa": 6, "importe": 7, "consumo": 8,
    "total": 9, "pago": 10, "empresa": 11, "pais": 12,
}

NULL_TOKENS = {"", "nan", "nat", "none", "unnamed", "s/n", "-"}

# Barandas de sanidad. El hotel opera en este rango; fuera de acá es typo crudo.
MIN_YEAR, MAX_YEAR = 2015, 2026
# Estadía hotelera plausible: por encima de esto, la fecha/año está corrupta.
MAX_NIGHTS = 60

# Set cerrado de habitaciones reales del hotel: 1-37 sin la 13 (no existe).
# Fuente: DETALLE_DE_HABITACIONES.md / seed_rooms. Un número fuera de acá es
# typo o un monto que se coló en la columna de habitación.
VALID_ROOMS = frozenset(set(range(1, 38)) - {13})

# Normalización de formas de pago. Los datos crudos tienen ~100 variantes
# (typos, combos, sinónimos). Cada método canónico se detecta por una lista de
# patrones-substring, en orden de prioridad. Si aparece más de un método en la
# misma celda -> "MIXTO" (pago combinado, es una categoría legítima).
PAGO_PATTERNS: list[tuple[str, tuple[str, ...]]] = [
    ("CORTESIA", ("FREE", "GRATIS", "CORTESIA", "LIBERADA", "AUSPICIO", "VOUCHER")),
    ("CTAS_POR_COBRAR", ("CXC", "CTAS POR COBRAR", "C/C", "POR COBRAR", "COBRAR")),
    ("TRANSFERENCIA", ("TRANSFER", "TRANFER")),  # TRANFERENCIA es typo común
    ("DEPOSITO", ("DEPOSIT", "DEPÓSIT", "DEPO", "DEP/", "/DEP", "DEP-", "DEP ")),
    ("QR", ("QR",)),
    ("AIRBNB", ("AIR BNB", "AIRBNB")),
    ("INTERCAMBIO", ("INTERCAMBIO", "CONVENIO")),
    ("TARJETA", ("TARJETA", "ATC", "TARJE")),
    # EFECTIVO al final: es el más común y muchos typos (ERECTIVO, EJECTIVO...).
    ("EFECTIVO", ("EFECTIVO", "EFEC", "CASH", "EFETIVO", "ERECTIVO",
                  "EJECTIVO", "EN EFECTIVO", "DOLAR", "PAGADO", "PAGARON")),
]


def normalize_payment(raw: str) -> str | None:
    """Colapsa la cola larga de formas de pago a un catálogo canónico."""
    s = raw.upper().strip()
    # Ruido: vacío, headers filtrados, o un MONTO que se coló por desalineación.
    if not s or "UNNAMED" in s or "FORMA PAGO" in s or s == "T/PAGO":
        return None
    if parse_num(s) is not None:  # un número no es una forma de pago
        return None
    found: list[str] = []
    for canon, pats in PAGO_PATTERNS:
        if any(p in s for p in pats) and canon not in found:
            found.append(canon)
    if not found:
        return "OTRO"
    return "MIXTO" if len(found) > 1 else found[0]


def is_null(s: str | None) -> bool:
    return s is None or s.strip().lower() in NULL_TOKENS


def clean_str(s: str | None) -> str | None:
    if is_null(s):
        return None
    return re.sub(r"\s+", " ", s).strip()


def parse_num(s: str | None) -> float | None:
    if is_null(s):
        return None
    s = s.strip().replace(",", "")
    try:
        return float(s)
    except ValueError:
        return None


def parse_date(s: str | None) -> date | None:
    if is_null(s):
        return None
    token = s.strip().split(" ")[0]
    for fmt in ("%Y-%m-%d", "%d/%m/%Y", "%Y/%m/%d", "%d-%m-%Y"):
        try:
            return datetime.strptime(token, fmt).date()
        except ValueError:
            continue
    return None


@dataclass
class Estadia:
    source_file: str
    row_num: int
    file_year: int | None
    guest_name: str | None
    room: int | None
    pax: int | None
    check_in: date | None
    check_out: date | None
    nights: int | None
    rate_bs: float | None       # tarifa por noche
    total_bs: float | None      # importe total de la estadía
    total_source: str           # "reported" | "recomputed" | "missing"
    payment: str | None
    channel: str | None         # empresa / canal de venta
    country: str | None
    is_multi_guest: bool = False
    quality_flags: list[str] = field(default_factory=list)

    def flag(self, f: str) -> None:
        self.quality_flags.append(f)


def _is_separator(cells: list[str]) -> bool:
    return all(set(c.strip()) <= set("-: ") for c in cells)


def _is_header(cells: list[str]) -> bool:
    joined = " ".join(cells).lower()
    return "nombre" in joined and ("check" in joined or "hab" in joined)


def extract(path: str) -> list[list[str]]:
    """Devuelve las filas de datos (listas de celdas) de un archivo md."""
    rows: list[list[str]] = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if not line.startswith("|"):
                continue
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if _is_separator(cells) or _is_header(cells):
                continue
            rows.append(cells)
    return rows


def transform_row(cells: list[str], src: str, row_num: int,
                  file_year: int | None) -> Estadia | None:
    def g(key: str) -> str | None:
        i = COL[key]
        return cells[i] if i < len(cells) else None

    name = clean_str(g("name"))
    check_in = parse_date(g("checkin"))
    check_out = parse_date(g("checkout"))

    # Regla 1: fila basura = sin nombre y sin ninguna fecha -> se descarta.
    if name is None and check_in is None and check_out is None:
        return None

    # Regla 0: baranda de fechas. Fuera del rango operativo del hotel es typo
    # crudo (1900, 5025, 2027) -> se anula la fecha, no se adivina.
    out_of_range = False
    if check_in and not (MIN_YEAR <= check_in.year <= MAX_YEAR):
        check_in, out_of_range = None, True
    if check_out and not (MIN_YEAR <= check_out.year <= MAX_YEAR):
        check_out, out_of_range = None, True

    e = Estadia(
        source_file=os.path.basename(src), row_num=row_num, file_year=file_year,
        guest_name=name,
        room=int(parse_num(g("hab"))) if parse_num(g("hab")) is not None else None,
        pax=int(parse_num(g("pax"))) if parse_num(g("pax")) is not None else None,
        check_in=check_in, check_out=check_out, nights=None,
        rate_bs=parse_num(g("tarifa")), total_bs=None, total_source="missing",
        payment=None, channel=clean_str(g("empresa")), country=clean_str(g("pais")),
    )
    if out_of_range:
        e.flag("date_out_of_range")

    # Regla 2: corregir typo de año en checkout (checkout < checkin por ~1 año).
    # Solo se acepta si el resultado da una estadía plausible; si genera algo
    # como "335 noches", la corrección es peor que el problema -> se descarta la fecha.
    if check_in and check_out and check_out < check_in:
        try:
            fixed = check_out.replace(year=check_in.year)
            if fixed < check_in:
                fixed = fixed.replace(year=check_in.year + 1)
            if 0 <= (fixed - check_in).days <= MAX_NIGHTS:
                e.check_out, check_out = fixed, fixed
                e.flag("checkout_year_fixed")
            else:
                e.check_out, check_out = None, None
                e.flag("checkout_unrecoverable")
        except ValueError:
            e.flag("checkout_before_checkin")

    # Regla 3: noches SIEMPRE se recalcula desde fechas (el valor guardado se
    # corrompe con checkout vacío -> serial de fecha de Excel). Mismo día = 1.
    noches_raw = parse_num(g("noches"))
    if check_in and check_out and check_out >= check_in:
        nights = (check_out - check_in).days or 1
        if nights <= MAX_NIGHTS:
            e.nights = nights
        else:
            e.flag("stay_too_long")  # implausible: no se confía, se deja sin noches
    elif noches_raw is not None and 0 < noches_raw <= MAX_NIGHTS:
        e.nights = int(noches_raw)
        e.flag("nights_from_reported")
    else:
        e.flag("nights_unknown")

    # Regla 4: total. Se usa el reportado solo si es plausible (0..100k), si no
    # se reconstruye como tarifa * noches. La cascada de Excel deja negativos/millones.
    total_raw = parse_num(g("total"))
    if total_raw is not None and 0 <= total_raw <= 100_000:
        e.total_bs, e.total_source = total_raw, "reported"
    elif e.rate_bs and 0 <= e.rate_bs <= 100_000 and e.nights:
        e.total_bs, e.total_source = round(e.rate_bs * e.nights, 2), "recomputed"
        e.flag("total_recomputed")
    else:
        e.flag("total_missing")

    if e.total_bs == 0:
        e.flag("courtesy_or_zero")

    # Regla 5: normalizar forma de pago contra catálogo canónico.
    pago = clean_str(g("pago"))
    if pago:
        e.payment = normalize_payment(pago)
    if e.payment is None:
        e.flag("payment_missing")

    # Regla 6: normalizar país / detectar multi-huésped.
    if e.country:
        e.country = e.country.upper()
    else:
        e.flag("country_missing")
    if name and ("," in name or "/" in name):
        e.is_multi_guest = True
        e.flag("multi_guest")

    # Regla 7: la habitación debe existir en el set real del hotel. Si no, es un
    # typo o un monto que se coló -> se marca para no atribuirle ingreso/ocupación.
    if e.room is not None and e.room not in VALID_ROOMS:
        e.flag("room_invalid")

    return e


def run() -> None:
    files = [f for f in glob.glob(os.path.join(MD_DIR, "*.md"))
             if re.search(r"legadas", os.path.basename(f), re.I)
             and not f.endswith("Zone.Identifier")]
    files.sort()

    estadias: list[Estadia] = []
    for path in files:
        ym = re.search(r"(20\d\d)", os.path.basename(path))
        file_year = int(ym.group(1)) if ym else None
        for i, cells in enumerate(extract(path), start=1):
            e = transform_row(cells, path, i, file_year)
            if e is not None:
                estadias.append(e)

    os.makedirs(OUT_DIR, exist_ok=True)
    csv_path = os.path.join(OUT_DIR, "stg_estadias.csv")
    cols = [f.name for f in fields(Estadia)]
    with open(csv_path, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(cols)
        for e in estadias:
            d = asdict(e)
            d["quality_flags"] = "|".join(e.quality_flags)
            w.writerow([d[c] for c in cols])

    _write_quality_report(estadias)
    print(f"OK -> {csv_path}  ({len(estadias):,} estadías)")


def _write_quality_report(estadias: list[Estadia]) -> None:
    n = len(estadias)
    flags = Counter(f for e in estadias for f in e.quality_flags)
    src = Counter(e.total_source for e in estadias)
    revenue = sum(e.total_bs or 0 for e in estadias)
    lines = [
        "REPORTE DE CALIDAD - stg_estadias",
        "=" * 40,
        f"estadías totales: {n:,}",
        f"ingreso total (Bs): {revenue:,.0f}",
        f"origen del total: {dict(src)}",
        "",
        "flags de calidad (fila puede tener varios):",
    ]
    for flag, c in flags.most_common():
        lines.append(f"  {c:>6,} ({100*c/n:4.1f}%)  {flag}")
    report = "\n".join(lines)
    with open(os.path.join(OUT_DIR, "stg_estadias_quality.txt"), "w", encoding="utf-8") as fh:
        fh.write(report + "\n")
    print("\n" + report)


if __name__ == "__main__":
    run()
