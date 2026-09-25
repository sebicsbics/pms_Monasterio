"""Dedupe de noches entre archivos + fusión en estadías.

Los workbooks son acumulativos (`guest_nights.py`): la misma noche aparece en
varios archivos. Acá se resuelve UNA observación por (night_date, room),
prefiriendo el archivo cuyo mes nominal (del nombre) coincide con la noche;
si ninguno coincide, el archivo "más tardío" (mes nominal mayor); empate por
ruta. Las descartadas van a `etl/output/night_dedupe_report.csv`. Sobre las
noches ya dedupeadas se separan los placeholders de ESTADO de habitación
(bloqueada, por habilitar, en depósito, ocupada sin nombre -- ver
`etl/parsers/room_blocks.py`) hacia `etl/output/stg_room_blocks.csv`; no son
estadías reales. Con las noches restantes se fusionan noches consecutivas de
(room, guest) en estadías, igual criterio que la Slice 2 original: corte por
hueco/cambio de huésped, flag `room_change`; `rate_varies` si la tarifa
cambia entre noches de la misma estadía (se toma igual la tarifa de la
primera noche).

Salida: `etl/output/stg_estadias_archive.csv` (mismas columnas que hoy) +
`etl/output/night_dedupe_report.csv` + `etl/output/stg_room_blocks.csv`.
"""
from __future__ import annotations

import csv, json, os, re
from dataclasses import asdict, dataclass, field, fields
from datetime import date, timedelta
from pathlib import Path

from collections import Counter

from etl.parsers.guest_nights import NightObservation, MONTHS, _MONTH_ABBR
from etl.parsers.room_blocks import BLOCK_COLUMNS, split_room_blocks
from etl.stg_estadias import VALID_ROOMS, normalize_payment

ETL_DIR = Path(__file__).resolve().parent.parent
OUT_DIR = ETL_DIR / "output"


def _strip_accents_lower(text: str) -> str:
    import unicodedata
    normalized = unicodedata.normalize("NFKD", str(text))
    return "".join(ch for ch in normalized if not unicodedata.combining(ch)).lower()


def _nominal_month(source_file: str) -> int | None:
    """Mes que el NOMBRE del archivo declara (ej. 'HUESPEDES ABRIL 2016.xls' -> 4)."""
    norm = _strip_accents_lower(source_file)
    for tok in re.findall(r"[a-z]+", norm):
        m = MONTHS.get(tok) or _MONTH_ABBR.get(tok[:3])
        if m:
            return m
    return None


def normalize_guest_key(name: str) -> str:
    return re.sub(r"\s+", " ", _strip_accents_lower(name or "")).strip()


def dedupe_nights(observations: list[NightObservation]) -> tuple[list[NightObservation], list[dict]]:
    """Una observación por (night_date, room). Ver docstring del módulo."""
    groups: dict[tuple, list[NightObservation]] = {}
    for o in observations:
        groups.setdefault((o.night_date, o.room), []).append(o)

    kept: list[NightObservation] = []
    report: list[dict] = []
    for (night_date, room), group in groups.items():
        if len(group) == 1:
            kept.append(group[0])
            continue

        def rank(o: NightObservation):
            nominal = _nominal_month(o.source_file)
            month_match = 1 if nominal == night_date.month else 0
            return (month_match, nominal or 0, o.source_file)

        winner = max(group, key=rank)
        kept.append(winner)
        winner_key = normalize_guest_key(winner.guest_name)
        for o in group:
            if o is winner:
                continue
            conflict = normalize_guest_key(o.guest_name) != winner_key
            report.append({
                "night_date": night_date, "room": room,
                "kept_source": winner.source_file, "kept_guest": winner.guest_name,
                "discarded_source": o.source_file, "discarded_guest": o.guest_name,
                "night_conflict": conflict,
            })
    return kept, report


@dataclass
class Stay:
    guest_name: str
    room: int | None
    pax: int | None
    check_in: date | None
    check_out: date | None
    nights: int | None
    rate_bs: float | None
    total_bs: float | None
    total_source: str
    payment: str | None
    channel: str | None
    country: str | None
    is_multi_guest: bool
    source_file: str
    quality_flags: list[str] = field(default_factory=list)

    def flag(self, f: str) -> None:
        if f not in self.quality_flags:
            self.quality_flags.append(f)


