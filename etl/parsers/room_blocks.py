"""Clasificador de placeholders de ESTADO de habitación escritos por error
en la columna de huésped (ver decisión de usuario, Slice 2b fix).

Las recepcionistas a veces anotaban el estado de la habitación (bloqueada,
por habilitar, en depósito, ocupada sin nombre) en la misma celda donde va
el nombre del huésped. Esas filas no son estadías reales y hay que sacarlas
antes de fusionar noches en `guest_stays.merge_nights_into_stays` -- si no,
inflan la ocupación 2013-2016 en más de un 20% de las noches.

Se aplica DESPUÉS del dedupe entre archivos (`dedupe_nights`): cada
(night_date, room) ya tiene una sola observación, así que clasificarla como
huésped o bloqueo es una decisión única y consistente.
"""
from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, fields
from datetime import date

from etl.parsers.guest_nights import NightObservation

_STORAGE_WORDS = {"DEPOSITO"}
_OCCUPIED_WORDS = {"OCUPADO", "OCUPADA"}
_TO_PREPARE_FIRST_WORDS = {"HABILITAR"}
_MAINTENANCE_PREFIXES = ("FUERA DE SERVICIO", "MANTENIMIENTO")


def _normalize_status_text(text: str | None) -> str:
    if not text:
        return ""
    normalized = unicodedata.normalize("NFKD", str(text))
    stripped = "".join(ch for ch in normalized if not unicodedata.combining(ch))
    stripped = re.sub(r"[^A-Za-z\s]", " ", stripped)
    return re.sub(r"\s+", " ", stripped).strip().upper()


_MIN_SPACED_LETTERS = 3


def _collapse_spaced_letters(words: list[str]) -> list[str]:
    """Algunas celdas quedaron con letras sueltas separadas por espacios
    (ej. 'B L O Q U E A D A', typeo de tipeo letra a letra). Si TODAS las
    palabras son de una sola letra y hay al menos `_MIN_SPACED_LETTERS`
    (evita colapsar iniciales de persona tipo 'A B'), se juntan en una sola
    palabra antes de clasificar."""
    if len(words) >= _MIN_SPACED_LETTERS and all(len(w) == 1 for w in words):
        return ["".join(words)]
    return words


def classify_room_status(raw_text: str | None) -> str | None:
    """Categoría de bloqueo ('blocked' / 'to_prepare' / 'storage' /
    'occupied_unnamed') si `raw_text` es texto de estado de habitación, o
    `None` si parece un huésped real.

    Solo clasifica por la PRIMERA palabra normalizada (mayúsculas, sin
    acentos ni puntuación, y con letras sueltas colapsadas -- ver
    `_collapse_spaced_letters`) o por un prefijo de frase completa -- nunca
    por substring en cualquier posición, para no atrapar nombres/apellidos
    reales que casualmente contengan un token de estado (ver tests con
    'MARIA DEPOSITO GARCIA' -> None). Vocabulario nuevo no confirmado por el
    usuario (DELEGACIÓN, NOCHE DE BODAS, HOTEL PLAZA, RESERVADA...) se deja
    deliberadamente sin clasificar."""
    norm = _normalize_status_text(raw_text)
    if not norm:
        return None
    if norm.startswith(_MAINTENANCE_PREFIXES):
        return "blocked"
    words = _collapse_spaced_letters(norm.split(" "))
    first = words[0]
    # 'BLOC' cubre el truncado real ('bloc'); 'BLOQUE' cubre
    # BLOQUEADA/BLOQUEADO/BLOQUEADAS/etc. Decisión conservadora: cualquier
    # primera palabra que arranque con estos prefijos se toma como bloqueo.
    if first.startswith(("BLOQUE", "BLOC")):
        return "blocked"
    if first == "FALTA":
        return "to_prepare"
    if first in _TO_PREPARE_FIRST_WORDS:
        return "to_prepare"
    if first in _STORAGE_WORDS:
        return "storage"
    if first in _OCCUPIED_WORDS:
        return "occupied_unnamed"
    return None


@dataclass
class RoomBlock:
    night_date: date
    room: int | None
    reason: str
    raw_text: str
    source_file: str


BLOCK_COLUMNS = [f.name for f in fields(RoomBlock)]


def split_room_blocks(
    nights: list[NightObservation],
) -> tuple[list[NightObservation], list[RoomBlock]]:
    """Separa las observaciones de noche cuyo campo `guest_name` es en
    realidad texto de estado de habitación. Devuelve (huéspedes, bloqueos)."""
    guests: list[NightObservation] = []
    blocks: list[RoomBlock] = []
    for o in nights:
        reason = classify_room_status(o.guest_name)
        if reason is None:
            guests.append(o)
        else:
            blocks.append(RoomBlock(
                night_date=o.night_date, room=o.room, reason=reason,
                raw_text=o.guest_name, source_file=o.source_file,
            ))
    return guests, blocks
