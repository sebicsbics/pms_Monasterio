export type TicketKind = 'corrective' | 'preventive'
// La categoría ahora es un código de la tabla de referencia maintenance_categories
// (no un enum hardcodeado). Se resuelve a etiqueta con las categorías cargadas.
export type TicketCategory = string
export type TicketPriority = 'low' | 'medium' | 'high' | 'urgent'
export type TicketStatus =
  | 'open' | 'assigned' | 'in_progress' | 'resolved' | 'closed' | 'cancelled'

// Categoría de referencia (leída de la DB).
export interface Category {
  code: string
  label: string
}

// Construye un buscador de etiquetas a partir de las categorías cargadas.
export function categoryLabeler(categories: Category[]): (code: string) => string {
  const byCode = new Map(categories.map((c) => [c.code, c.label]))
  return (code) => byCode.get(code) ?? code
}

export const PRIORITY_LABEL: Record<TicketPriority, string> = {
  low: 'Baja',
  medium: 'Media',
  high: 'Alta',
  urgent: 'Urgente',
}

export const STATUS_LABEL: Record<TicketStatus, string> = {
  open: 'Abierto',
  assigned: 'Asignado',
  in_progress: 'En progreso',
  resolved: 'Resuelto',
  closed: 'Cerrado',
  cancelled: 'Cancelado',
}

// Flujo lineal principal del ticket (para el stepper visual). 'cancelled' es una
// salida lateral y se muestra aparte, no dentro de este flujo.
export const STATUS_FLOW: TicketStatus[] = [
  'open', 'assigned', 'in_progress', 'resolved', 'closed',
]

// Transiciones válidas del ciclo de vida. Un ticket no salta de abierto a cerrado.
export const NEXT_STATUS: Record<TicketStatus, TicketStatus[]> = {
  open: ['assigned', 'in_progress', 'cancelled'],
  assigned: ['in_progress', 'cancelled'],
  in_progress: ['resolved', 'cancelled'],
  resolved: ['closed', 'in_progress'], // reabrir si no quedó bien
  closed: [],
  cancelled: [],
}

export interface Ticket {
  id: string
  ticketNo: number
  kind: TicketKind
  category: TicketCategory
  title: string
  description: string | null
  roomId: string | null
  roomNumber: string | null
  area: string | null
  priority: TicketPriority
  status: TicketStatus
  assignedTo: string | null
  assigneeName: string | null
  reportedAt: string
  startedAt: string | null
  resolvedAt: string | null
  closedAt: string | null
  partsTotalBs: number // gasto en repuestos acumulado (fase 2)
}

// Un cambio de estado registrado en el historial del ticket.
export interface TicketEvent {
  status: TicketStatus
  changedAt: string
}

// Repuesto/consumo cargado a un ticket (fase 2). line_total lo calcula la DB.
export interface TicketPart {
  id: string
  ticketId: string
  description: string
  quantity: number
  unitCostBs: number
  lineTotalBs: number
}

// Agenda de mantenimiento preventivo (fase 3).
export interface Schedule {
  id: string
  title: string
  category: TicketCategory
  roomId: string | null
  roomNumber: string | null
  area: string | null
  priority: TicketPriority
  frequencyDays: number
  nextDueAt: string
  lastDoneAt: string | null
  active: boolean
  notes: string | null
}

// ¿La agenda está vencida o vence hoy? (comparación por fecha ISO YYYY-MM-DD)
export function isDue(nextDueAt: string): boolean {
  return nextDueAt <= new Date().toISOString().slice(0, 10)
}
