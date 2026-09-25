"""
Loader genérico de datos a Supabase, parametrizado por tabla/columnas.

Genera SQL de DATOS: `delete from <table> where <predicate>` (rollback por
fuente, NUNCA `truncate`, que borraría filas de otras fuentes) + inserts
multi-fila en lotes, todo dentro de una transacción. Reusado por PR3a en
adelante (una tabla / set de columnas distinto por invocación).

Los datos llevan PII: quien llama esto escribe siempre a etl/output/
(gitignored), nunca a supabase/migrations/.
"""
from __future__ import annotations

CHUNK = 500


def lit(val, kind: str) -> str:
    """Literal SQL seguro para un valor + tipo ('str'|'int'|'num'|'date'|'bool')."""
    v = ("" if val is None else str(val)).strip()
    if v == "" or v.lower() in ("nan", "none"):
        return "NULL"
    if kind == "str":
        return "'" + v.replace("'", "''") + "'"
    if kind == "bool":
        return "true" if v.lower() in ("true", "1") else "false"
    if kind in ("int", "num"):
        try:
            return str(int(float(v))) if kind == "int" else str(float(v))
        except ValueError:
            return "NULL"
    if kind == "date":
        return "'" + v[:10] + "'"
    return "NULL"


def generate_load_sql(table: str, cols, rows, delete_predicate: str, chunk: int = CHUNK) -> str:
    """
    table: nombre calificado, ej. "public.historical_stays".
    cols: lista de (columna_destino, columna_origen_en_row, tipo).
    rows: lista de dicts (ej. csv.DictReader) con al menos las claves origen.
    delete_predicate: condición SQL cruda para el WHERE del delete, ej.
        "source = 'md'" — nunca se genera un `truncate`.
    """
    dest = ", ".join(c[0] for c in cols)
    parts = [
        "begin;\n\n",
        f"delete from {table} where {delete_predicate};\n",
    ]
    for i in range(0, len(rows), chunk):
        batch = rows[i:i + chunk]
        vals = ",\n".join(
            "  (" + ", ".join(lit(r[src], kind) for _, src, kind in cols) + ")"
            for r in batch
        )
        parts.append(f"\ninsert into {table} ({dest}) values\n{vals};\n")
    parts.append("\ncommit;\n")
    return "".join(parts)
