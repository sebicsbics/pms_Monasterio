import { supabase } from './supabase'
import { fetchAssignableStaff } from './tasks'
import type {
  Category,
  Schedule,
  Ticket,
  TicketCategory,
  TicketEvent,
  TicketKind,
  TicketPart,
  TicketPriority,
  TicketStatus,
} from '../domain/maintenance/ticket'

export async function fetchCategories(): Promise<Category[]> {
  const { data, error } = await supabase
    .from('maintenance_categories')
    .select('code, label')
    .eq('is_active', true)
    .order('sort_order')
  if (error) throw new Error(error.message)
  return (data ?? []).map((r: Record<string, unknown>) => ({
    code: r.code as string,
    label: r.label as string,
  }))
}

interface TicketRow {
  id: string
  ticket_no: number
  kind: TicketKind
  category: TicketCategory
  title: string
  description: string | null
  room_id: string | null
  area: string | null
  priority: TicketPriority
  status: TicketStatus
  assigned_to: string | null
  reported_at: string
  started_at: string | null
  resolved_at: string | null
  closed_at: string | null
  rooms: { room_number: string } | null
}

const SELECT =
  'id, ticket_no, kind, category, title, description, room_id, area, priority, ' +
  'status, assigned_to, reported_at, started_at, resolved_at, closed_at, ' +
  'rooms ( room_number )'

export async function fetchTickets(): Promise<Ticket[]> {
  const { data, error } = await supabase
    .from('maintenance_tickets')
    .select(SELECT)
    .order('reported_at', { ascending: false })
  if (error) throw new Error(error.message)

  // Resolver el nombre del asignado desde la vista segura (sin exponer sueldos).
  const staff = await fetchAssignableStaff()
  const nameById = new Map(staff.map((s) => [s.personId, s.fullName]))

  // Gasto en repuestos por ticket: se suman las líneas en una sola consulta.
  const { data: parts, error: pErr } = await supabase
    .from('maintenance_ticket_parts')
    .select('ticket_id, line_total_bs')
  if (pErr) throw new Error(pErr.message)
  const costById = new Map<string, number>()
  for (const p of (parts ?? []) as { ticket_id: string; line_total_bs: number }[]) {
    costById.set(p.ticket_id, (costById.get(p.ticket_id) ?? 0) + Number(p.line_total_bs))
  }

  return (data as unknown as TicketRow[]).map((r) => ({
    id: r.id,
    ticketNo: r.ticket_no,
    kind: r.kind,
    category: r.category,
    title: r.title,
    description: r.description,
    roomId: r.room_id,
    roomNumber: r.rooms?.room_number ?? null,
    area: r.area,
    priority: r.priority,
    status: r.status,
    assignedTo: r.assigned_to,
    assigneeName: r.assigned_to ? (nameById.get(r.assigned_to) ?? null) : null,
    reportedAt: r.reported_at,
    startedAt: r.started_at,
    resolvedAt: r.resolved_at,
    closedAt: r.closed_at,
    partsTotalBs: costById.get(r.id) ?? 0,
  }))
}

export async function createTicket(input: {
  title: string
  description: string
  category: TicketCategory
  priority: TicketPriority
  roomId: string | null
  area: string
}): Promise<void> {
  const { error } = await supabase.from('maintenance_tickets').insert({
    title: input.title,
    description: input.description || null,
    category: input.category,
    priority: input.priority,
    room_id: input.roomId,
    area: input.area || null,
    kind: 'corrective',
  })
  if (error) throw new Error(error.message)
}

export async function assignTicket(
  ticketId: string,
  personId: string,
): Promise<void> {
  const { error } = await supabase
    .from('maintenance_tickets')
    .update({ assigned_to: personId, status: 'assigned' })
    .eq('id', ticketId)
    .eq('status', 'open') // solo pasa a 'assigned' si venía de 'open'
  if (error) throw new Error(error.message)
}