def _stay_from_nights(recs: list[NightObservation]) -> Stay:
    first = recs[0]
    n = len(recs)
    rate = first.rate
    total = round(rate * n, 2) if rate else None
    payment = normalize_payment(first.payment) if isinstance(first.payment, str) else first.payment
    is_multi = bool(first.guest_name and ("," in first.guest_name or "/" in first.guest_name))
    s = Stay(
        guest_name=first.guest_name, room=first.room, pax=first.pax,
        check_in=first.night_date, check_out=recs[-1].night_date + timedelta(days=1),
        nights=n, rate_bs=rate, total_bs=total,
        total_source="recomputed" if total is not None else "missing",
        payment=payment, channel=first.company,
        country=first.country.upper() if first.country else None,
        is_multi_guest=is_multi, source_file=first.source_file,
    )
    if payment is None:
        s.flag("payment_missing")
    # `rate_bs`/`total_bs` siempre toman la tarifa de la PRIMERA noche (no
    # se promedia ni se recalcula por noche); `rate_varies` solo advierte
    # que hubo más de una tarifa no-nula entre las noches de la estadía.
    non_null_rates = {r.rate for r in recs if r.rate is not None}
    if len(non_null_rates) > 1:
        s.flag("rate_varies")
    return s


def merge_nights_into_stays(nights: list[NightObservation]) -> list[Stay]:
    """Fusiona noches consecutivas de (room, guest normalizado) en estadías.

    Corta ante hueco o cambio de huésped en la habitación. Si el mismo
    huésped reaparece en OTRA habitación la noche inmediatamente siguiente
    al cierre de su estadía anterior, la nueva estadía se flaggea
    `room_change` (nunca se fusiona entre habitaciones distintas).
    """
    placeable = sorted(
        (r for r in nights if r.room is not None and r.night_date is not None),
        key=lambda r: (r.night_date, r.room),
    )
    dates = sorted({r.night_date for r in placeable})

    stays: list[Stay] = []
    open_stays: dict[int, list[NightObservation]] = {}
    last_closed: dict[str, tuple[int, date]] = {}

    def close(room: int) -> None:
        recs = open_stays.pop(room)
        stay = _stay_from_nights(recs)
        key = normalize_guest_key(recs[0].guest_name)
        prev = last_closed.get(key)
        if prev is not None:
            prev_room, prev_last = prev
            if prev_room != room and prev_last == recs[0].night_date - timedelta(days=1):
                stay.flag("room_change")
        last_closed[key] = (room, recs[-1].night_date)
        stays.append(stay)

    for d in dates:
        occupied = {r.room: r for r in placeable if r.night_date == d}
        for room in list(open_stays):
            if room not in occupied:
                close(room)
        for room, rec in occupied.items():
            if room in open_stays:
                cur = open_stays[room]
                same_guest = normalize_guest_key(cur[-1].guest_name) == normalize_guest_key(rec.guest_name)
                consecutive = cur[-1].night_date == d - timedelta(days=1)
                if same_guest and consecutive:
                    cur.append(rec)
                    continue
                close(room)
            open_stays[room] = [rec]

    for room in list(open_stays):
        close(room)
    return stays


def invalid_room_stays(stays: list[Stay]) -> list[Stay]:
    """Estadías cuyo número de habitación no pertenece a `VALID_ROOMS`
    (etl/stg_estadias.py). Tras el dedupe por (night_date, room), un guard de
    "<=36 habitaciones ocupadas el mismo día" es tautológico por construcción
    (ya no puede haber dos estadías compitiendo por la misma noche+habitación)
    y no prueba nada sobre el fechado; esta comprobación sí es significativa
    porque detecta números de habitación imposibles que sobrevivieron a la
    fusión."""
    return [s for s in stays if s.room is not None and s.room not in VALID_ROOMS]


def night_conflict_rate(dedupe_report: list[dict]) -> float:
    """% de noches descartadas en el dedupe cuyo huésped difiere del que se
    mantuvo (posible corrupción de datos, no solo duplicado inocuo)."""
    if not dedupe_report:
        return 0.0
    conflicts = sum(1 for r in dedupe_report if r["night_conflict"])
    return 100 * conflicts / len(dedupe_report)


