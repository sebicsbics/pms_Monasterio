import { useCallback, useEffect, useState } from 'react'
import type {
  HousekeepingAssignment,
  HousekeepingAssignmentEvent,
  AssignmentStatus,
} from '../../domain/housekeeping/assignment'
import {
  ASSIGNMENT_STATUS_LABEL,
  ASSIGNMENT_KIND_LABEL,
  formatDuration,
} from '../../domain/housekeeping/assignment'
import {
  fetchAssignments,
  generateAssignments,
  updateAssignmentStatus,
  assignStaffName,
  addAssignmentNote,
  fetchAssignmentEvents,
} from '../../services/housekeeping'
import { PageHeader } from '../../components/ui'
import { formatDate, formatDateTime } from '../../lib/date'
import { useCanWrite } from '../../shared/lib/canWriteContext'

const STATUSES: AssignmentStatus[] = ['pending', 'in_progress', 'done']

const STATUS_STYLE: Record<AssignmentStatus, string> = {
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

// Cambio de estado pendiente de confirmar (con nota opcional) para una
// asignación puntual -- se pisa uno por otro, no hay más de uno abierto.
interface PendingStatusChange {
  assignmentId: string
  status: AssignmentStatus
  note: string
}

export function HousekeepingBoardView() {
  // owner: solo lectura, sin acciones.
  const canEdit = useCanWrite()
  const [serviceDate, setServiceDate] = useState(today())
  const [assignments, setAssignments] = useState<HousekeepingAssignment[]>([])
  const [events, setEvents] = useState<Record<string, HousekeepingAssignmentEvent[]>>({})
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [pendingChange, setPendingChange] = useState<PendingStatusChange | null>(null)
  const [noteDraftId, setNoteDraftId] = useState<string | null>(null)
  const [noteDraft, setNoteDraft] = useState('')
  const [expandedHistory, setExpandedHistory] = useState<Set<string>>(new Set())

  const reloadEvents = useCallback((rows: HousekeepingAssignment[]) => {
    if (rows.length === 0) {
      setEvents({})
      return Promise.resolve()
    }
    return fetchAssignmentEvents(rows.map((r) => r.id))
      .then((rows2) => {
        const byAssignment: Record<string, HousekeepingAssignmentEvent[]> = {}
        for (const e of rows2) {
          ;(byAssignment[e.assignmentId] ??= []).push(e)
        }
        setEvents(byAssignment)
      })
      .catch((e: Error) => setError(e.message))
  }, [])

  const reload = useCallback(
    (date: string) => {
      return fetchAssignments(date)
        .then(async (rows) => {
          setAssignments(rows)
          await reloadEvents(rows)
        })
        .catch((e: Error) => setError(e.message))
    },
    [reloadEvents],
  )

  useEffect(() => {
    void reload(serviceDate)
  }, [reload, serviceDate])

  async function handleGenerate() {
    setBusy(true)
    setError(null)
    try {
      await generateAssignments(serviceDate)
      await reload(serviceDate)
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  function requestStatusChange(id: string, status: AssignmentStatus) {
    setPendingChange({ assignmentId: id, status, note: '' })
  }

  function cancelStatusChange() {
    setPendingChange(null)
  }

  async function confirmStatusChange() {
    if (!pendingChange) return
    try {
      await updateAssignmentStatus(pendingChange.assignmentId, pendingChange.status, pendingChange.note)
      setPendingChange(null)
      await reload(serviceDate)
    } catch (e) {
      setError((e as Error).message)
    }
  }

  function startNoteDraft(id: string) {
    setNoteDraftId(id)
    setNoteDraft('')
  }

  function cancelNoteDraft() {
    setNoteDraftId(null)
    setNoteDraft('')
  }

  async function confirmNoteDraft(id: string, currentStatus: AssignmentStatus) {
    if (!noteDraft.trim()) return
    try {
      await addAssignmentNote(id, currentStatus, noteDraft)
      setNoteDraftId(null)
      setNoteDraft('')
      await reload(serviceDate)
    } catch (e) {
      setError((e as Error).message)
    }
  }

  function toggleHistory(id: string) {
    setExpandedHistory((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  async function saveAssignee(id: string, name: string, prev: string | null) {
    if (name.trim() === (prev ?? '')) return
    try {
      await assignStaffName(id, name)
      await reload(serviceDate)
    } catch (e) {
      setError((e as Error).message)
    }
  }

  return (
    <div className="mx-auto max-w-5xl p-6">
      <PageHeader title="Housekeeping" />

      {error && (
        <p className="mb-4 rounded bg-red-50 p-2 text-sm text-red-700">{error}</p>
      )}

      <div className="mb-6 flex flex-wrap items-end gap-3 rounded border border-slate-200 p-4">
        <label className="flex flex-col text-sm text-slate-600">
          Fecha de servicio
          <input
            type="date"
            value={serviceDate}
            onChange={(e) => setServiceDate(e.target.value)}
            className="mt-1 rounded border border-slate-300 p-2"
          />
        </label>
        {canEdit && (
          <button
          type="button"
          disabled={busy}
          onClick={handleGenerate}
          className="rounded bg-brand-700 px-4 py-2 text-sm font-medium text-white hover:bg-brand-800 disabled:opacity-50"
        >
          Generar tablero del día
        </button>
        )}
        <span className="text-sm text-slate-500">{formatDate(serviceDate)}</span>
      </div>

      <div className="overflow-x-auto rounded border border-slate-200">
        <table className="w-full text-left text-sm">
          <thead className="bg-slate-100 text-slate-600">
            <tr>
              <th className="p-3">Tipo</th>
              <th className="p-3">Habitación</th>
              <th className="p-3">Mucama</th>
              <th className="p-3">Estado</th>
              <th className="p-3">Duración</th>
              <th className="p-3">Notas</th>
            </tr>
          </thead>
          <tbody>
            {assignments.map((a) => {
              const duration = formatDuration(a.startedAt, a.completedAt)
              return (
                <tr key={a.id} className="border-t border-slate-100">
                  <td className="p-3">
                    <span className={`rounded px-2 py-1 text-xs font-medium ${KIND_STYLE[a.kind]}`}>
                      {ASSIGNMENT_KIND_LABEL[a.kind]}
                    </span>
                  </td>
                  <td className="p-3">
                    {a.roomNumber ? `Hab. ${a.roomNumber}` : 'Sin habitación'}
                  </td>
                  <td className="p-3">
                    <input
                      defaultValue={a.assignedToName ?? ''}
                      placeholder="Nombre de la mucama"
                      onBlur={(e) => saveAssignee(a.id, e.target.value, a.assignedToName)}
                      className="w-40 rounded border border-slate-300 p-2 text-sm"
                    />
                  </td>
                  <td className="p-3">
                    {canEdit ? (
                      <select
                        value={a.status}
                        onChange={(e) => requestStatusChange(a.id, e.target.value as AssignmentStatus)}
                        className={`rounded px-2 py-1 text-xs font-medium ${STATUS_STYLE[a.status]}`}
                      >
                        {STATUSES.map((s) => (
                          <option key={s} value={s}>
                            {ASSIGNMENT_STATUS_LABEL[s]}
                          </option>
                        ))}
                      </select>
                    ) : (
                      <span className={`rounded px-2 py-1 text-xs font-medium ${STATUS_STYLE[a.status]}`}>
                        {ASSIGNMENT_STATUS_LABEL[a.status]}
                      </span>
                    )}
                    {pendingChange?.assignmentId === a.id && (
                      <div className="mt-2 w-56 rounded border border-slate-300 bg-white p-2 shadow">
                        <label className="block text-xs text-slate-600">
                          Nota / anomalías (opcional)
                          <textarea
                            value={pendingChange.note}
                            onChange={(e) =>
                              setPendingChange({ ...pendingChange, note: e.target.value })
                            }
                            rows={2}
                            className="mt-1 w-full rounded border border-slate-300 p-1 text-xs"
                            placeholder="Ej: encontramos la ventana rota"
                          />
                        </label>
                        <div className="mt-2 flex justify-end gap-2">
                          <button
                            type="button"
                            onClick={cancelStatusChange}
                            className="rounded px-2 py-1 text-xs text-slate-600 hover:bg-slate-100"
                          >
                            Cancelar
                          </button>
                          <button
                            type="button"
                            onClick={confirmStatusChange}
                            className="rounded bg-brand-700 px-2 py-1 text-xs font-medium text-white hover:bg-brand-800"
                          >
                            Confirmar
                          </button>
                        </div>
                      </div>
                    )}
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
                    {canEdit && noteDraftId === a.id ? (
                      <div className="mt-2 w-56 rounded border border-slate-300 bg-white p-2 shadow">
                        <textarea
                          value={noteDraft}
                          onChange={(e) => setNoteDraft(e.target.value)}
                          rows={2}
                          className="w-full rounded border border-slate-300 p-1 text-xs"
                          placeholder="Nota / anomalías"
                          autoFocus
                        />
                        <div className="mt-2 flex justify-end gap-2">
                          <button
                            type="button"
                            onClick={cancelNoteDraft}
                            className="rounded px-2 py-1 text-xs text-slate-600 hover:bg-slate-100"
                          >
                            Cancelar
                          </button>
                          <button
                            type="button"
                            disabled={!noteDraft.trim()}
                            onClick={() => confirmNoteDraft(a.id, a.status)}
                            className="rounded bg-brand-700 px-2 py-1 text-xs font-medium text-white hover:bg-brand-800 disabled:opacity-50"
                          >
                            Guardar
                          </button>
                        </div>
                      </div>
                    ) : (
                      canEdit && (
                        <button
                          type="button"
                          onClick={() => startNoteDraft(a.id)}
                          className="mt-1 text-xs font-medium text-brand-700 hover:underline"
                        >
                          Agregar nota
                        </button>
                      )
                    )}
                  </td>
                </tr>
              )
            })}
            {assignments.length === 0 && (
              <tr>
                <td colSpan={6} className="p-4 text-center text-slate-400">
                  Sin asignaciones para esta fecha. Generá el tablero del día.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  )
}

// Historial de la asignación, más reciente primero: muestra los últimos
// 2 eventos y deja expandir el resto (evita que una limpieza con muchas
// notas rompa el ancho de la columna).
const HISTORY_COLLAPSED_COUNT = 2

function AssignmentHistory({
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
