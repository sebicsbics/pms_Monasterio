import { useCallback, useEffect, useState } from 'react'
import type { InfoNote } from '../../domain/info/infoNote'
import { fetchInfoNotes, createInfoNote, resolveInfoNote } from '../../services/infoNotes'
import { PageHeader } from '../../components/ui'
import { formatDateTime } from '../../lib/date'

export function InfoLogView() {
  const [notes, setNotes] = useState<InfoNote[]>([])
  const [content, setContent] = useState('')
  const [search, setSearch] = useState('')
  const [from, setFrom] = useState('')
  const [to, setTo] = useState('')
  const [includeResolved, setIncludeResolved] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const reload = useCallback(() => {
    return fetchInfoNotes({ search, from, to, includeResolved })
      .then(setNotes)
      .catch((e: Error) => setError(e.message))
  }, [search, from, to, includeResolved])

  useEffect(() => {
    void reload()
  }, [reload])

  async function handleCreate() {
    if (!content.trim()) {
      setError('Escribí la información a registrar')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await createInfoNote(content)
      setContent('')
      await reload()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  async function handleResolve(note: InfoNote) {
    const detail = window.prompt(
      'Detalle del cierre (ej. quién retiró el objeto). Opcional:',
      '',
    )
    // prompt devuelve null si cancelan → no hacemos nada.
    if (detail === null) return
    try {
      await resolveInfoNote(note.id, detail)
      await reload()
    } catch (e) {
      setError((e as Error).message)
    }
  }

  return (
    <div className="mx-auto max-w-3xl p-6">
      <PageHeader
        title="Pase de información"
        subtitle="Bitácora entre turnos — objetos olvidados, avisos, pendientes. Buscable por palabra clave y fecha."
      />

      {error && (
        <p className="mb-4 rounded bg-red-50 p-2 text-sm text-red-700">{error}</p>
      )}

      {/* Registrar */}
      <div className="mb-6 rounded border border-slate-200 p-4">
        <h3 className="mb-2 font-semibold text-slate-700">Registrar información</h3>
        <textarea
          value={content}
          onChange={(e) => setContent(e.target.value)}
          rows={2}
          placeholder="Ej. Se dejó una chaqueta negra en la Hab. 12 del huésped Juan Pérez."
          className="w-full rounded border border-slate-300 p-2 text-sm"
        />
        <button
          type="button"
          disabled={busy}
          onClick={handleCreate}
          className="mt-2 rounded bg-brand-700 px-4 py-2 text-sm font-medium text-white hover:bg-brand-800 disabled:opacity-50"
        >
          Registrar
        </button>
      </div>

      {/* Búsqueda */}
      <div className="mb-4 flex flex-wrap items-end gap-3">
        <label className="flex-1 text-xs font-medium text-slate-500">
          Buscar
          <input
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="palabra clave (chaqueta, Hab. 12, apellido…)"
            className="mt-1 block w-full rounded border border-slate-300 p-2 text-sm"
          />
        </label>
        <label className="text-xs font-medium text-slate-500">
          Desde
          <input type="date" value={from} onChange={(e) => setFrom(e.target.value)}
            className="mt-1 block rounded border border-slate-300 p-2 text-sm text-slate-700" />
        </label>
        <label className="text-xs font-medium text-slate-500">
          Hasta
          <input type="date" value={to} onChange={(e) => setTo(e.target.value)}
            className="mt-1 block rounded border border-slate-300 p-2 text-sm text-slate-700" />
        </label>
        <label className="flex items-center gap-1 pb-2 text-xs text-slate-600">
          <input
            type="checkbox"
            checked={includeResolved}
            onChange={(e) => setIncludeResolved(e.target.checked)}
          />
          Incluir resueltas
        </label>
      </div>

      {/* Lista */}
      <div className="space-y-2">
        {notes.map((n) => (
          <div
            key={n.id}
            className={`rounded border p-3 ${
              n.resolved ? 'border-slate-200 bg-slate-50' : 'border-slate-200 bg-white'
            }`}
          >
            <div className="flex items-start justify-between gap-3">
              <p className={`text-sm ${n.resolved ? 'text-slate-500 line-through' : 'text-slate-800'}`}>
                {n.content}
              </p>
              {!n.resolved && (
                <button
                  type="button"
                  onClick={() => handleResolve(n)}
                  className="shrink-0 rounded border border-slate-300 px-2 py-1 text-xs font-medium text-slate-600 hover:bg-slate-50"
                >
                  Marcar resuelta
                </button>
              )}
            </div>
            <p className="mt-2 text-xs text-slate-400">
              Registró {n.createdByName ?? '—'} · {formatDateTime(n.createdAt)}
            </p>
            {n.resolved && (
              <p className="mt-1 text-xs text-green-700">
                Resuelta por {n.resolvedByName ?? '—'} ·{' '}
                {n.resolvedAt ? formatDateTime(n.resolvedAt) : ''}
                {n.resolvedNote ? ` · ${n.resolvedNote}` : ''}
              </p>
            )}
          </div>
        ))}
        {notes.length === 0 && (
          <p className="py-6 text-center text-sm text-slate-400">
            Sin información registrada para esta búsqueda.
          </p>
        )}
      </div>
    </div>
  )
}
