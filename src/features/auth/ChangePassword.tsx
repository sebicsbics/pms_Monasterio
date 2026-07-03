import { useState } from 'react'
import { changePassword, signOut } from '../../services/auth'

// Pantalla obligatoria en el primer ingreso: reemplazar la contraseña genérica.
export function ChangePassword({ onDone }: { onDone: () => void }) {
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (password.length < 6) {
      setError('La contraseña debe tener al menos 6 caracteres')
      return
    }
    if (password !== confirm) {
      setError('Las contraseñas no coinciden')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await changePassword(password)
      onDone()
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
        <h1 className="mb-1 text-xl font-bold text-slate-800">
          Cambiá tu contraseña
        </h1>
        <p className="mb-6 text-sm text-slate-500">
          Es tu primer ingreso: reemplazá la contraseña genérica por una tuya.
        </p>

        {error && (
          <p className="mb-4 rounded bg-red-50 p-2 text-sm text-red-700">
            {error}
          </p>
        )}

        <label className="mb-3 block text-sm">
          <span className="text-slate-600">Nueva contraseña</span>
          <input
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            className="mt-1 w-full rounded border border-slate-300 p-2"
            autoComplete="new-password"
            required
          />
        </label>
        <label className="mb-5 block text-sm">
          <span className="text-slate-600">Repetir contraseña</span>
          <input
            type="password"
            value={confirm}
            onChange={(e) => setConfirm(e.target.value)}
            className="mt-1 w-full rounded border border-slate-300 p-2"
            autoComplete="new-password"
            required
          />
        </label>

        <button
          type="submit"
          disabled={busy}
          className="w-full rounded bg-blue-600 py-2 font-medium text-white hover:bg-blue-700 disabled:opacity-50"
        >
          {busy ? 'Guardando…' : 'Guardar y continuar'}
        </button>
        <button
          type="button"
          onClick={() => signOut()}
          className="mt-3 w-full text-sm text-slate-500 hover:underline"
        >
          Salir
        </button>
      </form>
    </div>
  )
}