def nights_per_year_report(stays: list[Stay]) -> dict[int, int]:
    """Noches por año del dato final. Es un REPORTE, no una prueba: que el
    total no supere 36 * días del año es un límite físico esperado, pero no
    valida por sí solo que el fechado sea correcto (ver `invalid_room_stays`
    y el `weekday_mismatch` de la Slice 2a para eso)."""
    by_year: dict[int, int] = {}
    for s in stays:
        if s.check_in is None or s.nights is None:
            continue
        by_year[s.check_in.year] = by_year.get(s.check_in.year, 0) + s.nights
    return dict(sorted(by_year.items()))


STAY_COLUMNS = [f.name for f in fields(Stay)]


def run() -> None:
    nights_csv = OUT_DIR / "stg_guest_nights.csv"
    if not nights_csv.exists():
        raise SystemExit(f"No existe {nights_csv} — correr primero guest_nights (Slice 2a)")

    observations: list[NightObservation] = []
    with open(nights_csv, encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            if not row["night_date"]:
                continue
            observations.append(NightObservation(
                night_date=date.fromisoformat(row["night_date"]),
                room=int(row["room"]) if row["room"] else None,
                guest_name=row["guest_name"],
                pax=int(float(row["pax"])) if row["pax"] else None,
                rate=float(row["rate"]) if row["rate"] else None,
                payment=row["payment"] or None,
                company=row["company"] or None, country=row["country"] or None,
                source_file=row["source_file"], sheet_name=row["sheet_name"],
                sheet_index=int(row["sheet_index"]), quality_flags=[],
            ))

    kept, dedupe_report = dedupe_nights(observations)
    guest_nights, blocks = split_room_blocks(kept)
    stays = merge_nights_into_stays(guest_nights)

    os.makedirs(OUT_DIR, exist_ok=True)
    with open(OUT_DIR / "stg_room_blocks.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(BLOCK_COLUMNS)
        for b in blocks:
            w.writerow([getattr(b, c) for c in BLOCK_COLUMNS])

    with open(OUT_DIR / "night_dedupe_report.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["night_date", "room", "kept_source", "kept_guest",
                    "discarded_source", "discarded_guest", "night_conflict"])
        for r in dedupe_report:
            w.writerow([r["night_date"], r["room"], r["kept_source"], r["kept_guest"],
                        r["discarded_source"], r["discarded_guest"], r["night_conflict"]])

    csv_path = OUT_DIR / "stg_estadias_archive.csv"
    with open(csv_path, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(STAY_COLUMNS + ["source"])
        for s in stays:
            d = asdict(s)
            d["quality_flags"] = "|".join(s.quality_flags)
            w.writerow([d[c] for c in STAY_COLUMNS] + ["hotel_archive"])

    by_year: dict[int, dict[str, int]] = {}
    for s in stays:
        if s.check_in is None:
            continue
        y = s.check_in.year
        by_year.setdefault(y, {"stays": 0, "nights": 0})
        by_year[y]["stays"] += 1
        by_year[y]["nights"] += s.nights or 0

    invalid_rooms = invalid_room_stays(stays)
    conflict_pct = night_conflict_rate(dedupe_report)
    conflicts = sum(1 for r in dedupe_report if r["night_conflict"])
    nights_by_year = nights_per_year_report(stays)

    blocks_by_reason = Counter(b.reason for b in blocks)
    remaining_name_counts = Counter(s.guest_name for s in stays).most_common(20)

    print(f"OK -> {csv_path}  ({len(stays):,} estadías)")
    print(f"Observaciones de noche: {len(observations):,} antes -> {len(kept):,} después de dedupe")
    print(f"night_conflict: {conflicts} / {len(dedupe_report)} descartadas ({conflict_pct:.1f}%)")
    print(f"Noches de placeholder de estado de habitación excluidas: {len(blocks)} -> {dict(blocks_by_reason)}")
    print("Top 20 guest_name entre las estadías restantes (para detectar placeholders nuevos):")
    for name, count in remaining_name_counts:
        print(f"  - {name!r}: {count}")
    print(f"Estadías por año: {[(y, by_year[y]['stays'], by_year[y]['nights']) for y in sorted(by_year)]}")
    print(f"Habitaciones inválidas (fuera de VALID_ROOMS): {len(invalid_rooms)}")
    for s in invalid_rooms[:20]:
        print(f"  - {s.source_file} room={s.room} {s.check_in}..{s.check_out}")
    # Reporte informativo, no una prueba de fechado correcto: ver docstring
    # de `nights_per_year_report`.
    print(f"Noches por año (reporte, límite físico 36 x días del año): {nights_by_year}")


if __name__ == "__main__":
    run()
