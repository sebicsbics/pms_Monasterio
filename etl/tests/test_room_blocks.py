"""Tests del clasificador de placeholders de estado de habitación
(etl/parsers/room_blocks.py).

Fixtures sintéticas. Nunca lee datos reales de Hotel/.
"""
from __future__ import annotations

from datetime import date

from etl.parsers.guest_nights import NightObservation
from etl.parsers.room_blocks import classify_room_status, split_room_blocks


def _obs(guest_name, night_date=date(2016, 4, 1), room=5, source_file="f.xls"):
    return NightObservation(
        night_date=night_date, room=room, guest_name=guest_name,
        pax=None, rate=100, payment=None, company=None, country=None,
        source_file=source_file, sheet_name="s", sheet_index=0, quality_flags=[],
    )


def test_classify_room_status_blocked_variants():
    assert classify_room_status("BLOQUEADA") == "blocked"
    assert classify_room_status("BLOQUEADO") == "blocked"
    assert classify_room_status("Bloqueada Habilitar") == "blocked"
    assert classify_room_status("BLOQUEADA (DEPOSITO)") == "blocked"
    assert classify_room_status("BLOQUEADA FALTAN ALMOHADAS") == "blocked"
    assert classify_room_status("BLOQUEADA POR HORMIGUICIDA") == "blocked"
    assert classify_room_status("BLOQUEADAS") == "blocked"


def test_classify_room_status_to_prepare_variants():
    assert classify_room_status("HABILITAR") == "to_prepare"
    assert classify_room_status("(HABILITAR)") == "to_prepare"
    assert classify_room_status("FALTA HABILITAR") == "to_prepare"


def test_classify_room_status_storage_and_occupied():
    assert classify_room_status("DEPOSITO") == "storage"
    assert classify_room_status("OCUPADO") == "occupied_unnamed"


def test_classify_room_status_maintenance_prefix_is_blocked():
    assert classify_room_status("FUERA DE SERVICIO") == "blocked"
    assert classify_room_status("MANTENIMIENTO") == "blocked"


def test_classify_room_status_returns_none_for_real_guest():
    assert classify_room_status("JUAN PEREZ") is None
    assert classify_room_status("MARIA LOPEZ") is None


def test_classify_room_status_does_not_match_status_word_mid_name():
    # apellido ficticio que contiene un token de estado, pero NO como
    # primera palabra -> no debe clasificarse como bloqueo.
    assert classify_room_status("MARIA DEPOSITO GARCIA") is None
    assert classify_room_status("PEDRO OCUPADO FLORES") is None


def test_classify_room_status_empty_or_none_is_none():
    assert classify_room_status("") is None
    assert classify_room_status(None) is None


def test_classify_room_status_collapses_spaced_out_letters():
    # celdas con letras sueltas separadas por espacios (>=3 letras) se
    # colapsan antes de clasificar.
    assert classify_room_status("B L O Q U E A D A") == "blocked"
    assert classify_room_status("H A B I L I T A R") == "to_prepare"
    assert classify_room_status("B L O  Q U E A D O") == "blocked"


def test_classify_room_status_does_not_collapse_short_letter_sequences():
    # menos de 3 letras sueltas (ej. iniciales de una persona) no se
    # colapsa: no se clasifica como bloqueo.
    assert classify_room_status("A B") is None


def test_classify_room_status_falta_prefix_is_to_prepare():
    assert classify_room_status("FALTA PAPEL") == "to_prepare"
    assert classify_room_status("FALTA TOALLAS") == "to_prepare"
    assert classify_room_status("FALTA HABILITAR") == "to_prepare"


def test_classify_room_status_bloc_truncated_is_blocked():
    assert classify_room_status("bloc") == "blocked"
    assert classify_room_status("BLOC") == "blocked"


def test_classify_room_status_leaves_ambiguous_new_vocab_untouched():
    # decisión explícita del usuario: estos NO se tocan en este fix.
    assert classify_room_status("DELEGACIÓN") is None
    assert classify_room_status("NOCHE DE BODAS") is None
    assert classify_room_status("HOTEL PLAZA") is None
    assert classify_room_status("RESERVADA 30 OCT-01NOV") is None


def test_split_room_blocks_separates_guest_and_block_nights():
    nights = [
        _obs("JUAN PEREZ", room=5),
        _obs("BLOQUEADA", room=6),
        _obs("HABILITAR", room=7),
        _obs("DEPOSITO", room=8),
        _obs("OCUPADO", room=9),
    ]
    guests, blocks = split_room_blocks(nights)
    assert [g.room for g in guests] == [5]
    assert {b.room: b.reason for b in blocks} == {
        6: "blocked", 7: "to_prepare", 8: "storage", 9: "occupied_unnamed",
    }


def test_split_room_blocks_keeps_raw_text_and_source_file():
    nights = [_obs("BLOQUEADA HABILITAR", room=6, source_file="HUESPEDES ABRIL 2016.xls")]
    _, blocks = split_room_blocks(nights)
    assert blocks[0].raw_text == "BLOQUEADA HABILITAR"
    assert blocks[0].source_file == "HUESPEDES ABRIL 2016.xls"
    assert blocks[0].night_date == date(2016, 4, 1)
