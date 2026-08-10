import { useCallback, useEffect, useState } from 'react'
import { AlertTriangle } from 'lucide-react'
import {
  fetchOpenTimeEntries,
  forceClockOut,
  type OpenTimeEntry,
  type TimeEntry,
} from '../../services/attendance'
import {
  formatShiftHours,
  isImplausibleShift,
  suggestedClockOut,
  toLocalInputValue,
} from '../../domain/attendance/shift'
import { Button, Card } from '../../components/ui'
import { ROLE_LABEL } from '../../domain/auth/profile'
import { formatDateTime } from '../../lib/date'

// Cierre de fichaje ajeno — sólo root.
//
// `clock_out()` sólo cierra el turno de quien lo llama, así que si un
// recepcionista se va sin fichar salida no había forma de intervenir: el
// turno seguía acumulando horas. En producción llegó a 104.
//
// La hora de salida se elige a mano y NO se propone "ahora": si el turno
// terminó ayer a las 19:00 y se detecta hoy, cerrar con la hora actual
// registraría igual horas que nadie trabajó. Se sugiere entrada + 8 h.
export function ForceClockOut({
  entries,
  onDone,
}: {
  entries: TimeEntry[] // fichajes ya cerrados, para detectar los implausibles
  onDone: () => void
}) {
  const [open, setOpen] = useState<OpenTimeEntry[]>([])
  const [editing, setEditing] = useState<string | null>(null)
  const [clockOutAt, setClockOutAt] = useState('')
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)

  const load = useCallback(
    () => fetchOpenTimeEntries().then(setOpen).catch((e: Error) => setError(e.message)),
    [],
  )

  useEffect(() => {
    void load()
  }, [load])

  // Turnos ya cerrados con una duración imposible: son los que quedaron
  // abiertos hasta que alguien los cerró tarde, y siguen inflando la nómina.
  const implausible = entries.filter(
    (e) => e.clockOut !== null && isImplausibleShift(e.clockIn, e.clockOut),
  )

  function startEditing(id: string, clockIn: string) {
    setEditing(id)
    setClockOutAt(toLocalInputValue(suggestedClockOut(clockIn)))
    setReason('')
    setError(null)
    setMessage(null)
  }

  async function submit(id: string) {
    if (!clockOutAt) {
      setError('Indicá la hora de salida')
      return
    }
    if (!reason.trim()) {
      setError('La justificación es obligatoria')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await forceClockOut(id, new Date(clockOutAt), reason)
      setMessage('Fichaje corregido.')
      setEditing(null)
      await load()
      onDone()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  function EditForm({ id }: { id: string }) {
    return (
      <div className="mt-3 space-y-2 border-t border-slate-200 pt-3">
        <label className="block text-sm">
          <span className="mb-1 block text-xs font-medium text-slate-500">
            Hora real de salida
          </span>
          <input
            type="datetime-local"
            value={clockOutAt}
            onChange={(e) => setClockOutAt(e.target.value)}
            className="w-full rounded border border-slate-300 p-2 text-sm"
          />
        </label>
        <input
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          placeholder="Justificación (obligatoria)"
          className="w-full rounded border border-slate-300 p-2 text-sm"
        />
        <div className="flex gap-2">
          <Button size="sm" loading={busy} onClick={() => submit(id)}>
            Cerrar turno
          </Button>
          <Button size="sm" variant="secondary" onClick={() => setEditing(null)}>
            Cancelar
          </Button>
        </div>
      </div>
    )
  }

  if (open.length === 0 && implausible.length === 0) return null

  return (
    <div className="mt-8">
      <h3 className="mb-2 font-semibold text-slate-700">Corregir fichajes</h3>
      {error && <p className="mb-3 rounded bg-red-50 p-2 text-sm text-red-700">{error}</p>}
      {message && (
        <p className="mb-3 rounded bg-green-50 p-2 text-sm text-green-700">{message}</p>
      )}

      {open.length > 0 && (
        <div className="mb-4 space-y-2">
          <p className="text-xs font-medium uppercase tracking-wide text-slate-500">
            Turnos abiertos ahora
          </p>
          {open.map((e) => {
            const tooLong = isImplausibleShift(e.clockIn, null)
            return (
              <Card key={e.id} className={`p-3 ${tooLong ? 'border-amber-300 bg-amber-50' : ''}`}>
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <div>
                    <p className="text-sm font-medium text-slate-800">
                      {e.userName}
                      <span className="ml-2 text-xs font-normal text-slate-500">
                        {e.role ? ROLE_LABEL[e.role] : '—'}
                      </span>
                    </p>
                    <p className="text-xs text-slate-500">
                      Entró {formatDateTime(e.clockIn)} · lleva{' '}
                      <span className={tooLong ? 'font-semibold text-amber-700' : ''}>
                        {formatShiftHours(e.clockIn, null)}
                      </span>
                      {tooLong && (
                        <AlertTriangle
                          size={13}
                          className="ml-1 inline align-text-top text-amber-600"
                        />
                      )}
                    </p>
                  </div>
                  {editing !== e.id && (
                    <Button size="sm" variant="secondary" onClick={() => startEditing(e.id, e.clockIn)}>
                      Cerrar turno
                    </Button>
                  )}
                </div>
                {editing === e.id && <EditForm id={e.id} />}
              </Card>
            )
          })}
        </div>
      )}

      {implausible.length > 0 && (
        <div className="space-y-2">
          <p className="text-xs font-medium uppercase tracking-wide text-slate-500">
            Turnos cerrados con duración implausible
          </p>
          <p className="text-xs text-slate-500">
            Quedaron abiertos hasta que alguien los cerró tarde. Siguen contando esas
            horas en la nómina.
          </p>
          {implausible.map((e) => (
            <Card key={e.id} className="border-amber-300 bg-amber-50 p-3">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <div>
                  <p className="text-sm font-medium text-slate-800">
                    {e.userName}
                    <span className="ml-2 text-xs font-normal text-slate-500">
                      {e.role ? ROLE_LABEL[e.role] : '—'}
                    </span>
                  </p>
                  <p className="text-xs text-slate-500">
                    {formatDateTime(e.clockIn)} → {formatDateTime(e.clockOut!)} ·{' '}
                    <span className="font-semibold text-amber-700">
                      {formatShiftHours(e.clockIn, e.clockOut)}
                    </span>
                  </p>
                </div>
                {editing !== e.id && (
                  <Button size="sm" variant="secondary" onClick={() => startEditing(e.id, e.clockIn)}>
                    Corregir
                  </Button>
                )}
              </div>
              {editing === e.id && <EditForm id={e.id} />}
            </Card>
          ))}
        </div>
      )}
    </div>
  )
}
