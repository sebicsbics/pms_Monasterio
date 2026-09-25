"""Extractor: recorre un árbol de archivos, calcula md5 e infiere familia/año.

Resuelve duplicados byte-idénticos (mismo hash) quedándose con el más
antiguo como canónico y descartando el resto (reportado, nunca en silencio).
Variantes SIN hash idéntico (ej. frigobar con 3 versiones distintas) NO se
resuelven automáticamente: quedan marcadas para reconciliación manual.

Ninguna función de este módulo escribe fuera de `etl/output/` (ver
`guard_output_path`); esta es la barrera de PII del extractor.
"""
from __future__ import annotations

import hashlib
import json
import os
from dataclasses import asdict, dataclass
from pathlib import Path


class OutputPathViolation(Exception):
    """Se intentó escribir una salida fuera del directorio permitido (etl/output/)."""


@dataclass(frozen=True)
class InventoryRecord:
    path: Path
    md5: str
    size: int
    family: str
    year: int | None
    is_canonical: bool
    reason: str | None


def _md5_of_file(path: Path) -> str:
    digest = hashlib.md5()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _infer_family_year(path: Path, root: Path) -> tuple[str, int | None]:
    """Infiere (familia, año) a partir de la ruta `root/<año>/<familia>/archivo`."""
    rel_parts = path.relative_to(root).parts
    year: int | None = None
    family = "unknown"
    if len(rel_parts) >= 2:
        year_part, family_part = rel_parts[0], rel_parts[1]
        try:
            year = int(year_part)
        except ValueError:
            year = None
        family = family_part
    elif len(rel_parts) == 1:
        family = "unknown"
    return family, year


def _walk_files(root: Path) -> list[Path]:
    files: list[Path] = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for filename in filenames:
            files.append(Path(dirpath) / filename)
    return files


def build_inventory(root: Path) -> list[InventoryRecord]:
    """Recorre `root`, calcula md5/tamaño/familia/año y resuelve precedencia.

    Reglas:
    - Archivos con hash idéntico: se queda uno solo como canónico (el de
      año más antiguo), el resto se marca `is_canonical=False`,
      `reason="duplicate_of_identical_hash"`.
    - Archivos que comparten (familia, año-base-de-la-familia) pero NO
      tienen hash idéntico entre sí y son ≥3 variantes de la misma familia
      en el mismo año (caso frigobar): se marcan
      `is_canonical=False`, `reason="needs_manual_review"` — nunca se
      resuelven en automático.
    - El resto queda canónico (`is_canonical=True`, `reason=None`).
    """
    root = Path(root)
    files = _walk_files(root)

    raw: list[tuple[Path, str, int, str, int | None]] = []
    for path in files:
        family, year = _infer_family_year(path, root)
        md5 = _md5_of_file(path)
        size = path.stat().st_size
        raw.append((path, md5, size, family, year))

    # 1) resolver duplicados byte-idénticos por hash
    by_hash: dict[str, list[tuple[Path, str, int, str, int | None]]] = {}
    for entry in raw:
        by_hash.setdefault(entry[1], []).append(entry)

    resolved: dict[Path, tuple[bool, str | None]] = {}
    for md5, entries in by_hash.items():
        if len(entries) > 1:
            entries_sorted = sorted(entries, key=lambda e: (e[4] is None, e[4]))
            canonical_path = entries_sorted[0][0]
            for entry in entries_sorted:
                if entry[0] == canonical_path:
                    resolved[entry[0]] = (True, None)
                else:
                    resolved[entry[0]] = (False, "duplicate_of_identical_hash")

    # 2) variantes de la misma familia+año sin hash idéntico entre sí
    #    (ej. frigobar): ≥3 archivos en el mismo (familia, año) que no
    #    fueron ya resueltos como duplicados exactos → manual review.
    remaining = [e for e in raw if e[0] not in resolved]
    by_family_year: dict[tuple[str, int | None], list] = {}
    for entry in remaining:
        by_family_year.setdefault((entry[3], entry[4]), []).append(entry)

    for (_family, _year), entries in by_family_year.items():
        if len(entries) >= 3:
            for entry in entries:
                resolved[entry[0]] = (False, "needs_manual_review")

    records: list[InventoryRecord] = []
    for path, md5, size, family, year in raw:
        is_canonical, reason = resolved.get(path, (True, None))
        records.append(
            InventoryRecord(
                path=path,
                md5=md5,
                size=size,
                family=family,
                year=year,
                is_canonical=is_canonical,
                reason=reason,
            )
        )
    return records


def guard_output_path(path: Path, allowed_dir: Path) -> None:
    """Rechaza cualquier escritura fuera de `allowed_dir` (etl/output/).

    Debe llamarse ANTES de tocar el filesystem.
    """
    path = Path(path).resolve()
    allowed_dir = Path(allowed_dir).resolve()
    if allowed_dir != path and allowed_dir not in path.parents:
        raise OutputPathViolation(
            f"Escritura rechazada fuera de {allowed_dir}: {path}"
        )


def write_inventory_json(
    records: list[InventoryRecord], out_file: Path, allowed_dir: Path
) -> None:
    """Escribe el manifest plano `inventory.json`. Rechaza rutas fuera de `allowed_dir`."""
    out_file = Path(out_file)
    guard_output_path(out_file, allowed_dir)
    out_file.parent.mkdir(parents=True, exist_ok=True)
    payload = []
    for record in records:
        row = asdict(record)
        row["path"] = str(record.path)
        payload.append(row)
    out_file.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")


def main() -> None:
    """CLI: recorre `Hotel/` (raíz del repo) y escribe `etl/output/inventory.json`."""
    base = Path(__file__).resolve().parent.parent.parent  # raíz del repo
    hotel_root = base / "Hotel"
    output_dir = base / "etl" / "output"
    out_file = output_dir / "inventory.json"

    if not hotel_root.exists():
        raise SystemExit(f"No existe {hotel_root} — nada que inventariar")

    records = build_inventory(hotel_root)
    write_inventory_json(records, out_file, allowed_dir=output_dir)

    total = len(records)
    canonical = sum(1 for r in records if r.is_canonical)
    duplicates = sum(1 for r in records if r.reason == "duplicate_of_identical_hash")
    manual_review = sum(1 for r in records if r.reason == "needs_manual_review")
    print(f"Inventario: {total} archivos, {canonical} canónicos, "
          f"{duplicates} duplicados descartados, {manual_review} en revisión manual.")
    print(f"Escrito en {out_file}")


if __name__ == "__main__":
    main()
