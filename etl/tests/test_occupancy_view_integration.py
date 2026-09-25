"""Test de integración de `v_occupancy_by_year` (capacidad por período
cubierto, columna `es_parcial`) contra una DB descartable `etl_3c_tmp` en el
stack local de Supabase (127.0.0.1:54322). NUNCA toca la DB `postgres` real
(datos sembrados a mano por el dev) ni corre `db reset`/`migration up`
contra el stack del dev.

Se salta limpiamente (skip, no error) si el stack local no está corriendo.
Crea `etl_3c_tmp`, aplica el esquema base + la migración de la vista, y la
borra al terminar (fixture teardown).
"""
from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

ADMIN_DSN = "postgresql://postgres:postgres@127.0.0.1:54322/postgres"
TMP_DB = "etl_3c_tmp"
TMP_DSN = f"postgresql://postgres:postgres@127.0.0.1:54322/{TMP_DB}"

REPO_ROOT = Path(__file__).resolve().parents[2]
MIGRATIONS = [
    REPO_ROOT / "supabase" / "migrations" / "20260703150000_load_historical_stays.sql",
    REPO_ROOT / "supabase" / "migrations" / "20260925000000_historical_stays_source.sql",
    REPO_ROOT / "supabase" / "migrations" / "20260925010000_occupancy_covered_period.sql",
]


def _db_reachable() -> bool:
    try:
        r = subprocess.run(
            ["psql", ADMIN_DSN, "-c", "select 1"],
            capture_output=True, timeout=5,
        )
        return r.returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


pytestmark = pytest.mark.skipif(
    not _db_reachable(),
    reason="stack local de Supabase (127.0.0.1:54322) no disponible",
)


def _psql(dsn: str, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["psql", dsn, "-v", "ON_ERROR_STOP=1", *args],
        capture_output=True, text=True,
    )


@pytest.fixture
def occupancy_db():
    _psql(ADMIN_DSN, "-c", f"drop database if exists {TMP_DB}")
    r = _psql(ADMIN_DSN, "-c", f"create database {TMP_DB}")
    assert r.returncode == 0, r.stderr

    for mig in MIGRATIONS:
        r = _psql(TMP_DSN, "-f", str(mig))
        assert r.returncode == 0, f"{mig.name}: {r.stderr}"

    yield TMP_DSN

    _psql(ADMIN_DSN, "-c", f"drop database if exists {TMP_DB}")


def _insert(dsn: str, rows: list[tuple[str, int, str, str, int]]) -> None:
    values = ", ".join(
        f"('{g}', {room}, '{ci}', '{co}', {n}, '')" for g, room, ci, co, n in rows
    )
    sql = (
        "insert into public.historical_stays "
        "(guest_name, room, check_in, check_out, nights, quality_flags) "
        f"values {values}"
    )
    r = _psql(dsn, "-c", sql)
    assert r.returncode == 0, r.stderr


def _fetch(dsn: str) -> dict[int, dict]:
    r = subprocess.run(
        ["psql", dsn, "-t", "-A", "-F", "|", "-c",
         "select year, noches_vendidas, capacidad, ocupacion_pct, es_parcial, "
         "desde, hasta from public.v_occupancy_by_year order by year"],
        capture_output=True, text=True,
    )
    assert r.returncode == 0, r.stderr
    out: dict[int, dict] = {}
    for line in r.stdout.strip().splitlines():
        year, noches, cap, pct, parcial, desde, hasta = line.split("|")
        out[int(year)] = {
            "noches": int(noches), "capacidad": int(cap), "pct": float(pct),
            "es_parcial": parcial == "t", "desde": desde, "hasta": hasta,
        }
    return out


def test_partial_year_only_sep_dec_marks_es_parcial_and_shrinks_capacidad(occupancy_db):
    _insert(occupancy_db, [
        ("A", 1, "2020-09-01", "2020-09-11", 10),
        ("B", 2, "2020-12-20", "2020-12-31", 11),
    ])
    r = _fetch(occupancy_db)[2020]
    assert r["es_parcial"] is True
    assert r["desde"] == "2020-09-01"
    assert r["hasta"] == "2020-12-30"  # última noche = check_out - 1
    assert r["capacidad"] == 36 * 121  # 1-sep..30-dic inclusive = 121 días
    assert r["noches"] == 21


def test_full_year_coverage_does_not_mark_es_parcial(occupancy_db):
    _insert(occupancy_db, [
        ("C", 1, "2021-01-01", "2021-01-06", 5),
        ("D", 2, "2021-12-25", "2022-01-01", 7),
    ])
    r = _fetch(occupancy_db)[2021]
    assert r["es_parcial"] is False
    assert r["desde"] == "2021-01-01"
    assert r["hasta"] == "2021-12-31"
    assert r["capacidad"] == 36 * 365


def test_null_quality_flags_row_is_counted_not_silently_excluded(occupancy_db):
    # bug: `quality_flags not like '%room_invalid%'` da NULL (falso) cuando
    # quality_flags es NULL -> excluía en silencio las filas MÁS limpias
    # (sin flags). Debe usar coalesce(quality_flags, '').
    r = _psql(occupancy_db, "-c",
        "insert into public.historical_stays "
        "(guest_name, room, check_in, check_out, nights, quality_flags) "
        "values ('sinflags', 1, '2018-03-01', '2018-03-05', 4, null)")
    assert r.returncode == 0, r.stderr
    rows = _fetch(occupancy_db)
    assert rows[2018]["noches"] == 4

    r2 = subprocess.run(
        ["psql", occupancy_db, "-t", "-A", "-c",
         "select noches from public.v_room_performance where room = 1"],
        capture_output=True, text=True,
    )
    assert r2.returncode == 0, r2.stderr
    assert r2.stdout.strip() == "4"


def test_unreliable_row_with_year_typo_range_is_excluded_from_covered_range(occupancy_db):
    # fila con nights null (como el typo real de md) no debe entrar al
    # cálculo ni de noches ni del rango desde/hasta.
    r = _psql(occupancy_db, "-c",
        "insert into public.historical_stays "
        "(guest_name, room, check_in, check_out, nights, quality_flags) "
        "values ('typo', 1, '2015-05-30', '2017-06-01', null, '')")
    assert r.returncode == 0, r.stderr
    _insert(occupancy_db, [("E", 1, "2015-06-01", "2015-06-05", 4)])
    rows = _fetch(occupancy_db)
    assert 2017 not in rows  # la fila con nights null no genera ningún año
    r2015 = rows[2015]
    assert r2015["desde"] == "2015-06-01"
    assert r2015["hasta"] == "2015-06-04"
