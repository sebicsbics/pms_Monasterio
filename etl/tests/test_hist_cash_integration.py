"""Integración de la carga de `hist_cash_movements` contra la DB descartable
`etl_review_tmp` del stack local (127.0.0.1:54322). Nunca toca `postgres`.

Foco: que el SQL que genera etl.gen_hist_cash cargue contra el esquema real
de la migración y que recargarlo no duplique. La RLS y los permisos se
prueban en supabase/tests/38_hist_cash_movements.sql sobre el stack
completo; acá `public.is_staff()` es un stub porque la DB descartable solo
recibe esta migración.

Se salta (skip) si el stack local no está corriendo.
"""
from __future__ import annotations

from datetime import date
from pathlib import Path

import pytest

from etl.gen_hist_cash import COLS
from etl.loader import generate_load_sql
from etl.tests.test_loader_integration import (
    ADMIN_DSN,
    TMP_DB,
    TMP_DSN,
    _db_reachable,
    _psql,
    _run_sql,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
MIGRATION = REPO_ROOT / "supabase" / "migrations" / "20261007000000_hist_cash_movements.sql"

pytestmark = pytest.mark.skipif(
    not _db_reachable(),
    reason="stack local de Supabase (127.0.0.1:54322) no disponible",
)


@pytest.fixture
def review_db():
    _psql(ADMIN_DSN, "-c", f"drop database if exists {TMP_DB}")
    r = _psql(ADMIN_DSN, "-c", f"create database {TMP_DB}")
    assert r.returncode == 0, r.stderr
    r = _psql(TMP_DSN, "-c",
              "create function public.is_staff() returns boolean language sql as $$ select false $$")
    assert r.returncode == 0, r.stderr
    r = _psql(TMP_DSN, "-f", str(MIGRATION))
    assert r.returncode == 0, f"{MIGRATION.name}: {r.stderr}"
    yield TMP_DSN
    _psql(ADMIN_DSN, "-c", f"drop database if exists {TMP_DB}")


def _scalar(dsn: str, sql: str) -> str:
    r = _psql(dsn, "-t", "-A", "-c", sql)
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()


def _rows() -> list[dict]:
    base = {"concept": "HAB 5", "receipt_ref": "2230", "receptionist": "R",
            "observations": None, "_source": "hotel_archive", "source_file": "caja.xlsx",
            "source_hash": "abc", "sheet_name": "Hoja1", "quality_flags": ""}
    return [
        {**base, "movement_date": date(2014, 7, 1), "kind": "income", "currency": "BOB",
         "amount": 200.0, "source_row": 3},
        {**base, "movement_date": date(2014, 7, 1), "kind": "expense", "currency": "USD",
         "amount": 15.5, "source_row": 3},
        # corrección real del archivo: se conserva el signo
        {**base, "movement_date": date(2013, 8, 2), "kind": "expense", "currency": "BOB",
         "amount": -200.0, "source_row": 9, "quality_flags": "negative_amount"},
    ]


def _load_sql() -> str:
    return generate_load_sql("public.hist_cash_movements", COLS, _rows(), "source = 'hotel_archive'")


def test_fresh_schema_has_zero_rows(review_db):
    assert _scalar(review_db, "select count(*) from public.hist_cash_movements") == "0"


def test_load_then_reload_is_idempotent(review_db):
    assert _run_sql(review_db, _load_sql()).returncode == 0
    assert _run_sql(review_db, _load_sql()).returncode == 0
    assert _scalar(review_db, "select count(*) from public.hist_cash_movements") == "3"
    assert _scalar(review_db, "select sum(amount) from public.hist_cash_movements") == "15.50"


def test_reload_does_not_touch_other_sources(review_db):
    r = _run_sql(review_db,
                 "insert into public.hist_cash_movements (movement_date, kind, currency, amount, source, source_file) "
                 "values ('2014-01-01', 'income', 'BOB', 1, 'otra_fuente', 'x')")
    assert r.returncode == 0, r.stderr
    assert _run_sql(review_db, _load_sql()).returncode == 0
    assert _scalar(review_db,
                   "select count(*) from public.hist_cash_movements where source = 'otra_fuente'") == "1"
