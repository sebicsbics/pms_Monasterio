#!/usr/bin/env bash
# Levanta el sandbox local: Docker → Supabase local → migraciones pendientes → frontend (dev:qa).
# Idempotente: si algo ya está arriba, lo reutiliza. Nunca toca el proyecto remoto.
#
# Uso:
#   bash scripts/local-up.sh                  # todo, frontend en primer plano
#   bash scripts/local-up.sh --no-frontend    # solo backend (Docker + Supabase + migraciones)
#   bash scripts/local-up.sh --reset          # db reset: esquema desde cero + seed (BORRA datos locales)
set -euo pipefail
cd "$(dirname "$0")/.."

FRONTEND=1
RESET=0
for arg in "$@"; do
  case "$arg" in
    --no-frontend) FRONTEND=0 ;;
    --reset) RESET=1 ;;
    *) echo "Opción desconocida: $arg" >&2; exit 2 ;;
  esac
done

sb() { npx --no-install supabase "$@" 2> >(grep -v -i 'npm notice' >&2); }

wait_for() { # wait_for <segundos> <descripción> <comando...>
  local secs=$1 desc=$2; shift 2
  for ((i = 0; i < secs; i += 5)); do
    if "$@" >/dev/null 2>&1; then echo "✓ $desc (~${i}s)"; return 0; fi
    sleep 5
  done
  echo "✗ $desc no respondió en ${secs}s" >&2
  return 1
}

# 1. Docker (Docker Desktop en Windows, visto desde WSL)
if ! docker info >/dev/null 2>&1; then
  DD="/mnt/c/Program Files/Docker/Docker/Docker Desktop.exe"
  if [[ -x "$DD" ]]; then
    echo "→ Arrancando Docker Desktop…"
    "$DD" >/dev/null 2>&1 &
  else
    echo "✗ Docker no está corriendo y no encuentro Docker Desktop. Arrancalo a mano." >&2
    exit 1
  fi
  wait_for 200 "Docker" docker info
else
  echo "✓ Docker ya estaba arriba"
fi

# 2. Supabase local (los contenedores pueden estar arrancando solos tras reiniciar Docker)
if ! sb status >/dev/null 2>&1; then
  echo "→ Levantando Supabase local…"
  sb start >/dev/null 2>&1 || true   # "already running" si los contenedores ya existen
  wait_for 240 "Supabase local" sb status
else
  echo "✓ Supabase local ya estaba arriba"
fi

# 3. Esquema
if [[ $RESET -eq 1 ]]; then
  echo "→ db reset (migraciones desde cero + seed)…"
  sb db reset
else
  pending=$(sb migration list --local 2>/dev/null | { grep -o '"remote":""' || true; } | wc -l)
  if [[ $pending -gt 0 ]]; then
    echo "→ $pending migración(es) pendiente(s) en local; aplicando sin borrar datos…"
    sb migration up --local
  else
    echo "✓ Migraciones locales al día"
  fi
fi

cat <<'EOF'

  Supabase API  http://127.0.0.1:54321
  Studio        http://127.0.0.1:54323
  Mailpit       http://127.0.0.1:54324
  Usuarios seed root / admin / recepcion / contadora / duenio — clave local1234
EOF

# 4. Frontend contra el stack local (.env.qa; .env.local sigue apuntando a la nube)
if [[ $FRONTEND -eq 1 ]]; then
  echo
  exec npm run dev:qa
fi
