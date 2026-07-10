import { useCallback, useEffect, useState } from 'react'
import type { Task, TaskType, TaskStatus, AssignableStaff } from '../../domain/tasks/task'
import { TASK_TYPE_LABEL, TASK_STATUS_LABEL } from '../../domain/tasks/task'
import type { Room } from '../../domain/rooms/room'
import {
  fetchTasks,
  fetchAssignableStaff,
  createTask,
  updateTaskStatus,
} from '../../services/tasks'
import { fetchRooms } from '../../services/rooms'
import { PageHeader } from '../../components/ui'

const TASK_TYPES: TaskType[] = ['cleaning', 'minibar', 'maintenance', 'other']
const STATUSES: TaskStatus[] = ['pending', 'in_progress', 'done']

const STATUS_STYLE: Record<TaskStatus, string> = {
  pending: 'bg-amber-100 text-amber-800',
  in_progress: 'bg-blue-100 text-blue-800',
  done: 'bg-green-100 text-green-800',
}

export function TasksView() {
  const [tasks, setTasks] = useState<Task[]>([])
  const [staff, setStaff] = useState<AssignableStaff[]>([])
  const [rooms, setRooms] = useState<Room[]>([])
  const [error, setError] = useState<string | null>(null)

  const [taskType, setTaskType] = useState<TaskType>('cleaning')
  const [roomId, setRoomId] = useState('')
  const [assignedTo, setAssignedTo] = useState('')
  const [notes, setNotes] = useState('')
  const [busy, setBusy] = useState(false)

  const reload = useCallback(() => {
    return fetchTasks()
      .then(setTasks)
      .catch((e: Error) => setError(e.message))
  }, [])

  useEffect(() => {
    void reload()
    fetchAssignableStaff().then(setStaff).catch((e: Error) => setError(e.message))
    fetchRooms().then(setRooms).catch((e: Error) => setError(e.message))
  }, [reload])

  const staffName = (id: string | null) =>
    id ? (staff.find((s) => s.personId === id)?.fullName ?? '—') : 'Sin asignar'

  async function handleCreate() {
    setBusy(true)
    setError(null)
    try {
      await createTask({
        taskType,
        roomId: roomId || null,
        assignedTo: assignedTo || null,
        notes,
      })
      setNotes('')
      setRoomId('')
      setAssignedTo('')
      await reload()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  async function changeStatus(id: string, status: TaskStatus) {
    try {
      await updateTaskStatus(id, status)
      await reload()
    } catch (e) {
      setError((e as Error).message)
    }
  }

  return (
    <div className="mx-auto max-w-5xl p-6">
      <PageHeader title="Tareas" />

      {error && (
        <p className="mb-4 rounded bg-red-50 p-2 text-sm text-red-700">{error}</p>
      )}

      {/* Asignar tarea */}
      <div className="mb-6 rounded border border-slate-200 p-4">
        <h3 className="mb-3 font-semibold text-slate-700">Asignar tarea</h3>
        <div className="grid grid-cols-1 gap-2 sm:grid-cols-4">
          <select
            value={taskType}
            onChange={(e) => setTaskType(e.target.value as TaskType)}
            className="rounded border border-slate-300 p-2"
          >
            {TASK_TYPES.map((t) => (
              <option key={t} value={t}>
                {TASK_TYPE_LABEL[t]}
              </option>
            ))}
          </select>
          <select
            value={roomId}
            onChange={(e) => setRoomId(e.target.value)}
            className="rounded border border-slate-300 p-2"
          >
            <option value="">Habitación (opcional)…</option>
            {rooms.map((r) => (
              <option key={r.id} value={r.id}>
                Hab. {r.roomNumber}
              </option>
            ))}
          </select>
          <select
            value={assignedTo}
            onChange={(e) => setAssignedTo(e.target.value)}
            className="rounded border border-slate-300 p-2"
          >
            <option value="">Asignar a…</option>
            {staff.map((s) => (
              <option key={s.personId} value={s.personId}>
                {s.fullName} ({s.jobTitle})
              </option>
            ))}
          </select>
          <input
            placeholder="Notas"
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
            className="rounded border border-slate-300 p-2"
          />
        </div>
        <button
          type="button"
          disabled={busy}
          onClick={handleCreate}
          className="mt-3 rounded bg-brand-700 px-4 py-2 text-sm font-medium text-white hover:bg-brand-800 disabled:opacity-50"
        >
          Asignar
        </button>
      </div>

      {/* Lista */}
      <div className="overflow-x-auto rounded border border-slate-200">
        <table className="w-full text-left text-sm">
          <thead className="bg-slate-100 text-slate-600">
            <tr>
              <th className="p-3">Tipo</th>
              <th className="p-3">Habitación</th>
              <th className="p-3">Asignada a</th>
              <th className="p-3">Notas</th>
              <th className="p-3">Estado</th>
            </tr>
          </thead>
          <tbody>
            {tasks.map((t) => (
              <tr key={t.id} className="border-t border-slate-100">
                <td className="p-3 font-medium">{TASK_TYPE_LABEL[t.taskType]}</td>
                <td className="p-3">{t.roomNumber ? `Hab. ${t.roomNumber}` : '—'}</td>
                <td className="p-3">{staffName(t.assignedTo)}</td>
                <td className="p-3 text-slate-500">{t.notes ?? '—'}</td>
                <td className="p-3">
                  <select
                    value={t.status}
                    onChange={(e) => changeStatus(t.id, e.target.value as TaskStatus)}
                    className={`rounded px-2 py-1 text-xs font-medium ${STATUS_STYLE[t.status]}`}
                  >
                    {STATUSES.map((s) => (
                      <option key={s} value={s}>
                        {TASK_STATUS_LABEL[s]}
                      </option>
                    ))}
                  </select>
                </td>
              </tr>
            ))}
            {tasks.length === 0 && (
              <tr>
                <td colSpan={5} className="p-4 text-center text-slate-400">
                  Sin tareas asignadas.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  )
}
