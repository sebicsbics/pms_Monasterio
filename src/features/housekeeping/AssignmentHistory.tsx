import type { HousekeepingAssignmentEvent } from '../../domain/housekeeping/assignment'
import { ASSIGNMENT_STATUS_LABEL } from '../../domain/housekeeping/assignment'
import { formatDateTime } from '../../lib/date'

// Historial de una asignación, más reciente primero: muestra los últimos
// 2 eventos y deja expandir el resto (evita que una limpieza con muchas
// notas rompa el ancho de la columna). Compartido por el tablero del día
// y el historial por habitación -- misma lectura en los dos lugares.
const HISTORY_COLLAPSED_COUNT = 2

export function AssignmentHistory({
  events,
  expanded,
  onToggle,
}: {
  events: HousekeepingAssignmentEvent[]
  expanded: boolean
  onToggle: () => void
}) {
  if (events.length === 0) return <span>—</span>

  const visible = expanded ? events : events.slice(0, HISTORY_COLLAPSED_COUNT)
  const hiddenCount = events.length - visible.length

  return (
    <div className="space-y-1">
      {visible.map((e) => (
        <div key={e.id} className="text-xs">
          <span className="text-slate-400">{formatDateTime(e.createdAt)}</span>{' '}
          <span className="font-medium text-slate-600">{e.createdByName}</span>
          {e.fromStatus !== e.toStatus && (
            <span className="text-slate-500">
              {' '}
              ({ASSIGNMENT_STATUS_LABEL[e.fromStatus]} → {ASSIGNMENT_STATUS_LABEL[e.toStatus]})
            </span>
          )}
          {e.note && <p className="text-slate-700">{e.note}</p>}
        </div>
      ))}
      {events.length > HISTORY_COLLAPSED_COUNT && (
        <button
          type="button"
          onClick={onToggle}
          className="text-xs font-medium text-brand-700 hover:underline"
        >
          {expanded ? 'Ver menos' : `Ver ${hiddenCount} más`}
        </button>
      )}
    </div>
  )
}
