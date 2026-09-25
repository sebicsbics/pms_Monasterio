# ETL — Datos históricos del hotel

Pipeline que convierte los archivos `md/*.md` (exportados de Excel, con drift de
formato año a año) en datos limpios y canónicos.

## Datos personales (PII)

Los insumos (`md/`, `Hotel/`) y todo `etl/output/` llevan nombres de huéspedes y
están en `.gitignore`: viven solo en la máquina de quien corre el ETL. Las
migraciones de `supabase/migrations/` llevan **solo esquema**; los datos se
cargan con un SQL generado en `etl/output/`, nunca con una migración.

## Extractor del archivo histórico (`Hotel/`, 2013-2017)

`Hotel/` es un árbol separado de `md/`: contiene el archivo físico del hotel
(huéspedes, caja, telefonía, frigobar, informes) escaneado por año/familia.
Antes de parsear nada, el extractor recorre el árbol y calcula un inventario:

```bash
etl/.venv/bin/python -m etl.extractor.inventory
```

Produce `etl/output/inventory.json` (gitignorado, con PII: rutas de archivos
reales) con una fila por archivo: `path`, `md5`, `size`, `family`, `year`,
`is_canonical`, `reason`.

Reglas de precedencia (documentadas y testeadas en `etl/tests/test_inventory.py`):

- **Duplicados byte-idénticos** (mismo md5, ej. mirror 2015→2016): se procesa
  uno solo (el más antiguo), el resto queda `is_canonical=false`,
  `reason="duplicate_of_identical_hash"`.
- **Variantes sin hash idéntico** dentro de la misma familia+año (ej. 3
  versiones de frigobar): NO se resuelven en automático. Quedan
  `is_canonical=false`, `reason="needs_manual_review"` para reconciliación
  manual en un PR posterior.
- **Guard de PII**: ninguna función de `etl/extractor/inventory.py` escribe
  fuera de `etl/output/`; un intento de escribir afuera lanza
  `OutputPathViolation` antes de tocar el filesystem.

## Capa canónica: `stg_estadias`

`python3 etl/stg_estadias.py`

Lee `md/Lista de Llegadas*.md` y produce **una fila por estadía**:

- `output/stg_estadias.csv` — dataset canónico (7.782 estadías, 2015–2025).
- `output/stg_estadias_quality.txt` — reporte de calidad por flag.

### Reglas de transformación (documentadas en el código)

| # | Regla | Por qué |
|---|-------|---------|
| 0 | Fechas fuera de 2015–2026 se anulan | typos crudos (1900, 5025) |
| 1 | Fila sin nombre ni fechas → se descarta | relleno de plantilla (Excel) |
| 2 | Corregir año de checkout solo si da ≤60 noches | no inventar estadías de 335 noches |
| 3 | `nights` SIEMPRE recalculado desde fechas | el guardado se corrompe con checkout vacío (serial de Excel) |
| 4 | `total` reportado solo si 0–100k, si no `tarifa×noches` | cascada de corrupción deja millones negativos |
| 5 | Forma de pago normalizada a catálogo | DEPÓSITO/DEPOSITO, CXC/C/C, etc. |
| 6 | País en mayúsculas + flag multi-huésped | 46% de celdas tienen varios nombres |

### Filosofía

Lo dudoso **no se borra en silencio, se etiqueta** en `quality_flags`. Cada
consumidor (app o análisis) decide qué filtrar según su tolerancia.

## Capa analítica: `analytics`

`python3 etl/analytics.py`

Consume `stg_estadias.csv` (acá SÍ con pandas: son agregaciones) y produce en
`output/analytics/`:

| Tabla | Contenido |
|-------|-----------|
| `revenue_by_year` | ingreso, estadías, noches, ADR por año |
| `occupancy_by_year` | tasa de ocupación (sobre 36 hab); marca años parciales |
| `seasonality` | estadías/noches/ingreso por mes (todos los años) |
| `channel_mix` | estadías, ingreso y ticket medio por canal de venta |
| `country_mix` | origen del huésped (solo poblado en años recientes) |
| `payment_mix` | forma de pago canónica; combos → `MIXTO` |
| `room_performance` | estadías, noches, ingreso y ADR por habitación |

Cada tabla se calcula sobre su universo válido (revenue solo con `total_bs`,
ocupación solo con noches+habitación). Nunca se infla con filas incompletas.

## Seeds derivados para la app

- **`rooms`**: NO se puebla desde el ETL — ya es un maestro completo y validado
  (las 36 habitaciones tienen historia; 0 sin uso). El ETL solo aporta el flag
  `room_invalid` para no atribuir ingreso a habitaciones fantasma (typos/montos).
- **Catálogos** (`supabase/migrations/20260703130000_seed_channels_and_payments.sql`):
  - `reservation_channels` — taxonomía de 6 tipos (DIRECTO, OTA, AGENCIA,
    EMPRESA, REFERIDO, EVENTO). Las 677 `empresa` crudas mapean a estas categorías.
  - `payment_methods` — 10 formas canónicas (AIRBNB excluido: era un canal).

