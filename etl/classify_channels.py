"""
Clasificador de canal: mapea cada `empresa` cruda del histórico a la taxonomía
de reservation_channels (DIRECTO, OTA, AGENCIA, EMPRESA, REFERIDO, EVENTO).

El campo crudo tiene 677 valores mezclando canal + agencia + empresa-convenio +
ruido (montos, formas de pago coladas). Reglas por prioridad; lo que no matchea
queda UNKNOWN (honesto, no se fuerza a una categoría).

Salidas:
  output/channel_alias_map.csv  — empresa_raw, channel_code, n_estadias
  + resumen de cobertura en consola
"""

from __future__ import annotations

import csv
import os
from collections import Counter

BASE = os.path.dirname(__file__)
STG = os.path.join(BASE, "output", "stg_estadias.csv")
OUT = os.path.join(BASE, "output")

# Reglas por prioridad: la primera categoría cuyo patrón matchee gana.
# El orden importa: OTA/AGENCIA/EMPRESA antes que REFERIDO/DIRECTO (más específicos).
CHANNEL_RULES: list[tuple[str, tuple[str, ...]]] = [
    ("EVENTO", ("BODA", "MATRIMONIO", "EVENTO", "QUINCE", "GRADUACION")),
    ("OTA", ("BOOKING", "EXPEDIA", "AIRBNB", "AIR BNB", "DESPEGAR", "HOTELS.COM",
             "TRIVAGO", "ATRAPALO", "HOSTELWORLD", "TRIP", "AGODA")),
    ("AGENCIA", ("TAKUARAL", "TROPICAL", "CUARTA DIMENSION", "ANDAVENTURE",
                 "TOURS", "TOUR", "VIAJES", "TRAVEL", "TURISMO", "AGENCIA",
                 "CRILLON", "BALSA", "MAGRI", "TERRA", "GLORIA", "OPERADOR",
                 "VIVA")),
    ("EMPRESA", ("BANCO", "S.A.", "SRL", "S.R.L", "LTDA", "COOP", "FUNDACION",
                 "FUNDACIÓN", "EMPRESA", "MINISTERIO", "UNIVERSIDAD", "CONVISA",
                 "IMEXCOMED", "COSUDE", "UNION EUROPEA", "HELVETAS", "INTI",
                 "CRECER", "PIL", "COBOL", "ONG", "CAJA", "SEGUROS", "COMPANY",
                 "CORP", "INSTITUTO", "GOBIERNO", "ALCALDIA", "SA ")),
    ("REFERIDO", ("LIC.", "LIC ", "AMIGO", "AMIGA", "CLIENTE", "RECOMEND",
                  "REFERIDO", "CONOCIDO", "SR.", "SRA.", "DR.", "DRA.",
                  "NATY", "NATHY")),
    ("DIRECTO", ("PARTICULAR", "WALK", "DIRECTO", "WEB", "PAGINA", "FACEBOOK",
                 "INSTAGRAM", "WHATSAPP", "REDES", "TELEFONO", "PASAJERO")),
]

