// Pase de información: una línea de la bitácora entre turnos (objetos
// olvidados, avisos, pendientes que persisten en el tiempo).
export interface InfoNote {
  id: string
  content: string
  createdAt: string
  createdByName: string | null
  resolved: boolean
  resolvedAt: string | null
  resolvedByName: string | null
  resolvedNote: string | null
}

export interface InfoNoteFilters {
  search?: string
  from?: string // 'YYYY-MM-DD'
  to?: string
  includeResolved?: boolean
}
