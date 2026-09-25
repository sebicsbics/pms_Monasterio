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
import re
import unicodedata
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
    variant_group: str | None = None


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


_COPY_SUFFIX_RE = re.compile(r"\s*\(\d+\)\s*$")
_COPY_WORD_RE = re.compile(r"\s*-\s*copia\b.*$")
_COPY_PREFIX_RE = re.compile(r"^copia de\s+")
_WHITESPACE_RE = re.compile(r"\s+")


def _strip_accents(text: str) -> str:
    normalized = unicodedata.normalize("NFKD", text)
    return "".join(ch for ch in normalized if not unicodedata.combining(ch))


def _normalize_variant_key(family: str, filename: str) -> str:
    """Clave de agrupación de variantes del MISMO documento lógico.

    Normaliza nombre de archivo (sin extensión) y familia: minúsculas, sin
    acentos, sin sufijos de copia (" (2)", " - copia", "copia de ").
    Archivos con nombres distintos (ej. meses distintos) producen claves
    distintas y NUNCA se agrupan como variantes.
    """
    stem = Path(filename).stem
    stem = _strip_accents(stem).lower()
    stem = _COPY_PREFIX_RE.sub("", stem)
    stem = _COPY_WORD_RE.sub("", stem)
    stem = _COPY_SUFFIX_RE.sub("", stem)
    stem = _WHITESPACE_RE.sub(" ", stem).strip()

    family_norm = _strip_accents(family).lower().strip()
    return f"{family_norm}::{stem}"


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
    - Archivos que son el MISMO documento lógico (mismo nombre normalizado,
      ver `_normalize_variant_key`: minúsculas, sin acentos, sin sufijos de
      copia) pero con hash DISTINTO entre sí (después de resolver los
      duplicados exactos) son variantes del mismo documento (caso frigobar
      con distintas versiones). Se marcan `is_canonical=False`,
      `reason="needs_manual_review"`, `variant_group=<clave normalizada>`
      — nunca se resuelven en automático. Archivos con nombres DISTINTOS
      (ej. un archivo por mes) NUNCA se agrupan, aunque compartan
      familia+año: no son variantes del mismo documento.
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

    # 2) variantes del MISMO documento lógico (mismo nombre normalizado)
    #    con hash distinto entre sí, tras resolver duplicados exactos.
    #    Archivos con nombres distintos (ej. un mes cada uno) no se agrupan.
    remaining = [e for e in raw if e[0] not in resolved]
    by_variant_key: dict[str, list] = {}
    for entry in remaining:
        path, _md5, _size, family, _year = entry
        key = _normalize_variant_key(family, path.name)
        by_variant_key.setdefault(key, []).append(entry)

    variant_group_by_path: dict[Path, str] = {}
    for key, entries in by_variant_key.items():
        if len(entries) >= 2:
            for entry in entries:
                resolved[entry[0]] = (False, "needs_manual_review")
                variant_group_by_path[entry[0]] = key

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
                variant_group=variant_group_by_path.get(path),
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
    records: list[InventoryRecord], out_file: Path, allowed_dir: Path, root: Path
) -> None:
    """Escribe el manifest plano `inventory.json`. Rechaza rutas fuera de `allowed_dir`.

    `path` se escribe RELATIVO a `root` (nunca absoluto): un path absoluto
    filtraría el home local de quien corrió el extractor.
    """
    out_file = Path(out_file)
    root = Path(root)
    guard_output_path(out_file, allowed_dir)
    out_file.parent.mkdir(parents=True, exist_ok=True)
    payload = []
    for record in records:
        row = asdict(record)
        row["path"] = str(record.path.relative_to(root))
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
    write_inventory_json(records, out_file, allowed_dir=output_dir, root=hotel_root)

    total = len(records)
    canonical = sum(1 for r in records if r.is_canonical)
    duplicates = sum(1 for r in records if r.reason == "duplicate_of_identical_hash")
    manual_review = sum(1 for r in records if r.reason == "needs_manual_review")
    print(f"Inventario: {total} archivos, {canonical} canónicos, "
          f"{duplicates} duplicados descartados, {manual_review} en revisión manual.")
    print(f"Escrito en {out_file}")


if __name__ == "__main__":
    main()
