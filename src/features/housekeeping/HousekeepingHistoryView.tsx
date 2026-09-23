import { useCallback, useEffect, useMemo, useState } from 'react'
import type {
  HousekeepingAssignment,
  HousekeepingAssignmentEvent,
} from '../../domain/housekeeping/assignment'
import {
  ASSIGNMENT_STATUS_LABEL,
  ASSIGNMENT_KIND_LABEL,
  formatDuration,
  assignmentIdsWithNotes,
} from '../../domain/housekeeping/assignment'
import { fetchAssignmentHistory, fetchAssignmentEvents } from '../../services/housekeeping'
import { fetchRooms } from '../../services/rooms'
import type { Room } from '../../domain/rooms/room'
import { formatDate } from '../../lib/date'
import { AssignmentHistory } from './AssignmentHistory'

const STATUS_STYLE: Record<HousekeepingAssignment['status'], string> = {
  pending: 'bg-amber-100 text-amber-800',
  in_progress: 'bg-blue-100 text-blue-800',
  done: 'bg-green-100 text-green-800',
}

const KIND_STYLE: Record<HousekeepingAssignment['kind'], string> = {
  stayover: 'bg-slate-100 text-slate-700',
  turnover: 'bg-purple-100 text-purple-800',
  carryover: 'bg-red-100 text-red-800',
}

function today(): string {
  return new Date().toISOString().slice(0, 10)
}

function daysAgo(n: number): string {
  const d = new Date()
  d.setDate(d.getDate() - n)
  return d.toISOString().slice(0, 10)
}

// Historial de limpieza por habitación: "¿quién limpió la habitación X
// hace dos semanas y qué encontraron?". Solo lectura -- ni el tablero
// del día ni acá permiten editar desde esta vista.
export function HousekeepingHistoryView() {
  const [rooms, setRooms] = useState<Room[]>([])
  const [roomId, setRoomId] = useState('')
  const [from, setFrom] = useState(daysAgo(30))
  const [to, setTo] = useState(today())
  const [onlyWithNotes, setOnlyWithNotes] = useState(false)
  const [assignments, setAssignments] = useState<HousekeepingAssignment[]>([])
  const [events, setEvents] = useState<Record<string, HousekeepingAssignmentEvent[]>>({})
  const [expandedHistory, setExpandedHistory] = useState<Set<string>>(new Set())
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    fetchRooms()
      .then(setRooms)
      .catch((e: Error) => setError(e.message))
  }, [])

  const reload = useCallback(() => {
    if (from > to) {
      setError('La fecha "Desde" no puede ser posterior a "Hasta"')
      return Promise.resolve()
    }
    setError(null)
    return fetchAssignmentHistory({ roomId: roomId || undefined, from, to })
      .then(async (rows) => {
        setAssignments(rows)
        if (rows.length === 0) {
          setEvents({})
          return
        }
        const rows2 = await fetchAssignmentEvents(rows.map((r) => r.id))
        const byAssignment: Record<string, HousekeepingAssignmentEvent[]> = {}
        for (const e of rows2) {
          ;(byAssignment[e.assignmentId] ??= []).push(e)
        }
        setEvents(byAssignment)
      })
      .catch((e: Error) => setError(e.message))
  }, [roomId, from, to])

  useEffect(() => {
    void reload()
  }, [reload])

  function toggleHistory(id: string) {
    setExpandedHistory((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  const idsWithNotes = useMemo(
    () => assignmentIdsWithNotes(Object.values(events).flat()),
    [events],
  )

  const visibleAssignments = onlyWithNotes
    ? assignments.filter((a) => idsWithNotes.has(a.id))
    : assignments

  return (
    <div>
      {error && <p className="mb-4 rounded bg-red-50 p-2 text-sm text-red-700">{error}</p>}

      <div className="mb-6 flex flex-wrap items-end gap-3 rounded border border-slate-200 p-4">
        <label className="flex flex-col text-sm text-slate-600">
          Habitación
          <select
            value={roomId}
            onChange={(e) => setRoomId(e.target.value)}
            className="mt-1 rounded border border-slate-300 p-2"
          >
            <option value="">Todas</option>
            {rooms.map((r) => (
              <option key={r.id} value={r.id}>
                Hab. {r.roomNumber}
              </option>
            ))}
          </select>
        </label>
        <label className="flex flex-col text-sm text-slate-600">
          Desde
          <input
            type="date"
            value={from}
            onChange={(e) => setFrom(e.target.value)}
            className="mt-1 rounded border border-slate-300 p-2"
          />
        </label>
        <label className="flex flex-col text-sm text-slate-600">
          Hasta
          <input
            type="date"
            value={to}
            onChange={(e) => setTo(e.target.value)}
            className="mt-1 rounded border border-slate-300 p-2"
          />
        </label>
        <label className="flex items-center gap-2 text-sm text-slate-600">
          <input
            type="checkbox"
            checked={onlyWithNotes}
            onChange={(e) => setOnlyWithNotes(e.target.checked)}
          />
          Solo con notas/anomalías
        </label>
      </div>

      <div className="overflow-x-auto rounded border border-slate-200">
        <table className="w-full text-left text-sm">
          <thead className="bg-slate-100 text-slate-600">
            <tr>
              <th className="p-3">Fecha</th>
              <th className="p-3">Habitación</th>
              <th className="p-3">Tipo</th>
              <th className="p-3">Mucama</th>
              <th className="p-3">Estado</th>
              <th className="p-3">Duración</th>
              <th className="p-3">Notas</th>
            </tr>
          </thead>
          <tbody>
            {visibleAssignments.map((a) => {
              const duration = formatDuration(a.startedAt, a.completedAt)
              return (
                <tr key={a.id} className="border-t border-slate-100">
                  <td className="p-3">{formatDate(a.serviceDate)}</td>
                  <td className="p-3">
                    {a.roomNumber ? `Hab. ${a.roomNumber}` : 'Sin habitación'}
                  </td>
                  <td className="p-3">
                    <span className={`rounded px-2 py-1 text-xs font-medium ${KIND_STYLE[a.kind]}`}>
                      {ASSIGNMENT_KIND_LABEL[a.kind]}
                    </span>
                  </td>
                  <td className="p-3">{a.assignedToName ?? '—'}</td>
                  <td className="p-3">
                    <span className={`rounded px-2 py-1 text-xs font-medium ${STATUS_STYLE[a.status]}`}>
                      {ASSIGNMENT_STATUS_LABEL[a.status]}
                    </span>
                  </td>
                  <td className="p-3 text-slate-500">
                    {a.status === 'done'
                      ? (duration ?? '—')
                      : a.status === 'in_progress'
                        ? 'En curso…'
                        : '—'}
                  </td>
                  <td className="p-3 text-slate-500">
                    <AssignmentHistory
                      events={events[a.id] ?? []}
                      expanded={expandedHistory.has(a.id)}
                      onToggle={() => toggleHistory(a.id)}
                    />
                  </td>
                </tr>
              )
            })}
            {visibleAssignments.length === 0 && (
              <tr>
                <td colSpan={7} className="p-4 text-center text-slate-400">
                  Sin limpiezas registradas para este filtro.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  )
}
