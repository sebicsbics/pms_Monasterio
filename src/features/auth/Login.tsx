import { useState } from 'react'
import { signIn } from '../../services/auth'

export function Login() {
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    try {
      await signIn(username.trim(), password)
      // onAuthStateChange en App detecta la sesión y entra.
    } catch (err) {
      setError((err as Error).message)
      setBusy(false)
    }
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-slate-100">
      <form
        onSubmit={handleSubmit}
        className="w-full max-w-sm rounded-lg border border-slate-200 bg-white p-8 shadow-sm"
      >
        <h1 className="mb-1 text-2xl font-bold text-slate-800">
          PMS Hotel Monasterio
        </h1>
        <p className="mb-6 text-sm text-slate-500">Ingresá con tu cuenta</p>

        {error && (
          <p className="mb-4 rounded bg-red-50 p-2 text-sm text-red-700">
            {error}
          </p>
        )}

        <label className="mb-3 block text-sm">
          <span className="text-slate-600">Usuario</span>
          <input
            type="text"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            className="mt-1 w-full rounded border border-slate-300 p-2"
            autoComplete="username"
            required
          />
        </label>
        <label className="mb-5 block text-sm">
          <span className="text-slate-600">Contraseña</span>
          <input
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            className="mt-1 w-full rounded border border-slate-300 p-2"
            required
          />
        </label>

        <button
          type="submit"
          disabled={busy}
          className="w-full rounded bg-blue-600 py-2 font-medium text-white hover:bg-blue-700 disabled:opacity-50"
        >
          {busy ? 'Ingresando…' : 'Ingresar'}
        </button>
      </form>
    </div>
  )
}
