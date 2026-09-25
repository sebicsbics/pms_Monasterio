"""Dedupe de noches entre archivos + fusión en estadías.

Los workbooks son acumulativos (`guest_nights.py`): la misma noche aparece en
varios archivos. Acá se resuelve UNA observación por (night_date, room),
prefiriendo el archivo cuyo mes nominal (del nombre) coincide con la noche;
si ninguno coincide, el archivo "más tardío" (mes nominal mayor); empate por
ruta. Las descartadas van a `etl/output/night_dedupe_report.csv`. Luego se
fusionan noches consecutivas de (room, guest) en estadías, igual criterio que
la Slice 2 original: corte por hueco/cambio de huésped, flag `room_change`.

Salida: `etl/output/stg_estadias_archive.csv` (mismas columnas que hoy) +
`etl/output/night_dedupe_report.csv`.
"""
from __future__ import annotations

import csv, json, os, re
from dataclasses import asdict, dataclass, field, fields
from datetime import date, timedelta
from pathlib import Path

from etl.parsers.guest_nights import NightObservation, MONTHS, _MONTH_ABBR
from etl.stg_estadias import normalize_payment

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


def capacity_violations_final(stays: list[Stay]) -> list[tuple[date, int]]:
    """(date, count) para fechas con más de 36 habitaciones ocupadas (dato final)."""
    occ: dict[date, set[int]] = {}
    for s in stays:
        if s.check_in is None or s.check_out is None or s.room is None:
            continue
        d = s.check_in
        while d < s.check_out:
            occ.setdefault(d, set()).add(s.room)
            d += timedelta(days=1)
    return sorted((d, len(r)) for d, r in occ.items() if len(r) > 36)


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
    stays = merge_nights_into_stays(kept)

    os.makedirs(OUT_DIR, exist_ok=True)
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

    violations = capacity_violations_final(stays)
    conflicts = sum(1 for r in dedupe_report if r["night_conflict"])

    print(f"OK -> {csv_path}  ({len(stays):,} estadías)")
    print(f"Observaciones de noche: {len(observations):,} antes -> {len(kept):,} después de dedupe")
    print(f"night_conflict: {conflicts} / {len(dedupe_report)} descartadas")
    print(f"Estadías por año: {[(y, by_year[y]['stays'], by_year[y]['nights']) for y in sorted(by_year)]}")
    print(f"Violaciones de capacidad final (>36 hab. ocupadas el mismo día): {len(violations)}")
    for d, n in violations[:20]:
        print(f"  - {d}: {n} habitaciones")


if __name__ == "__main__":
    run()
