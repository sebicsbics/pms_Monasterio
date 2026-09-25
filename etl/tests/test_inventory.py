"""Tests del extractor de inventario (etl/extractor/inventory.py).

Fixtures 100% sintéticas (contenido de texto inventado, cero PII real).
Nunca lee datos reales de Hotel/ ni md/.
"""
from __future__ import annotations

import pytest

import json

from etl.extractor.inventory import (
    OutputPathViolation,
    build_inventory,
    guard_output_path,
    write_inventory_json,
)


def _write(path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def test_build_inventory_produces_path_hash_size_family(tmp_path):
    root = tmp_path / "Hotel"
    _write(root / "2015" / "huespedes" / "registro.xlsx", "contenido huespedes 2015")
    _write(root / "2016" / "caja" / "caja_enero.xlsx", "contenido caja 2016")

    records = build_inventory(root)

    assert len(records) == 2
    by_family = {r.family: r for r in records}

    huespedes = by_family["huespedes"]
    assert huespedes.year == 2015
    assert huespedes.size == len("contenido huespedes 2015".encode("utf-8"))
    assert len(huespedes.md5) == 32

    caja = by_family["caja"]
    assert caja.year == 2016
    assert caja.size == len("contenido caja 2016".encode("utf-8"))


def test_build_inventory_resolves_mirror_duplicates_by_hash(tmp_path):
    root = tmp_path / "Hotel"
    same_content = "estadia identica huesped X"
    _write(root / "2015" / "huespedes" / "registro.xlsx", same_content)
    _write(root / "2016" / "huespedes" / "registro.xlsx", same_content)

    records = build_inventory(root)

    canonical = [r for r in records if r.is_canonical]
    discarded = [r for r in records if not r.is_canonical]

    assert len(canonical) == 1
    assert len(discarded) == 1
    assert discarded[0].reason == "duplicate_of_identical_hash"
    # el más antiguo (2015) es el canónico por precedencia
    assert canonical[0].year == 2015


def test_build_inventory_flags_frigobar_variants_without_identical_hash(tmp_path):
    root = tmp_path / "Hotel"
    _write(root / "2015" / "frigobar" / "a.xlsx", "variante A")
    _write(root / "2015" / "frigobar" / "b.xlsx", "variante B")
    _write(root / "2015" / "frigobar" / "c.xlsx", "variante C")

    records = build_inventory(root)

    assert len(records) == 3
    assert all(r.family == "frigobar" for r in records)
    assert all(not r.is_canonical for r in records)
    assert all(r.reason == "needs_manual_review" for r in records)


def test_guard_output_path_rejects_paths_outside_etl_output(tmp_path):
    allowed = tmp_path / "etl" / "output"
    outside = tmp_path / "supabase" / "migrations" / "leak.sql"

    with pytest.raises(OutputPathViolation):
        guard_output_path(outside, allowed_dir=allowed)


def test_guard_output_path_accepts_paths_inside_etl_output(tmp_path):
    allowed = tmp_path / "etl" / "output"
    inside = allowed / "inventory.json"

    # no debe lanzar
    guard_output_path(inside, allowed_dir=allowed)


def test_write_inventory_json_writes_manifest_inside_output(tmp_path):
    root = tmp_path / "Hotel"
    _write(root / "2015" / "caja" / "caja.xlsx", "contenido caja")
    output_dir = tmp_path / "etl" / "output"
    out_file = output_dir / "inventory.json"

    records = build_inventory(root)
    write_inventory_json(records, out_file, allowed_dir=output_dir)

    assert out_file.exists()
    data = json.loads(out_file.read_text(encoding="utf-8"))
    assert len(data) == 1
    assert data[0]["family"] == "caja"
    assert data[0]["year"] == 2015
    assert data[0]["is_canonical"] is True


def test_write_inventory_json_rejects_path_outside_output(tmp_path):
    root = tmp_path / "Hotel"
    _write(root / "2015" / "caja" / "caja.xlsx", "contenido caja")
    output_dir = tmp_path / "etl" / "output"
    leak_file = tmp_path / "supabase" / "migrations" / "leak.json"

    records = build_inventory(root)
    with pytest.raises(OutputPathViolation):
        write_inventory_json(records, leak_file, allowed_dir=output_dir)
    assert not leak_file.exists()
