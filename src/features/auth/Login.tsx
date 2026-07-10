import { useEffect, useMemo, useRef, useState } from 'react'
import { signIn } from '../../services/auth'

// Fondos optimizados en public/login-bg/bg-01.webp … bg-31.webp.
const BG_COUNT = 31
const ROTATE_MS = 8000

function bgUrl(n: number): string {
  return `/login-bg/bg-${String(n).padStart(2, '0')}.webp`
}

export function Login() {
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  // Orden aleatorio de las fotos, fijo mientras la pantalla está abierta.
  const order = useMemo(() => {
    const a = Array.from({ length: BG_COUNT }, (_, i) => i + 1)
    for (let i = a.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1))
      ;[a[i], a[j]] = [a[j], a[i]]
    }
    return a
  }, [])

  const [pos, setPos] = useState(0)
  const prevPos = useRef(0)

  useEffect(() => {
    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    if (reduce) return // sin rotación si el usuario pide menos movimiento
    const id = setInterval(() => {
      setPos((p) => {
        prevPos.current = p
        return (p + 1) % order.length
      })
    }, ROTATE_MS)
    return () => clearInterval(id)
  }, [order.length])

  // Precarga la siguiente foto para que el fundido no muestre un salto.
  useEffect(() => {
    const next = new Image()
    next.src = bgUrl(order[(pos + 1) % order.length])
  }, [pos, order])

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    try {
      await signIn(username.trim(), password)
    } catch (err) {
      setError((err as Error).message)
      setBusy(false)
    }
  }

  return (
    <div className="relative flex min-h-dvh items-center justify-center overflow-hidden bg-slate-900">
      {/* Fondo rotativo: capa previa (estática) + capa actual (fundido) */}
      <img
        src={bgUrl(order[prevPos.current])}
        alt=""
        aria-hidden
        className="absolute inset-0 h-full w-full object-cover"
      />
      <img
        key={pos}
        src={bgUrl(order[pos])}
        alt=""
        aria-hidden
        className="bg-fade absolute inset-0 h-full w-full object-cover"
      />
      {/* Scrim para legibilidad del formulario sobre fotos claras */}
      <div className="absolute inset-0 bg-gradient-to-br from-slate-900/60 via-slate-900/30 to-slate-900/60" />

      {/* Tarjeta de login (vidrio esmerilado) */}
      <form
        onSubmit={handleSubmit}
        className="relative z-10 m-4 w-full max-w-sm rounded-3xl border border-white/30 bg-white/55 p-8 shadow-2xl ring-1 ring-white/20 backdrop-blur-2xl backdrop-saturate-150"
      >
        <div className="mb-6 flex flex-col items-center">
          <img src="/brand/logo-full.png" alt="Hotel Monasterio" className="h-24 w-auto" />
          <p className="mt-2 text-sm text-slate-500">Sistema de gestión</p>
        </div>

        {error && (
          <p className="mb-4 rounded-lg bg-red-50 p-2 text-sm text-red-700" role="alert">
            {error}
          </p>
        )}

        <label className="mb-3 block text-sm" htmlFor="login-user">
          <span className="font-medium text-slate-700">Usuario</span>
          <input
            id="login-user"
            type="text"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            className="mt-1 w-full rounded-xl border border-white/50 bg-white/60 p-2.5 backdrop-blur-sm placeholder:text-slate-400 focus:bg-white/80"
            autoComplete="username"
            required
          />
        </label>
        <label className="mb-5 block text-sm" htmlFor="login-pass">
          <span className="font-medium text-slate-700">Contraseña</span>
          <input
            id="login-pass"
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            className="mt-1 w-full rounded-xl border border-white/50 bg-white/60 p-2.5 backdrop-blur-sm placeholder:text-slate-400 focus:bg-white/80"
            autoComplete="current-password"
            required
          />
        </label>

        <button
          type="submit"
          disabled={busy}
          className="w-full rounded-xl border border-white/15 bg-slate-800/80 py-2.5 font-medium text-white shadow-lg backdrop-blur-md transition-colors hover:bg-slate-800/95 disabled:opacity-50"
        >
          {busy ? 'Ingresando…' : 'Ingresar'}
        </button>
      </form>
    </div>
  )
}