// Solo root puede borrar (además la RLS lo exige). Cascada a repuestos y eventos.
export async function deleteTicket(ticketId: string): Promise<void> {
  const { error } = await supabase
    .from('maintenance_tickets')
    .delete()
    .eq('id', ticketId)
  if (error) throw new Error(error.message)
}

// Historial de estados por los que pasó el ticket (registrado por trigger).
export async function fetchTicketEvents(ticketId: string): Promise<TicketEvent[]> {
  const { data, error } = await supabase
    .from('maintenance_ticket_events')
    .select('status, changed_at')
    .eq('ticket_id', ticketId)
    .order('changed_at')
  if (error) throw new Error(error.message)
  return (data ?? []).map((r: Record<string, unknown>) => ({
    status: r.status as TicketStatus,
    changedAt: r.changed_at as string,
  }))
}

// Cambia el estado y sella el timestamp correspondiente. Los sellos son la
// materia prima de las métricas de tiempo de respuesta (fase 4).
export async function updateTicketStatus(
  ticketId: string,
  status: TicketStatus,
): Promise<void> {
  const patch: Record<string, unknown> = { status }
  if (status === 'in_progress') patch.started_at = new Date().toISOString()
  if (status === 'resolved') patch.resolved_at = new Date().toISOString()
  if (status === 'closed') patch.closed_at = new Date().toISOString()
  const { error } = await supabase
    .from('maintenance_tickets')
    .update(patch)
    .eq('id', ticketId)
  if (error) throw new Error(error.message)
}

// ---------- Fase 2: repuestos ----------

export async function fetchTicketParts(ticketId: string): Promise<TicketPart[]> {
  const { data, error } = await supabase
    .from('maintenance_ticket_parts')
    .select('id, ticket_id, description, quantity, unit_cost_bs, line_total_bs')
    .eq('ticket_id', ticketId)
    .order('created_at')
  if (error) throw new Error(error.message)
  return (data ?? []).map((r: Record<string, unknown>) => ({
    id: r.id as string,
    ticketId: r.ticket_id as string,
    description: r.description as string,
    quantity: Number(r.quantity),
    unitCostBs: Number(r.unit_cost_bs),
    lineTotalBs: Number(r.line_total_bs),
  }))
}

export async function addTicketPart(
  ticketId: string,
  input: { description: string; quantity: number; unitCostBs: number },
): Promise<void> {
  const { error } = await supabase.from('maintenance_ticket_parts').insert({
    ticket_id: ticketId,
    description: input.description,
    quantity: input.quantity,
    unit_cost_bs: input.unitCostBs,
  })
  if (error) throw new Error(error.message)
}

export async function deleteTicketPart(partId: string): Promise<void> {
  const { error } = await supabase
    .from('maintenance_ticket_parts')
    .delete()
    .eq('id', partId)
  if (error) throw new Error(error.message)
}

// ---------- Fase 3: agendas de preventivo ----------

interface ScheduleRow {
  id: string
  title: string
  category: TicketCategory
  room_id: string | null
  area: string | null
  priority: TicketPriority
  frequency_days: number
  next_due_at: string
  last_done_at: string | null
  active: boolean
  notes: string | null
  rooms: { room_number: string } | null
}

export async function fetchSchedules(): Promise<Schedule[]> {
  const { data, error } = await supabase
    .from('maintenance_schedules')
    .select(
      'id, title, category, room_id, area, priority, frequency_days, ' +
        'next_due_at, last_done_at, active, notes, rooms ( room_number )',
    )
    .order('next_due_at')
  if (error) throw new Error(error.message)
  return (data as unknown as ScheduleRow[]).map((r) => ({
    id: r.id,
    title: r.title,
    category: r.category,
    roomId: r.room_id,
    roomNumber: r.rooms?.room_number ?? null,
    area: r.area,
    priority: r.priority,
    frequencyDays: r.frequency_days,
    nextDueAt: r.next_due_at,
    lastDoneAt: r.last_done_at,
    active: r.active,
    notes: r.notes,
  }))
}

