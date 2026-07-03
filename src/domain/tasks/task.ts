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
  roomId: string | null
  roomNumber: string | null
  assignedTo: string | null // person_id del empleado
  status: TaskStatus
  notes: string | null
  createdAt: string
}

export interface AssignableStaff {
  personId: string
  fullName: string
  jobTitle: string
}
