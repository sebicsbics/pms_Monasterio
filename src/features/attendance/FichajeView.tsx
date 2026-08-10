import { useEffect, useMemo, useState } from 'react'
import {
  clockIn,
  clockOut,
  fetchMyEntriesSince,
  fetchMyOpenEntry,
  fetchTimeEntries,
  type TimeEntry,
} from '../../services/attendance'
import { ROLE_LABEL, canWrite, type UserRole } from '../../domain/auth/profile'
import { Card, PageHeader } from '../../components/ui'
import { formatDate } from '../../lib/date'
import { ForceClockOut } from './ForceClockOut'

const fmtTime = (iso: string) =>
  new Date(iso).toLocaleTimeString('es-BO', { hour: '2-digit', minute: '2-digit' })

// Duración de una sesión (usa 'now' si sigue abierta) en milisegundos.
function durationMs(e: TimeEntry, now: number): number {
  const end = e.clockOut ? new Date(e.clockOut).getTime() : now
  return Math.max(0, end - new Date(e.clockIn).getTime())
}
function fmtDur(ms: number): string {
  const min = Math.floor(ms / 60000)
  return `${Math.floor(min / 60)}h ${min % 60}m`
}

export function FichajeView({
  userId,
  role,
}: {
  userId: string
  role?: UserRole | null
}) {
  const [open, setOpen] = useState<TimeEntry | null>(null)
  const [today, setToday] = useState<TimeEntry[]>([])
  const [all, setAll] = useState<TimeEntry[]>([])
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [now, setNow] = useState(Date.now())

  // owner NO ficha: no es empleado, no cumple turno. La RPC también lo
  // rechaza (20260809030000); acá se le oculta la tarjeta de marcaje.
  const punches = canWrite(role)
  const isMgmt = role === 'root' || role === 'accountant' || role === 'owner'
  // Cerrar el fichaje de OTRA persona es dato de nómina: sólo root.
  const isRoot = role === 'root'

  function reload() {
    const start = new Date()
    start.setHours(0, 0, 0, 0)
    const jobs: [Promise<TimeEntry | null>, Promise<TimeEntry[]>, Promise<TimeEntry[]>] = [
      fetchMyOpenEntry(userId),
      fetchMyEntriesSince(userId, start.toISOString()),
      isMgmt ? fetchTimeEntries() : Promise.resolve([]),
    ]
    return Promise.all(jobs)
      .then(([o, t, a]) => {
        setOpen(o)
        setToday(t)
        setAll(a)
      })
      .catch((e: Error) => setError(e.message))
  }

  useEffect(() => {
    reload().finally(() => setLoading(false))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [userId])

  // Refresca el contador en vivo cada 30s (sin re-consultar la base).
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 30000)
    return () => clearInterval(id)
  }, [])

  async function punch(action: () => Promise<void>) {
    setBusy(true)
    setError(null)
    try {
      await action()
      await reload()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  const totalToday = useMemo(
    () => today.reduce((s, e) => s + durationMs(e, now), 0),
    [today, now],
  )

  if (loading) return <p className="p-8 text-slate-500">Cargando fichaje…</p>

  return (
    <div className="mx-auto max-w-5xl p-6">
      <PageHeader
        title="Fichaje"
        subtitle={
          punches
            ? 'Marcá tu entrada y salida del turno'
            : 'Asistencia del personal (tu usuario no ficha)'
        }
      />

      {error && <p className="mb-4 rounded bg-red-50 p-2 text-sm text-red-700">{error}</p>}

      {punches && (
        <>
      {/* Widget personal */}
      <Card className="mb-6 p-6">
        <div className="flex flex-wrap items-center justify-between gap-4">
          <div>
            {open ? (
              <>
                <p className="flex items-center gap-2 text-lg font-semibold text-green-700">
                  <span className="h-2.5 w-2.5 rounded-full bg-green-500" />
                  Dentro desde {fmtTime(open.clockIn)}
                </p>
                <p className="text-sm text-slate-500">
                  Sesión actual: {fmtDur(durationMs(open, now))}
                </p>
              </>
            ) : (
              <p className="flex items-center gap-2 text-lg font-semibold text-slate-600">
                <span className="h-2.5 w-2.5 rounded-full bg-slate-300" />
                Fuera de turno
              </p>
            )}
            <p className="mt-1 text-sm text-slate-500">
              Hoy trabajaste: <span className="font-semibold text-slate-700">{fmtDur(totalToday)}</span>
            </p>
          </div>

          {!punches ? null : open ? (
            <button
              type="button"
              disabled={busy}
              onClick={() => punch(clockOut)}
              className="rounded-lg bg-slate-700 px-6 py-3 font-medium text-white hover:bg-slate-800 disabled:opacity-50"
            >
              {busy ? '…' : 'Marcar salida'}
            </button>
          ) : (
            <button
              type="button"
              disabled={busy}
              onClick={() => punch(clockIn)}
              className="rounded-lg bg-green-600 px-6 py-3 font-medium text-white hover:bg-green-700 disabled:opacity-50"
            >
              {busy ? '…' : 'Marcar entrada'}
            </button>
          )}
        </div>

        {today.length > 0 && (
          <div className="mt-4 border-t border-slate-100 pt-3">
            <h4 className="mb-2 text-xs font-semibold uppercase tracking-wide text-slate-500">
              Sesiones de hoy
            </h4>
            <div className="space-y-1 text-sm text-slate-600">
              {today.map((e) => (
                <div key={e.id} className="flex justify-between">
                  <span>
                    {fmtTime(e.clockIn)} → {e.clockOut ? fmtTime(e.clockOut) : 'en curso'}
                  </span>
                  <span className="font-medium">{fmtDur(durationMs(e, now))}</span>
                </div>
              ))}
            </div>
          </div>
        )}
      </Card>

      {/* Vista de gestión: root / contaduría */}
        </>
      )}

      {isMgmt && (
        <div>
          <h2 className="mb-3 font-semibold text-slate-700">
            Registro de todos los empleados
          </h2>
          {all.length === 0 ? (
            <p className="text-sm text-slate-400">Sin fichajes todavía.</p>
          ) : (
            <Card className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
                  <tr>
                    <th className="p-3">Empleado</th>
                    <th className="p-3">Rol</th>
                    <th className="p-3">Fecha</th>
                    <th className="p-3">Entrada</th>
                    <th className="p-3">Salida</th>
                    <th className="p-3">Horas</th>
                  </tr>
                </thead>
                <tbody>
                  {all.map((e) => (
                    <tr key={e.id} className="border-t border-slate-100">
                      <td className="p-3 font-medium text-slate-800">{e.userName}</td>
                      <td className="p-3 text-slate-600">{e.role ? ROLE_LABEL[e.role] : '—'}</td>
                      <td className="p-3 text-slate-600">{formatDate(e.clockIn)}</td>
                      <td className="p-3 font-mono text-slate-700">{fmtTime(e.clockIn)}</td>
                      <td className="p-3 font-mono text-slate-700">
                        {e.clockOut ? (
                          fmtTime(e.clockOut)
                        ) : (
                          <span className="rounded bg-green-100 px-1.5 py-0.5 text-xs font-medium text-green-700">
                            dentro
                          </span>
                        )}
                      </td>
                      <td className="p-3 font-medium text-slate-700">
                        {fmtDur(durationMs(e, now))}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </Card>
          )}
        </div>
      )}
      {isRoot && <ForceClockOut entries={all} onDone={() => void reload()} />}
    </div>
  )
}
