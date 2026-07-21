export type AssignmentStatus = 'pending' | 'in_progress' | 'done'
export type AssignmentKind = 'stayover' | 'turnover'

export const ASSIGNMENT_STATUS_LABEL: Record<AssignmentStatus, string> = {
  pending: 'Pendiente',
  in_progress: 'En progreso',
  done: 'Hecha',
}

export const ASSIGNMENT_KIND_LABEL: Record<AssignmentKind, string> = {
  stayover: 'Repaso (huésped en curso)',
  turnover: 'Salida (rotación)',
}

export interface HousekeepingAssignment {
  id: string
  roomId: string
  roomNumber: string | null
  serviceDate: string // ISO date, storage format
  assignedTo: string | null
  kind: AssignmentKind
  status: AssignmentStatus
  notes: string | null
  completedAt: string | null
  createdAt: string
}
