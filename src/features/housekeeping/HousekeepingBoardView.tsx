import { useCallback, useEffect, useState } from 'react'
import type {
  HousekeepingAssignment,
  AssignmentStatus,
} from '../../domain/housekeeping/assignment'
import {
  ASSIGNMENT_STATUS_LABEL,
  ASSIGNMENT_KIND_LABEL,
} from '../../domain/housekeeping/assignment'
import type { AssignableStaff } from '../../domain/tasks/task'
import {
  fetchAssignments,
  generateAssignments,
  updateAssignmentStatus,
  assignStaff,
  fetchAssignableStaff,
} from '../../services/housekeeping'
import { PageHeader } from '../../components/ui'
import { formatDate } from '../../lib/date'

const STATUSES: AssignmentStatus[] = ['pending', 'in_progress', 'done']

const STATUS_STYLE: Record<AssignmentStatus, string> = {
  pending: 'bg-amber-100 text-amber-800',
  in_progress: 'bg-blue-100 text-blue-800',
  done: 'bg-green-100 text-green-800',
}

const KIND_STYLE: Record<HousekeepingAssignment['kind'], string> = {
  stayover: 'bg-slate-100 text-slate-700',
  turnover: 'bg-purple-100 text-purple-800',
}

function today(): string {
  return new Date().toISOString().slice(0, 10)
}

export function HousekeepingBoardView() {
  const [serviceDate, setServiceDate] = useState(today())
  const [assignments, setAssignments] = useState<HousekeepingAssignment[]>([])
  const [staff, setStaff] = useState<AssignableStaff[]>([])
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const reload = useCallback((date: string) => {
    return fetchAssignments(date)
      .then(setAssignments)
      .catch((e: Error) => setError(e.message))
  }, [])

  useEffect(() => {
    void reload(serviceDate)
  }, [reload, serviceDate])

  useEffect(() => {
    fetchAssignableStaff().then(setStaff).catch((e: Error) => setError(e.message))
  }, [])

  const staffName = (id: string | null) =>
    id ? (staff.find((s) => s.personId === id)?.fullName ?? '—') : 'Sin asignar'

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

  async function changeStatus(id: string, status: AssignmentStatus) {
    try {
      await updateAssignmentStatus(id, status)
      await reload(serviceDate)
    } catch (e) {
      setError((e as Error).message)
    }
  }

  async function changeAssignee(id: string, personId: string) {
    try {
      await assignStaff(id, personId || null)
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
        <button
          type="button"
          disabled={busy}
          onClick={handleGenerate}
          className="rounded bg-brand-700 px-4 py-2 text-sm font-medium text-white hover:bg-brand-800 disabled:opacity-50"
        >
          Generar tablero del día
        </button>
        <span className="text-sm text-slate-500">{formatDate(serviceDate)}</span>
      </div>

      <div className="overflow-x-auto rounded border border-slate-200">
        <table className="w-full text-left text-sm">
          <thead className="bg-slate-100 text-slate-600">
            <tr>
              <th className="p-3">Tipo</th>
              <th className="p-3">Habitación</th>
              <th className="p-3">Asignada a</th>
              <th className="p-3">Estado</th>
              <th className="p-3">Notas</th>
            </tr>
          </thead>
          <tbody>
            {assignments.map((a) => (
              <tr key={a.id} className="border-t border-slate-100">
                <td className="p-3">
                  <span
                    className={`rounded px-2 py-1 text-xs font-medium ${KIND_STYLE[a.kind]}`}
                  >
                    {ASSIGNMENT_KIND_LABEL[a.kind]}
                  </span>
                </td>
                <td className="p-3">
                  {a.roomNumber ? `Hab. ${a.roomNumber}` : 'Sin habitación'}
                </td>
                <td className="p-3">
                  <select
                    value={a.assignedTo ?? ''}
                    onChange={(e) => changeAssignee(a.id, e.target.value)}
                    className="rounded border border-slate-300 p-2"
                  >
                    <option value="">Sin asignar</option>
                    {staff.map((s) => (
                      <option key={s.personId} value={s.personId}>
                        {s.fullName} ({s.jobTitle})
                      </option>
                    ))}
                  </select>
                  <span className="sr-only">{staffName(a.assignedTo)}</span>
                </td>
                <td className="p-3">
                  <select
                    value={a.status}
                    onChange={(e) => changeStatus(a.id, e.target.value as AssignmentStatus)}
                    className={`rounded px-2 py-1 text-xs font-medium ${STATUS_STYLE[a.status]}`}
                  >
                    {STATUSES.map((s) => (
                      <option key={s} value={s}>
                        {ASSIGNMENT_STATUS_LABEL[s]}
                      </option>
                    ))}
                  </select>
                </td>
                <td className="p-3 text-slate-500">{a.notes ?? '—'}</td>
              </tr>
            ))}
            {assignments.length === 0 && (
              <tr>
                <td colSpan={5} className="p-4 text-center text-slate-400">
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
