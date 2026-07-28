import { useCallback, useEffect, useState } from 'react'
import { ChevronLeft, ChevronRight } from 'lucide-react'
import type { Task, TaskType, TaskStatus } from '../../domain/tasks/task'
import {
  TASK_TYPE_LABEL,
  TASK_STATUS_LABEL,
  TASK_STATUS_ORDER,
} from '../../domain/tasks/task'
import { fetchTasks, createTask, updateTaskStatus } from '../../services/tasks'
import { PageHeader } from '../../components/ui'
import { formatDateTime } from '../../lib/date'

// 'minibar' (Frigobar) queda fuera: ya no hay frigobares en las
// habitaciones. Se conserva TASK_TYPE_LABEL['minibar'] para mostrar tareas
// históricas.
const TASK_TYPES: TaskType[] = ['cleaning', 'maintenance', 'other']

const COLUMN_STYLE: Record<TaskStatus, string> = {
  pending: 'border-amber-200 bg-amber-50',
  in_progress: 'border-blue-200 bg-blue-50',
  done: 'border-green-200 bg-green-50',
}

export function TasksView() {
  const [tasks, setTasks] = useState<Task[]>([])
  const [error, setError] = useState<string | null>(null)

  const [taskType, setTaskType] = useState<TaskType>('cleaning')
  const [assignedToName, setAssignedToName] = useState('')
  const [notes, setNotes] = useState('')
  const [busy, setBusy] = useState(false)

  const reload = useCallback(() => {
    return fetchTasks()
      .then(setTasks)
      .catch((e: Error) => setError(e.message))
  }, [])

  useEffect(() => {
    void reload()
  }, [reload])

  async function handleCreate() {
    setBusy(true)
    setError(null)
    try {
      await createTask({ taskType, assignedToName, notes })
      setNotes('')
      setAssignedToName('')
      await reload()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  // Mueve una tarea a la columna anterior/siguiente del tablero.
  async function moveTask(task: Task, direction: -1 | 1) {
    const currentIndex = TASK_STATUS_ORDER.indexOf(task.status)
    const next = TASK_STATUS_ORDER[currentIndex + direction]
    if (!next) return
    try {
      await updateTaskStatus(task.id, next)
      await reload()
    } catch (e) {
      setError((e as Error).message)
    }
  }

  return (
    <div className="mx-auto max-w-6xl p-6">
      <PageHeader
        title="Tareas"
        subtitle="Tablero de handoff entre turnos — mové el trabajo entre columnas con ‹ ›"
      />

      {error && (
        <p className="mb-4 rounded bg-red-50 p-2 text-sm text-red-700">{error}</p>
      )}

      {/* Registrar tarea — lo que importa es dejar el pedido con su hora y
          quién lo abrió; la asignación es texto libre (cualquier persona). */}
      <div className="mb-6 rounded border border-slate-200 p-4">
        <h3 className="mb-3 font-semibold text-slate-700">Registrar tarea</h3>
        <div className="grid grid-cols-1 gap-2 sm:grid-cols-3">
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
          <input
            placeholder="Notas"
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
            className="rounded border border-slate-300 p-2"
          />
          <input
            placeholder="Asignar a… (nombre, opcional)"
            value={assignedToName}
            onChange={(e) => setAssignedToName(e.target.value)}
            className="rounded border border-slate-300 p-2"
          />
        </div>
        <button
          type="button"
          disabled={busy}
          onClick={handleCreate}
          className="mt-3 rounded bg-brand-700 px-4 py-2 text-sm font-medium text-white hover:bg-brand-800 disabled:opacity-50"
        >
          Registrar
        </button>
      </div>

      {/* Tablero Kanban: una columna por estado. */}
      <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
        {TASK_STATUS_ORDER.map((status) => {
          const columnTasks = tasks.filter((t) => t.status === status)
          return (
            <div
              key={status}
              className={`rounded border ${COLUMN_STYLE[status]} p-3`}
            >
              <div className="mb-3 flex items-center justify-between">
                <h4 className="font-semibold text-slate-700">
                  {TASK_STATUS_LABEL[status]}
                </h4>
                <span className="rounded-full bg-white px-2 py-0.5 text-xs font-medium text-slate-500">
                  {columnTasks.length}
                </span>
              </div>

              <div className="space-y-2">
                {columnTasks.map((t) => {
                  const index = TASK_STATUS_ORDER.indexOf(t.status)
                  return (
                    <div
                      key={t.id}
                      className="rounded border border-slate-200 bg-white p-3 shadow-sm"
                    >
                      <div className="flex items-center justify-between">
                        <span className="rounded bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-600">
                          {TASK_TYPE_LABEL[t.taskType]}
                        </span>
                        <div className="flex gap-1">
                          <button
                            type="button"
                            disabled={index === 0}
                            onClick={() => moveTask(t, -1)}
                            aria-label="Mover a la columna anterior"
                            className="rounded p-1 text-slate-400 hover:bg-slate-100 hover:text-slate-700 disabled:opacity-30"
                          >
                            <ChevronLeft size={16} />
                          </button>
                          <button
                            type="button"
                            disabled={index === TASK_STATUS_ORDER.length - 1}
                            onClick={() => moveTask(t, 1)}
                            aria-label="Mover a la columna siguiente"
                            className="rounded p-1 text-slate-400 hover:bg-slate-100 hover:text-slate-700 disabled:opacity-30"
                          >
                            <ChevronRight size={16} />
                          </button>
                        </div>
                      </div>

                      {t.notes && (
                        <p className="mt-2 text-sm text-slate-700">{t.notes}</p>
                      )}

                      {t.assignedToName && (
                        <p className="mt-2 text-xs text-slate-500">
                          Asignada a: <span className="font-medium">{t.assignedToName}</span>
                        </p>
                      )}

                      <p className="mt-2 border-t border-slate-100 pt-2 text-xs text-slate-400">
                        Abrió {t.createdByName ?? '—'} · {formatDateTime(t.createdAt)}
                      </p>
                    </div>
                  )
                })}

                {columnTasks.length === 0 && (
                  <p className="py-4 text-center text-xs text-slate-400">
                    Sin tareas.
                  </p>
                )}
              </div>
            </div>
          )
        })}
      </div>
    </div>
  )
}
