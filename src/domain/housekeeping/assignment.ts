export type AssignmentStatus = 'pending' | 'in_progress' | 'done'
export type AssignmentKind = 'stayover' | 'turnover' | 'carryover'

export const ASSIGNMENT_STATUS_LABEL: Record<AssignmentStatus, string> = {
  pending: 'Pendiente',
  in_progress: 'En progreso',
  done: 'Hecha',
}

// stayover = mismo huésped sigue → solo se limpia el cuarto ("Limpieza").
// turnover = salió el huésped → se prepara para uno nuevo ("Habilitar").
// carryover = quedó sucia de un día anterior, sin reserva que la explique
// hoy → nadie la liberó a tiempo ("Pendiente de días anteriores").
export const ASSIGNMENT_KIND_LABEL: Record<AssignmentKind, string> = {
  stayover: 'Limpieza',
  turnover: 'Habilitar',
  carryover: 'Pendiente de días anteriores',
}

export interface HousekeepingAssignmentEvent {
  id: string
  assignmentId: string
  fromStatus: AssignmentStatus
  toStatus: AssignmentStatus
  note: string | null
  createdByName: string
  createdAt: string
}

export interface HousekeepingAssignment {
  id: string
  roomId: string
  roomNumber: string | null
  serviceDate: string // ISO date, storage format
  assignedToName: string | null // texto libre: nombre de la mucama
  kind: AssignmentKind
  status: AssignmentStatus
  notes: string | null
  startedAt: string | null // pasó a en_progreso
  completedAt: string | null
  createdAt: string
}

// IDs de asignaciones que tienen al menos un evento con una nota real
// (no nula/en blanco) -- alimenta el filtro "Solo con notas/anomalías"
// del historial de limpieza.
export function assignmentIdsWithNotes(
  events: HousekeepingAssignmentEvent[],
): Set<string> {
  const ids = new Set<string>()
  for (const e of events) {
    if (e.note && e.note.trim()) ids.add(e.assignmentId)
  }
  return ids
}

// Duración entre inicio (en_progreso) y fin (hecha), en texto legible.
// Devuelve null si falta algún extremo o el rango es inválido.
export function formatDuration(
  startedAt: string | null,
  completedAt: string | null,
): string | null {
  if (!startedAt || !completedAt) return null
  const ms = new Date(completedAt).getTime() - new Date(startedAt).getTime()
  if (!Number.isFinite(ms) || ms < 0) return null
  const totalMin = Math.round(ms / 60000)
  if (totalMin < 1) return 'menos de 1 min'
  if (totalMin < 60) return `${totalMin} min`
  const h = Math.floor(totalMin / 60)
  const m = totalMin % 60
  return m === 0 ? `${h} h` : `${h} h ${m} min`
}
