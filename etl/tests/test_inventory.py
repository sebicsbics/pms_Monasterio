"""Tests del extractor de inventario (etl/extractor/inventory.py).

Fixtures 100% sintéticas (contenido de texto inventado, cero PII real).
Nunca lee datos reales de Hotel/ ni md/.
"""
from __future__ import annotations

import pytest

import json
from pathlib import Path

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


def test_build_inventory_keeps_distinct_monthly_files_canonical(tmp_path):
    root = tmp_path / "Hotel"
    meses = [
        "ENERO", "FEBRERO", "MARZO", "ABRIL", "MAYO", "JUNIO",
        "JULIO", "AGOSTO", "SEPTIEMBRE", "OCTUBRE", "NOVIEMBRE", "DICIEMBRE",
    ]
    for mes in meses:
        _write(
            root / "2014" / "huespedes" / f"HUESPEDES {mes}.xlsx",
            f"contenido real de {mes} 2014, distinto de los demas meses",
        )

    records = build_inventory(root)

    assert len(records) == 12
    assert all(r.is_canonical for r in records)
    assert all(r.reason is None for r in records)


def test_build_inventory_flags_same_logical_document_variants_as_manual_review(tmp_path):
    root = tmp_path / "Hotel"
    _write(root / "2015" / "FRIGOBAR" / "FRIGOBAR AGOSTO.xls", "version A del frigobar de agosto")
    _write(root / "2016" / "Frigobar" / "frigobar agosto (2).xls", "version B del frigobar de agosto")

    records = build_inventory(root)

    assert len(records) == 2
    assert all(not r.is_canonical for r in records)
    assert all(r.reason == "needs_manual_review" for r in records)
    group_keys = {r.variant_group for r in records}
    assert len(group_keys) == 1
    assert group_keys != {None}


def test_build_inventory_same_name_identical_content_uses_hash_dedupe_not_variant(tmp_path):
    root = tmp_path / "Hotel"
    same_content = "reporte identico repetido en dos carpetas"
    _write(root / "2015" / "frigobar" / "frigobar agosto.xls", same_content)
    _write(root / "2016" / "frigobar" / "frigobar agosto.xls", same_content)

    records = build_inventory(root)

    canonical = [r for r in records if r.is_canonical]
    discarded = [r for r in records if not r.is_canonical]

    assert len(canonical) == 1
    assert len(discarded) == 1
    assert discarded[0].reason == "duplicate_of_identical_hash"
    assert canonical[0].year == 2015
    assert discarded[0].variant_group is None


def test_build_inventory_canonical_of_exact_dup_still_joins_variant_group(tmp_path):
    # 2014 y 2015: mismo hash ("A") -> 2015 es duplicado exacto de 2014.
    # 2016: hash distinto ("B") pero mismo documento lógico (mismo nombre
    # normalizado) -> 2014 (el canónico del grupo de hash) Y 2016 deben
    # quedar needs_manual_review con el mismo variant_group. El repro del
    # bug: el 2014 quedaba canonical/None porque el paso 2 lo excluía por
    # estar ya en `resolved` (aunque fuera el representante canónico).
    root = tmp_path / "Hotel"
    _write(root / "2014" / "Frigobar" / "frigobar agosto.xls", "A")
    _write(root / "2015" / "Frigobar" / "frigobar agosto.xls", "A")
    _write(root / "2016" / "Frigobar" / "frigobar agosto (2).xls", "B")

    records = build_inventory(root)
    by_year = {r.year: r for r in records}

    assert by_year[2015].is_canonical is False
    assert by_year[2015].reason == "duplicate_of_identical_hash"
    assert by_year[2015].variant_group is None

    assert by_year[2014].is_canonical is False
    assert by_year[2014].reason == "needs_manual_review"
    assert by_year[2016].is_canonical is False
    assert by_year[2016].reason == "needs_manual_review"
    assert by_year[2014].variant_group == by_year[2016].variant_group
    assert by_year[2014].variant_group is not None


def test_build_inventory_canonical_tie_break_is_deterministic_by_path(tmp_path):
    root = tmp_path / "Hotel"
    same_content = "contenido identico mismo anio"
    _write(root / "2015" / "caja" / "z_ultimo.xlsx", same_content)
    _write(root / "2015" / "caja" / "a_primero.xlsx", same_content)

    records = build_inventory(root)
    canonical = [r for r in records if r.is_canonical]

    assert len(canonical) == 1
    assert canonical[0].path.name == "a_primero.xlsx"


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
    write_inventory_json(records, out_file, allowed_dir=output_dir, root=root)

    assert out_file.exists()
    data = json.loads(out_file.read_text(encoding="utf-8"))
    assert len(data) == 1
    assert data[0]["family"] == "caja"
    assert data[0]["year"] == 2015
    assert data[0]["is_canonical"] is True
    # el path debe ser relativo a root, nunca absoluto (no debe filtrar el home local)
    assert data[0]["path"] == str(Path("2015") / "caja" / "caja.xlsx")
    assert not Path(data[0]["path"]).is_absolute()


def test_write_inventory_json_includes_variant_group_for_manual_review_rows(tmp_path):
    root = tmp_path / "Hotel"
    _write(root / "2015" / "FRIGOBAR" / "FRIGOBAR AGOSTO.xls", "version A")
    _write(root / "2016" / "Frigobar" / "frigobar agosto (2).xls", "version B")
    output_dir = tmp_path / "etl" / "output"
    out_file = output_dir / "inventory.json"

    records = build_inventory(root)
    write_inventory_json(records, out_file, allowed_dir=output_dir, root=root)

    data = json.loads(out_file.read_text(encoding="utf-8"))
    assert len(data) == 2
    assert all(row["reason"] == "needs_manual_review" for row in data)
    assert all(row["variant_group"] is not None for row in data)
    assert len({row["variant_group"] for row in data}) == 1


def test_write_inventory_json_rejects_path_outside_output(tmp_path):
    root = tmp_path / "Hotel"
    _write(root / "2015" / "caja" / "caja.xlsx", "contenido caja")
    output_dir = tmp_path / "etl" / "output"
    leak_file = tmp_path / "supabase" / "migrations" / "leak.json"

    records = build_inventory(root)
    with pytest.raises(OutputPathViolation):
        write_inventory_json(records, leak_file, allowed_dir=output_dir, root=root)
    assert not leak_file.exists()