# Overrides curados a mano: nombres propios de instituciones/agencias/personas
# que ninguna regla por keyword puede resolver. Fuente: los 81 UNKNOWN de mayor
# volumen (>=8 estadías). Los casos ambiguos se dejaron para revisión del usuario.
ALIAS_OVERRIDES: dict[str, str] = {
    # --- EMPRESA (instituciones, ONGs, universidades, bancos, empresas) ---
    "BIOTECH": "EMPRESA", "CIES": "EMPRESA", "VISION MUNDO": "EMPRESA",
    "GOETHE-INSTITUT": "EMPRESA", "FYP": "EMPRESA", "GIZ": "EMPRESA",
    "VETERQUIMICA": "EMPRESA", "COL. MEDICO SANTA CRUZ": "EMPRESA",
    "IRD": "EMPRESA", "ENDE": "EMPRESA", "EUROFINSA": "EMPRESA",
    "BCP": "EMPRESA", "COLEGIO ALEMAN SCZ": "EMPRESA", "ONU": "EMPRESA",
    "HUMANITARIAN": "EMPRESA", "FIIAP": "EMPRESA", "FELAFACS": "EMPRESA",
    "MANQA": "EMPRESA", "CORTEX": "EMPRESA", "CORTEX BOLIVIA": "EMPRESA",
    "CBM": "EMPRESA", "CRUZ ROJA BOLIVIANA": "EMPRESA", "MARIE STOPES": "EMPRESA",
    "MARIE STOP": "EMPRESA", "AGETIC": "EMPRESA", "IPAS": "EMPRESA",
    "U CATOLICA": "EMPRESA", "CATOLICA": "EMPRESA", "FIAP": "EMPRESA",
    "SAN MIGUEL ABOGADOS": "EMPRESA", "SAN MIGUEL ASOCIADOS": "EMPRESA",
    "PRIETO Y ASOCIADOS": "EMPRESA", "YPFB": "EMPRESA", "VICEPRESIDENCIA": "EMPRESA",
    "BDP": "EMPRESA", "LA SALLE": "EMPRESA", "TEXTIL MODA": "EMPRESA",
    "FEXPO": "EMPRESA", "CBA": "EMPRESA", "MEDICINA INTERNA": "EMPRESA",
    "PRODAC": "EMPRESA", "PMA": "EMPRESA", "NACIONES UNIDAS": "EMPRESA",
    "MERCANTIL SANTA CRUZ": "EMPRESA", "BMSC": "EMPRESA", "BIOQUIMICA": "EMPRESA",
    "COPELME": "EMPRESA", "ONU MUJERES": "EMPRESA", "ANESTESIOLOGIA": "EMPRESA",
    "ICBA": "EMPRESA", "OPTICENTRO": "EMPRESA", "EMBAJADA BRITANICA": "EMPRESA",
    "SAN SIMON": "EMPRESA", "FLAPIA": "EMPRESA", "CAB": "EMPRESA",
    "AZUMIT": "EMPRESA", "COFEMEL": "EMPRESA", "FAIR PLAY": "EMPRESA",
    "LIBOBASQUET": "EMPRESA", "REAL SANTA CRUZ": "EMPRESA", "GRUPO VENENO": "EMPRESA",
    "BANDA ESCOLAR": "EMPRESA", "PLAZA HOTEL": "EMPRESA", "COPELME ": "EMPRESA",
    "FLAPIA ": "EMPRESA", "PLAZA": "EMPRESA",
    # --- AGENCIA (agencias de viaje / DMC / operadores) ---
    "DMC": "AGENCIA", "ANDES DISCOVERY": "AGENCIA", "TRANSTURIN": "AGENCIA",
    "SOUTH AMERICAN PLANET": "AGENCIA", "ANTIPODE": "AGENCIA",
    "DESCUBRE S.T.": "AGENCIA", "DESCUBRE ST": "AGENCIA",
    "ANDADVENTURE": "AGENCIA", "UARTA DIMENSION": "AGENCIA",
    "STARZ INFINITE": "AGENCIA",
    # --- REFERIDO (nombres de persona) ---
    "NATALIA": "REFERIDO", "SUSANA CAMPOS": "REFERIDO", "CYRIL": "REFERIDO",
    "MAURICIO PROD.": "REFERIDO",
    # --- NOISE ---
    "PAGADO": "NOISE", "BOOINK INVERSIONES": "UNKNOWN",  # ambiguo, revisar
    "ZEPPELIN": "UNKNOWN", "CORTEX ": "EMPRESA",  # ZEPPELIN ambiguo (bar/agencia?)
}

# Ruido: formas de pago o montos que se colaron en la columna empresa.
PAYMENT_NOISE = ("EFECTIVO", "TARJETA", "CXC", "DEPOSITO", "DEPÓSITO",
                 "TRANSFERENCIA", "QR", "C/C", "ATC")


def classify(raw: str) -> str:
    s = raw.upper().strip()
    if not s or s in ("NAN", "NONE"):
        return "UNKNOWN"
    if s in ALIAS_OVERRIDES:  # curaduría manual gana sobre reglas
        return ALIAS_OVERRIDES[s]
    # un número solo = monto colado, no es canal
    if s.replace(".", "").replace(",", "").isdigit():
        return "NOISE"
    if any(s == p or s.startswith(p) for p in PAYMENT_NOISE):
        return "NOISE"
    for code, pats in CHANNEL_RULES:
        if any(p in s for p in pats):
            return code
    return "UNKNOWN"


def run() -> None:
    rows = list(csv.DictReader(open(STG, encoding="utf-8")))
    counts: Counter[str] = Counter()
    for r in rows:
        ch = (r["channel"] or "").upper().strip()
        if ch:
            counts[ch] += 1

    mapping = {raw: classify(raw) for raw in counts}

    # CSV de mapeo para auditoría humana.
    path = os.path.join(OUT, "channel_alias_map.csv")
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["empresa_raw", "channel_code", "n_estadias"])
        for raw, n in counts.most_common():
            w.writerow([raw, mapping[raw], n])

    # Cobertura por VOLUMEN (estadías), que es lo que importa, no por # de valores.
    by_code_vol: Counter[str] = Counter()
    by_code_distinct: Counter[str] = Counter()
    for raw, n in counts.items():
        by_code_vol[mapping[raw]] += n
        by_code_distinct[mapping[raw]] += 1

    total_vol = sum(counts.values())
    total_distinct = len(counts)
    print(f"empresas distintas: {total_distinct} | estadías con canal: {total_vol:,}\n")
    print(f"{'canal':<10} {'estadías':>9} {'% vol':>7} {'valores':>8}")
    for code, vol in by_code_vol.most_common():
        print(f"{code:<10} {vol:>9,} {100*vol/total_vol:>6.1f}% {by_code_distinct[code]:>8}")

    unknown_vol = by_code_vol["UNKNOWN"] + by_code_vol["NOISE"]
    print(f"\nCobertura clasificada: {100*(total_vol-unknown_vol)/total_vol:.1f}% del volumen")
    print(f"Mapeo escrito en {path}")

    # Muestra los UNKNOWN de mayor volumen: candidatos a agregar reglas.
    unknowns = [(raw, n) for raw, n in counts.most_common()
                if mapping[raw] == "UNKNOWN"]
    print(f"\nTop UNKNOWN (candidatos a regla), {len(unknowns)} valores:")
    for raw, n in unknowns[:20]:
        print(f"  {n:>4}  {raw}")


if __name__ == "__main__":
    run()
