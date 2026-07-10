import { useEffect, useMemo, useState } from 'react'
import { fetchLoginEvents, type LoginEvent } from '../../services/attendance'
import { ROLE_LABEL } from '../../domain/auth/profile'
import { Badge, Card, PageHeader } from '../../components/ui'

const fmtDate = (iso: string) =>
  new Date(iso).toLocaleDateString('es-BO', { day: '2-digit', month: '2-digit', year: 'numeric' })
const fmtTime = (iso: string) =>
  new Date(iso).toLocaleTimeString('es-BO', { hour: '2-digit', minute: '2-digit' })

type Filter = 'all' | 'login' | 'logout'

export function AccessLogView() {
  const [events, setEvents] = useState<LoginEvent[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [filter, setFilter] = useState<Filter>('all')

  useEffect(() => {
    fetchLoginEvents()
      .then(setEvents)
      .catch((e: Error) => setError(e.message))
      .finally(() => setLoading(false))
  }, [])

  const visible = useMemo(
    () => (filter === 'all' ? events : events.filter((e) => e.eventType === filter)),
    [events, filter],
  )

  if (loading) return <p className="p-8 text-slate-500">Cargando accesos…</p>
  if (error) {
    return (
      <div className="mx-auto max-w-5xl p-6">
        <p className="rounded bg-red-50 p-3 text-sm text-red-700">Error: {error}</p>
      </div>
    )
  }

  return (
    <div className="mx-auto max-w-5xl p-6">
      <PageHeader
        title="Accesos al sistema"
        subtitle="Ingresos y salidas del personal · marcador aproximado de asistencia"
      />

      <div className="mb-4 flex flex-wrap gap-2">
        {([['all', 'Todos'], ['login', 'Ingresos'], ['logout', 'Salidas']] as const).map(
          ([id, label]) => (
            <button
              key={id}
              type="button"
              onClick={() => setFilter(id)}
              className={`rounded-full px-3 py-1 text-sm ${
                filter === id ? 'bg-slate-800 text-white' : 'bg-slate-100 text-slate-600 hover:bg-slate-200'
              }`}
            >
              {label}
            </button>
          ),
        )}
      </div>

      {visible.length === 0 ? (
        <p className="text-sm text-slate-400">Sin registros todavía.</p>
      ) : (
        <Card className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
              <tr>
                <th className="p-3">Usuario</th>
                <th className="p-3">Rol</th>
                <th className="p-3">Evento</th>
                <th className="p-3">Fecha</th>
                <th className="p-3">Hora</th>
              </tr>
            </thead>
            <tbody>
              {visible.map((e) => (
                <tr key={e.id} className="border-t border-slate-100">
                  <td className="p-3 font-medium text-slate-800">
                    {e.userName}
                    {e.username && <span className="ml-1 text-xs text-slate-400">@{e.username}</span>}
                  </td>
                  <td className="p-3 text-slate-600">{e.role ? ROLE_LABEL[e.role] : '—'}</td>
                  <td className="p-3">
                    <Badge tone={e.eventType === 'login' ? 'success' : 'neutral'}>
                      {e.eventType === 'login' ? 'Ingreso' : 'Salida'}
                    </Badge>
                  </td>
                  <td className="p-3 text-slate-600">{fmtDate(e.occurredAt)}</td>
                  <td className="p-3 font-mono text-slate-700">{fmtTime(e.occurredAt)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </Card>
      )}
    </div>
  )
}
