"""
Capa analítica del ETL del hotel.

Consume la capa canónica (etl/output/stg_estadias.csv) y produce tablas de
negocio listas para reporting/BI. Acá SÍ usamos pandas: son agregaciones.

Honestidad de datos:
  - Revenue: solo filas con total_bs válido (reported o recomputed).
  - Ocupación/ADR: solo filas con noches y habitación.
  - Cada tabla dice sobre qué universo se calculó.

Salidas en etl/output/analytics/*.csv + un resumen en consola.
"""

from __future__ import annotations

import calendar
import os

import pandas as pd

BASE = os.path.dirname(__file__)
STG = os.path.join(BASE, "output", "stg_estadias.csv")
OUT = os.path.join(BASE, "output", "analytics")

TOTAL_ROOMS = 36  # DETALLE_DE_HABITACIONES.md
MESES = ["", "Ene", "Feb", "Mar", "Abr", "May", "Jun",
         "Jul", "Ago", "Sep", "Oct", "Nov", "Dic"]


def load() -> pd.DataFrame:
    df = pd.read_csv(STG, parse_dates=["check_in", "check_out"])
    df["year"] = df["check_in"].dt.year
    df["month"] = df["check_in"].dt.month
    df["quality_flags"] = df["quality_flags"].fillna("")
    df["room_ok"] = ~df["quality_flags"].str.contains("room_invalid")
    return df


def _save(df: pd.DataFrame, name: str) -> None:
    df.to_csv(os.path.join(OUT, f"{name}.csv"), index=False)


def revenue_by_year(df: pd.DataFrame) -> pd.DataFrame:
    """Ingreso, estadías, noches y ADR por año. ADR = ingreso / noches-hab."""
    rev = df[df["total_bs"].notna()].copy()
    g = rev.groupby("year").agg(
        estadias=("total_bs", "size"),
        ingreso_bs=("total_bs", "sum"),
        noches=("nights", "sum"),
        pax=("pax", "sum"),
    ).reset_index()
    # ADR indefinido si no hay noches (evita inf por división por cero).
    g["adr_bs"] = (g["ingreso_bs"] / g["noches"]).round(0)
    g.loc[g["noches"] == 0, "adr_bs"] = pd.NA
    g["ingreso_bs"] = g["ingreso_bs"].round(0)
    return g


def occupancy_by_year(df: pd.DataFrame) -> pd.DataFrame:
    """Tasa de ocupación = noches-hab vendidas / (36 hab * días del año).

    Los años parciales (primero y último del dataset) se marcan: la tasa real
    es mayor porque no cubren los 365 días.
    """
    occ = df[df["nights"].notna() & df["room"].notna() & df["room_ok"]].copy()
    g = occ.groupby("year").agg(noches_vendidas=("nights", "sum")).reset_index()
    g["dias_anio"] = g["year"].apply(lambda y: 366 if calendar.isleap(int(y)) else 365)
    g["capacidad"] = TOTAL_ROOMS * g["dias_anio"]
    g["ocupacion_pct"] = (100 * g["noches_vendidas"] / g["capacidad"]).round(1)
    ymin, ymax = g["year"].min(), g["year"].max()
    g["parcial"] = g["year"].isin([ymin, ymax])
    return g[["year", "noches_vendidas", "capacidad", "ocupacion_pct", "parcial"]]


def seasonality(df: pd.DataFrame) -> pd.DataFrame:
    """Estacionalidad: estadías, noches e ingreso por mes (todos los años)."""
    s = df[df["month"].notna()].copy()
    g = s.groupby("month").agg(
        estadias=("month", "size"),
        noches=("nights", "sum"),
        ingreso_bs=("total_bs", "sum"),
    ).reset_index()
    g["mes"] = g["month"].astype(int).map(lambda m: MESES[m])
    g["ingreso_bs"] = g["ingreso_bs"].round(0)
    return g[["month", "mes", "estadias", "noches", "ingreso_bs"]]


