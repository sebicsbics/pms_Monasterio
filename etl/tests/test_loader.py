"""Tests del loader genérico (etl/loader.py). Fixtures sintéticas."""
from __future__ import annotations

from etl.loader import generate_load_sql, lit


def test_lit_escapes_quotes_in_strings():
    assert lit("O'Brien", "str") == "'O''Brien'"


def test_lit_null_for_empty_or_none():
    assert lit("", "str") == "NULL"
    assert lit(None, "int") == "NULL"
    assert lit("nan", "num") == "NULL"


def test_lit_types():
    assert lit("42", "int") == "42"
    assert lit("42.5", "num") == "42.5"
    assert lit("true", "bool") == "true"
    assert lit("2016-04-01", "date") == "'2016-04-01'"


def test_generate_load_sql_never_truncates():
    cols = [("guest_name", "guest_name", "str")]
    rows = [{"guest_name": "JUAN"}]
    sql = generate_load_sql("public.historical_stays", cols, rows, "source = 'md'")
    assert "truncate" not in sql.lower()


def test_generate_load_sql_deletes_by_predicate_inside_transaction():
    cols = [("guest_name", "guest_name", "str")]
    rows = [{"guest_name": "JUAN"}]
    sql = generate_load_sql("public.historical_stays", cols, rows, "source = 'md'")
    assert "begin;" in sql
    assert "delete from public.historical_stays where source = 'md';" in sql
    assert sql.strip().endswith("commit;")
    assert sql.index("delete from") < sql.index("insert into")


def test_generate_load_sql_batches_multi_row_inserts():
    cols = [("guest_name", "guest_name", "str")]
    rows = [{"guest_name": f"G{i}"} for i in range(5)]
    sql = generate_load_sql("public.historical_stays", cols, rows, "source = 'md'", chunk=2)
    assert sql.count("insert into public.historical_stays") == 3  # 2+2+1
    assert "'G0'" in sql and "'G4'" in sql


def test_generate_load_sql_empty_rows_no_insert():
    cols = [("guest_name", "guest_name", "str")]
    sql = generate_load_sql("public.historical_stays", cols, [], "source = 'md'")
    assert "insert into" not in sql
    assert "delete from" in sql