export async function createSchedule(input: {
  title: string
  category: TicketCategory
  priority: TicketPriority
  roomId: string | null
  area: string
  frequencyDays: number
  nextDueAt: string
  notes: string
}): Promise<void> {
  const { error } = await supabase.from('maintenance_schedules').insert({
    title: input.title,
    category: input.category,
    priority: input.priority,
    room_id: input.roomId,
    area: input.area || null,
    frequency_days: input.frequencyDays,
    next_due_at: input.nextDueAt,
    notes: input.notes || null,
  })
  if (error) throw new Error(error.message)
}

// Genera el ticket preventivo y avanza la agenda (lógica en la DB).
export async function generateTicketFromSchedule(scheduleId: string): Promise<void> {
  const { error } = await supabase.rpc('create_ticket_from_schedule', {
    p_schedule_id: scheduleId,
  })
  if (error) throw new Error(error.message)
}

export async function setScheduleActive(
  scheduleId: string,
  active: boolean,
): Promise<void> {
  const { error } = await supabase
    .from('maintenance_schedules')
    .update({ active })
    .eq('id', scheduleId)
  if (error) throw new Error(error.message)
}

// ---------- Fase 4: métricas ----------

export interface MtKpis {
  totalTickets: number
  activos: number
  preventivos: number
  horasRespuestaProm: number | null
  horasResolucionProm: number | null
}
export interface MtResponseByMonth {
  month: string
  resueltos: number
  horasRespuesta: number | null
  horasResolucion: number | null
}
export interface MtSpendByMonth {
  month: string
  gastoBs: number
}
export interface MtByCategory {
  categoria: string
  tickets: number
  gastoBs: number
}
export interface MtActiveByPriority {
  priority: TicketPriority
  tickets: number
}

const n = (v: unknown): number => Number(v ?? 0)
const nOrNull = (v: unknown): number | null => (v == null ? null : Number(v))

export async function fetchMtKpis(): Promise<MtKpis> {
  const { data, error } = await supabase.from('v_mt_kpis').select('*').single()
  if (error) throw new Error(error.message)
  const r = data as Record<string, unknown>
  return {
    totalTickets: n(r.total_tickets),
    activos: n(r.activos),
    preventivos: n(r.preventivos),
    horasRespuestaProm: nOrNull(r.horas_respuesta_prom),
    horasResolucionProm: nOrNull(r.horas_resolucion_prom),
  }
}

export async function fetchMtResponseByMonth(): Promise<MtResponseByMonth[]> {
  const { data, error } = await supabase.from('v_mt_response_by_month').select('*')
  if (error) throw new Error(error.message)
  return (data ?? []).map((r: Record<string, unknown>) => ({
    month: String(r.month),
    resueltos: n(r.resueltos),
    horasRespuesta: nOrNull(r.horas_respuesta),
    horasResolucion: nOrNull(r.horas_resolucion),
  }))
}

export async function fetchMtSpendByMonth(): Promise<MtSpendByMonth[]> {
  const { data, error } = await supabase.from('v_mt_spend_by_month').select('*')
  if (error) throw new Error(error.message)
  return (data ?? []).map((r: Record<string, unknown>) => ({
    month: String(r.month),
    gastoBs: n(r.gasto_bs),
  }))
}

export async function fetchMtByCategory(): Promise<MtByCategory[]> {
  const { data, error } = await supabase.from('v_mt_by_category').select('*')
  if (error) throw new Error(error.message)
  return (data ?? []).map((r: Record<string, unknown>) => ({
    categoria: String(r.categoria),
    tickets: n(r.tickets),
    gastoBs: n(r.gasto_bs),
  }))
}

export async function fetchMtActiveByPriority(): Promise<MtActiveByPriority[]> {
  const { data, error } = await supabase.from('v_mt_active_by_priority').select('*')
  if (error) throw new Error(error.message)
  return (data ?? []).map((r: Record<string, unknown>) => ({
    priority: r.priority as TicketPriority,
    tickets: n(r.tickets),
  }))
}
