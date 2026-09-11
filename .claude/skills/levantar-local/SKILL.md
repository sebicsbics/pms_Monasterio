---
name: levantar-local
description: "Trigger: levantar local, ambiente local, sandbox, run the app, arrancar servidores, pruebas locales. Levanta Docker, Supabase local y el frontend de pms-hotel."
license: Apache-2.0
metadata:
  author: sebicsbics
  version: "1.0"
---

## Activation Contract

Usar cuando el usuario pide levantar el ambiente local de pms-hotel para probar, o antes de validar un cambio en su sandbox.

## Hard Rules

- Todo pasa por `scripts/local-up.sh`; no reimplementar los pasos a mano.
- Nunca tocar el proyecto remoto (`--linked`, `db push`, MCP de Supabase) en este flujo.
- Nunca pasar `--reset` sin que el usuario lo pida: borra los datos locales.
- El frontend usa `npm run dev:qa` (`.env.qa`); no editar ni leer `.env.local`.

## Decision Gates

| Pedido | Acción |
|---|---|
| Levantar todo (default) | Paso 1 + Paso 2 |
| Solo backend / base | Solo Paso 1 |
| "Resetear", "base limpia", "cargar seed" | Paso 1 con `--reset` |
| El script falla en Docker | Pedir al usuario que abra Docker Desktop o active la integración WSL |

## Execution Steps

1. Ejecutar `bash scripts/local-up.sh --no-frontend` (timeout ≥ 10 min). Es idempotente: reutiliza lo que ya esté arriba y aplica migraciones pendientes con `migration up --local`.
2. Ejecutar `npm run dev:qa` con `run_in_background`, luego leer su salida hasta ver la URL de Vite.
3. Si un paso falla, mostrar el error textual y detenerse; no improvisar workarounds sobre el remoto.

## Output Contract

Reportar en una tabla corta: URL del frontend, Studio (`:54323`), Mailpit (`:54324`), estado de migraciones (al día / N aplicadas / reset), y los usuarios seed (`root`, `admin`, `recepcion`, `contadora`, `duenio`, clave `local1234`). Indicar cómo detener: `npx supabase stop`.

## References

- `README.md` — sección "Opción A — entorno local completo" y "QA local rápido".
- `scripts/local-up.sh` — implementación del flujo.
