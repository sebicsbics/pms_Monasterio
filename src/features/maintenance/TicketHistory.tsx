import { useEffect, useState } from 'react'
import { fetchTicketEvents } from '../../services/maintenance'
import { STATUS_LABEL, type TicketEvent } from '../../domain/maintenance/ticket'

const fmt = (iso: string) =>
  new Date(iso).toLocaleString('es-BO', {
    day: '2-digit', month: '2-digit', year: '2-digit',
    hour: '2-digit', minute: '2-digit',
  })

// Línea de tiempo de los estados por los que pasó el ticket.
export function TicketHistory({ ticketId }: { ticketId: string }) {
  const [events, setEvents] = useState<TicketEvent[]>([])
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    fetchTicketEvents(ticketId)
      .then(setEvents)
      .catch((e: Error) => setError(e.message))
  }, [ticketId])

  if (error) return <p className="text-xs text-red-600">{error}</p>
  if (events.length === 0) return null

  return (
    <div className="mt-3 rounded border border-slate-200 bg-slate-50 p-3">
      <h4 className="mb-2 text-xs font-semibold uppercase tracking-wide text-slate-500">
        Historial
      </h4>
      <ol className="flex flex-wrap items-center gap-x-1 gap-y-1 text-xs text-slate-600">
        {events.map((e, i) => (
          <li key={i} className="flex items-center gap-1">
            {i > 0 && <span className="text-slate-300">→</span>}
            <span className="font-medium text-slate-700">{STATUS_LABEL[e.status]}</span>
            <span className="text-slate-400">({fmt(e.changedAt)})</span>
          </li>
        ))}
      </ol>
    </div>
  )
}
