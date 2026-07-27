export type TaskType = 'cleaning' | 'minibar' | 'maintenance' | 'other'
export type TaskStatus = 'pending' | 'in_progress' | 'done'

export const TASK_TYPE_LABEL: Record<TaskType, string> = {
  cleaning: 'Limpieza',
  minibar: 'Frigobar',
  maintenance: 'Mantenimiento',
  other: 'Otro',
}

export const TASK_STATUS_LABEL: Record<TaskStatus, string> = {
  pending: 'Pendiente',
  in_progress: 'En progreso',
  done: 'Hecha',
}

export interface Task {
  id: string
  taskType: TaskType
  status: TaskStatus
  notes: string | null
  assignedToName: string | null // texto libre: a quién se le pasa la tarea
  createdAt: string
  createdBy: string | null // profile id de quien abrió el ticket
  createdByName: string | null // nombre resuelto server-side (list_tasks)
}

// Orden de las columnas del tablero Kanban.
export const TASK_STATUS_ORDER: TaskStatus[] = ['pending', 'in_progress', 'done']

export interface AssignableStaff {
  personId: string
  fullName: string
  jobTitle: string
}
