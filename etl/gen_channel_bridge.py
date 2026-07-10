"""
Generador de la migración de la tabla puente empresa_cruda -> reservation_channel.

Lee output/channel_alias_map.csv y emite una migración SQL idempotente que crea
`channel_aliases` y la siembra con los alias que resuelven a un canal válido.
Los UNKNOWN/NOISE se excluyen (no tienen canal al que apuntar).

Regenerable: si se ajustan las reglas/overrides, se re-corre y se re-emite.
"""

from __future__ import annotations

import csv
import os

BASE = os.path.dirname(__file__)
MAP = os.path.join(BASE, "output", "channel_alias_map.csv")
MIGRATION = os.path.join(
    BASE, "..", "supabase", "migrations",
    "20260703140000_seed_channel_aliases.sql",
)
VALID = {"DIRECTO", "OTA", "AGENCIA", "EMPRESA", "REFERIDO", "EVENTO"}


def sql_str(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


def run() -> None:
    rows = [r for r in csv.DictReader(open(MAP, encoding="utf-8"))
            if r["channel_code"] in VALID]
    rows.sort(key=lambda r: (r["channel_code"], -int(r["n_estadias"])))

    covered = sum(int(r["n_estadias"]) for r in rows)
    values = ",\n".join(
        f"  ({sql_str(r['empresa_raw'])}, '{r['channel_code']}')" for r in rows
    )

    sql = f"""-- =====================================================================
-- Tabla puente: empresa cruda del histórico -> canal (reservation_channels).
-- Generado por etl/gen_channel_bridge.py desde etl/output/channel_alias_map.csv.
-- {len(rows)} alias que cubren {covered:,} estadías. UNKNOWN/NOISE excluidos.
-- NO editar a mano: regenerar con el script si cambian reglas/overrides.
-- Idempotente (on conflict do nothing).
-- =====================================================================

create table if not exists public.channel_aliases (
  raw_name     varchar(120) primary key,
  channel_code varchar(20) not null references public.reservation_channels(code)
);
create index if not exists idx_channel_aliases_code
  on public.channel_aliases (channel_code);

insert into public.channel_aliases (raw_name, channel_code) values
{values}
on conflict (raw_name) do nothing;

-- RLS: catálogo de referencia, mismo patrón permisivo de fase dev.
alter table public.channel_aliases enable row level security;
create policy "dev_all_channel_aliases"
  on public.channel_aliases for all using (true) with check (true);
"""
    with open(MIGRATION, "w", encoding="utf-8") as fh:
        fh.write(sql)
    print(f"Migración escrita: {os.path.normpath(MIGRATION)}")
    print(f"  {len(rows)} alias, {covered:,} estadías cubiertas")


if __name__ == "__main__":
    run()
