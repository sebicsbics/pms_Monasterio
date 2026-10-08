"""Guard de aislamiento: ningún test puede tocar `etl/output/` real.

`etl/output/` contiene los datos reales del pipeline (con PII) y es la
entrada de los pasos siguientes -- `etl.validate` lee
`stg_estadias_archive_deduped.csv`. Un test que escribe ahí por error
corrompe en silencio la validación (bug real: una fixture de
test_gen_historical_stays pisaba ese csv con una sola fila sintética).
Los tests trabajan siempre sobre `tmp_path`.
"""
from __future__ import annotations

import os
from pathlib import Path

import pytest

REAL_OUTPUT_DIR = Path(__file__).resolve().parent.parent / "output"


def _snapshot(root: Path) -> dict[str, tuple[int, int]]:
    """{ruta relativa: (tamaño, mtime_ns)} de cada archivo bajo `root`."""
    if not root.exists():
        return {}
    snap: dict[str, tuple[int, int]] = {}
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            p = Path(dirpath) / name
            st = p.stat()
            snap[str(p.relative_to(root))] = (st.st_size, st.st_mtime_ns)
    return snap


@pytest.fixture(autouse=True)
def _real_output_untouched():
    before = _snapshot(REAL_OUTPUT_DIR)
    yield
    after = _snapshot(REAL_OUTPUT_DIR)
    changed = sorted(
        k for k in before.keys() | after.keys() if before.get(k) != after.get(k)
    )
    if changed:
        pytest.fail(
            f"el test modificó etl/output/ real: {changed} -- usar tmp_path",
            pytrace=False,
        )