def channel_mix(df: pd.DataFrame, top: int = 15) -> pd.DataFrame:
    """Mix de canal de venta: estadías, ingreso y ticket medio por canal."""
    c = df[df["channel"].notna()].copy()
    c["channel"] = c["channel"].str.upper().str.strip()
    g = c.groupby("channel").agg(
        estadias=("channel", "size"),
        ingreso_bs=("total_bs", "sum"),
    ).reset_index()
    g["ticket_medio_bs"] = (g["ingreso_bs"] / g["estadias"]).round(0)
    g["ingreso_bs"] = g["ingreso_bs"].round(0)
    g["pct_estadias"] = (100 * g["estadias"] / len(c)).round(1)
    return g.sort_values("estadias", ascending=False).head(top).reset_index(drop=True)


def country_mix(df: pd.DataFrame, top: int = 15) -> pd.DataFrame:
    """Origen del huésped. Nota: país solo poblado en años recientes."""
    c = df[df["country"].notna()].copy()
    c["country"] = c["country"].str.upper().str.strip()
    g = c.groupby("country").agg(estadias=("country", "size")).reset_index()
    g["pct"] = (100 * g["estadias"] / len(c)).round(1)
    return g.sort_values("estadias", ascending=False).head(top).reset_index(drop=True)


def payment_mix(df: pd.DataFrame) -> pd.DataFrame:
    """Mix de forma de pago (canónico). Excluye faltantes."""
    p = df[df["payment"].notna()].copy()
    g = p.groupby("payment").agg(
        estadias=("payment", "size"),
        ingreso_bs=("total_bs", "sum"),
    ).reset_index()
    g["pct"] = (100 * g["estadias"] / len(p)).round(1)
    g["ingreso_bs"] = g["ingreso_bs"].round(0)
    return g.sort_values("estadias", ascending=False).reset_index(drop=True)


def room_performance(df: pd.DataFrame) -> pd.DataFrame:
    """Rendimiento por habitación: estadías, noches, ingreso, ADR."""
    r = df[df["room"].notna() & df["room_ok"]].copy()
    r["room"] = r["room"].astype(int)
    g = r.groupby("room").agg(
        estadias=("room", "size"),
        noches=("nights", "sum"),
        ingreso_bs=("total_bs", "sum"),
    ).reset_index()
    g["adr_bs"] = (g["ingreso_bs"] / g["noches"]).round(0)
    g["ingreso_bs"] = g["ingreso_bs"].round(0)
    return g.sort_values("ingreso_bs", ascending=False).reset_index(drop=True)


def run() -> None:
    os.makedirs(OUT, exist_ok=True)
    df = load()

    tables = {
        "revenue_by_year": revenue_by_year(df),
        "occupancy_by_year": occupancy_by_year(df),
        "seasonality": seasonality(df),
        "channel_mix": channel_mix(df),
        "country_mix": country_mix(df),
        "payment_mix": payment_mix(df),
        "room_performance": room_performance(df),
    }
    for name, t in tables.items():
        _save(t, name)

    pd.set_option("display.max_rows", 40, "display.width", 120)
    print(f"Universo: {len(df):,} estadías\n")
    print("=== INGRESO Y ADR POR AÑO ===")
    print(tables["revenue_by_year"].to_string(index=False))
    print("\n=== OCUPACIÓN POR AÑO (parcial=no cubre 365 días) ===")
    print(tables["occupancy_by_year"].to_string(index=False))
    print("\n=== ESTACIONALIDAD ===")
    print(tables["seasonality"].to_string(index=False))
    print("\n=== MIX DE CANAL (top 15) ===")
    print(tables["channel_mix"].to_string(index=False))
    print("\n=== MIX DE PAGO ===")
    print(tables["payment_mix"].to_string(index=False))
    print("\n=== TOP HABITACIONES POR INGRESO ===")
    print(tables["room_performance"].head(10).to_string(index=False))
    print(f"\nTablas guardadas en {OUT}/")


if __name__ == "__main__":
    run()