## Tabla puente: empresa cruda → canal

`python3 etl/classify_channels.py`   → clasifica las 677 `empresa` y escribe
`output/channel_alias_map.csv` (auditable). Cobertura ~84% del volumen:
reglas por keyword + `ALIAS_OVERRIDES` curados a mano para nombres propios.

`python3 etl/gen_channel_bridge.py`  → genera desde ese CSV la migración
`supabase/migrations/20260703140000_seed_channel_aliases.sql` (tabla
`channel_aliases`, 262 alias, FK a `reservation_channels`). Regenerable: si se
ajustan reglas/overrides, re-correr ambos scripts.

El ~16% restante (UNKNOWN/NOISE) es cola larga de singletons; se resuelve con
conocimiento de dominio, no con más reglas.

## Capa de presentación (dashboard en el app)

Los datos llegan al app vía Supabase (NO se leen los CSV en el front):

1. La migración `20260703150000` crea `historical_stays` (solo esquema);
   `20260925000000` le agrega la columna `source` (default `'md'`) para poder
   cargar/rollback por fuente sin truncar la tabla completa (PR3a).
   `python3 -m etl.gen_historical_stays --source {md,hotel_archive}` genera,
   vía `etl/loader.py` (loader genérico, reusado por fuentes futuras), la
   carga de datos de esa fuente en
   `etl/output/load_historical_stays_<source>.sql`, y se aplica aparte:

   ```bash
   # local (Supabase CLI)
   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
     -v ON_ERROR_STOP=1 -f etl/output/load_historical_stays_md.sql
   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
     -v ON_ERROR_STOP=1 -f etl/output/load_historical_stays_hotel_archive.sql
   ```

   Cada archivo es idempotente por fuente (`delete from historical_stays
   where source = '<source>'` + inserts, en una transacción) — nunca
   `truncate`, así una fuente no se pisa con otra. Rollback de una fuente:
   `delete from historical_stays where source = '<source>'`.

   `--source hotel_archive` primero deduplica localmente (sin tocar la DB)
   contra `etl/output/stg_estadias.csv` (md): estadías con la misma `room`
   y rango `[check_in, check_out)` que se solapa con una estadía de md se
   excluyen (md siempre gana, ya es el dataset cargado y canónico) y quedan
   documentadas en `etl/output/dedupe_report.csv`. El solape real cae en
   2015-2016 (md arranca en 2015).
2. `supabase/migrations/20260703160000_analytics_views.sql` → 7 vistas `v_*` que
   replican `analytics.py` en SQL (cálculo en vivo), con grants a anon/authenticated.
3. App: `src/services/analytics.ts` (fetch de las vistas), `src/features/analytics/`
   (`Dashboard.tsx` con Recharts + `palette.ts` validada por la skill dataviz).
   Tab "Analítica" (rol root/accountant), lazy-loaded para no cargar Recharts a todos.

## Placeholders de estado en `Hotel/` (Slice 2b, `guest_stays.py`)

Algunas hojas de huéspedes tienen el ESTADO de la habitación (bloqueada, por
habilitar, en depósito, ocupada sin nombre) escrito en la columna de nombre.
`etl/parsers/room_blocks.py` los separa antes de fusionar noches en estadías
(`etl/output/stg_room_blocks.csv`), con reglas generales por primera palabra
(BLOQUE\*/BLOC, HABILITAR, FALTA, DEPOSITO, OCUPADO, RESERVAD\*) más una lista
curada a mano (`ROOM_STATUS_OVERRIDES`) para casos puntuales, igual patrón
que `ALIAS_OVERRIDES` en `classify_channels.py`.

Para agregar un caso nuevo después de correr el pipeline:

1. `etl/.venv/bin/python -m etl.parsers.guest_stays` y mirar el "Top 20
   guest_name" del resumen — ahí aparecen los nombres más repetidos entre
   las estadías que quedaron.
2. Si es texto de estado no cubierto por las reglas generales, agregar una
   entrada a `ROOM_STATUS_OVERRIDES` en `room_blocks.py` con el texto en
   MAYÚSCULAS sin acentos/puntuación (ver `_normalize_status_text`) y la
   razón de bloqueo (`blocked`/`to_prepare`/`storage`/`occupied_unnamed`/
   `reserved`, o una nueva si hace falta).
3. Si en cambio es un huésped real pero no-persona (delegación, evento,
   cuarto propio del hotel), usar el veredicto `"GUEST"`: no se excluye de
   las estadías, pero queda flaggeado `name_not_person` en
   `quality_flags`.
4. Agregar un test en `etl/tests/test_room_blocks.py` (fixture sintética,
   nunca datos reales) y correr `pytest etl/tests` antes de volver a
   correr el pipeline real.

## Próximas capas (pendientes)

- Curar la cola larga UNKNOWN (ZEPPELIN, BOOINK, etc.) con criterio del hotel.
- `Planning de Reserva` (pivot de texto libre) — fase 2, bajo valor.
