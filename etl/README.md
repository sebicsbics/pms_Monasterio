# ETL — Datos históricos del hotel

Pipeline que convierte los archivos `md/*.md` (exportados de Excel, con drift de
formato año a año) en datos limpios y canónicos.

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

1. `python3 etl/gen_historical_stays.py` → migración `20260703150000` que crea
   y carga `historical_stays` (7.782 estadías).
2. `supabase/migrations/20260703160000_analytics_views.sql` → 7 vistas `v_*` que
   replican `analytics.py` en SQL (cálculo en vivo), con grants a anon/authenticated.
3. App: `src/services/analytics.ts` (fetch de las vistas), `src/features/analytics/`
   (`Dashboard.tsx` con Recharts + `palette.ts` validada por la skill dataviz).
   Tab "Analítica" (rol root/accountant), lazy-loaded para no cargar Recharts a todos.

## Próximas capas (pendientes)

- Curar la cola larga UNKNOWN (ZEPPELIN, BOOINK, etc.) con criterio del hotel.
- `Planning de Reserva` (pivot de texto libre) — fase 2, bajo valor.
