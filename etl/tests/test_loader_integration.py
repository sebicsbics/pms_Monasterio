"""Tests de integración del loader contra una DB descartable `etl_review_tmp`
en el stack local de Supabase (127.0.0.1:54322). NUNCA tocan la DB `postgres`
real (datos sembrados a mano por el dev) ni corren `db reset`/`migration up`
contra el stack del dev.

Se saltan limpiamente (skip, no error) si el stack local no está corriendo.
Cada test crea `etl_review_tmp`, aplica el esquema (migración base +
20260925000000) y la borra al terminar (fixture teardown).
"""
from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from etl.loader import generate_load_sql

ADMIN_DSN = "postgresql://postgres:postgres@127.0.0.1:54322/postgres"
TMP_DB = "etl_review_tmp"
TMP_DSN = f"postgresql://postgres:postgres@127.0.0.1:54322/{TMP_DB}"

REPO_ROOT = Path(__file__).resolve().parents[2]
MIGRATIONS = [
    REPO_ROOT / "supabase" / "migrations" / "20260703150000_load_historical_stays.sql",
    REPO_ROOT / "supabase" / "migrations" / "20260925000000_historical_stays_source.sql",
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
def review_db():
    """Crea etl_review_tmp fresca (nunca toca `postgres`) y aplica el esquema
    base de historical_stays. La borra al terminar el test."""
    _psql(ADMIN_DSN, "-c", f"drop database if exists {TMP_DB}")
    r = _psql(ADMIN_DSN, "-c", f"create database {TMP_DB}")
    assert r.returncode == 0, r.stderr

    for mig in MIGRATIONS:
        r = _psql(TMP_DSN, "-f", str(mig))
        assert r.returncode == 0, f"{mig.name}: {r.stderr}"

    yield TMP_DSN

    _psql(ADMIN_DSN, "-c", f"drop database if exists {TMP_DB}")


def _run_sql(dsn: str, sql: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["psql", dsn, "-v", "ON_ERROR_STOP=1", "-c", sql],
        capture_output=True, text=True,
    )


def _count(dsn: str, where: str = "") -> int:
    clause = f"where {where}" if where else ""
    r = subprocess.run(
        ["psql", dsn, "-t", "-A", "-c",
         f"select count(*) from public.historical_stays {clause}"],
        capture_output=True, text=True,
    )
    assert r.returncode == 0, r.stderr
    return int(r.stdout.strip())


COLS = [("guest_name", "guest_name", "str"), ("room", "room", "int"),
        ("check_in", "check_in", "date"), ("source", "_source", "str")]


def _rows(source: str, n: int) -> list[dict]:
    return [{"guest_name": f"G{i}", "room": str((i % 36) + 1),
              "check_in": "2016-04-01", "_source": source} for i in range(n)]


def test_fresh_schema_has_zero_rows(review_db):
    assert _count(review_db) == 0


def test_load_then_reload_same_source_is_idempotent(review_db):
    rows = _rows("md", 5)
    sql = generate_load_sql("public.historical_stays", COLS, rows, "source = 'md'")
    assert _run_sql(review_db, sql).returncode == 0
    assert _count(review_db) == 5

    assert _run_sql(review_db, sql).returncode == 0
    assert _count(review_db) == 5


def test_loading_hotel_archive_does_not_touch_md_rows(review_db):
    md_sql = generate_load_sql(
        "public.historical_stays", COLS, _rows("md", 3), "source = 'md'")
    assert _run_sql(review_db, md_sql).returncode == 0

    archive_sql = generate_load_sql(
        "public.historical_stays", COLS, _rows("hotel_archive", 4),
        "source = 'hotel_archive'")
    assert _run_sql(review_db, archive_sql).returncode == 0

    assert _count(review_db, "source = 'md'") == 3
    assert _count(review_db, "source = 'hotel_archive'") == 4
    assert _count(review_db) == 7


def test_delete_by_source_leaves_other_sources_intact(review_db):
    md_sql = generate_load_sql(
        "public.historical_stays", COLS, _rows("md", 3), "source = 'md'")
    archive_sql = generate_load_sql(
        "public.historical_stays", COLS, _rows("hotel_archive", 4),
        "source = 'hotel_archive'")
    assert _run_sql(review_db, md_sql).returncode == 0
    assert _run_sql(review_db, archive_sql).returncode == 0

    r = _run_sql(review_db, "delete from public.historical_stays where source='hotel_archive'")
    assert r.returncode == 0

    assert _count(review_db, "source = 'md'") == 3
    assert _count(review_db, "source = 'hotel_archive'") == 0
