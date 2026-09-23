import { supabase } from './supabase'
import type {
  HousekeepingAssignment,
  HousekeepingAssignmentEvent,
  AssignmentStatus,
} from '../domain/housekeeping/assignment'

interface HousekeepingAssignmentEventRow {
  id: string
  assignment_id: string
  from_status: AssignmentStatus
  to_status: AssignmentStatus
  note: string | null
  created_by_name: string
  created_at: string
}

interface HousekeepingAssignmentRow {
  id: string
  room_id: string
  service_date: string
  assigned_to_name: string | null
  kind: HousekeepingAssignment['kind']
  status: AssignmentStatus
  notes: string | null
  started_at: string | null
  completed_at: string | null
  created_at: string
  rooms: { room_number: string } | null
}

export async function fetchAssignments(
  serviceDate: string,
): Promise<HousekeepingAssignment[]> {
  const { data, error } = await supabase
    .from('housekeeping_assignments')
    .select(
      'id, room_id, service_date, assigned_to_name, kind, status, notes, started_at, completed_at, created_at, rooms ( room_number )',
    )
    .eq('service_date', serviceDate)
    .order('created_at', { ascending: true })
  if (error) throw new Error(error.message)

  return (data as unknown as HousekeepingAssignmentRow[]).map((r) => ({
    id: r.id,
    roomId: r.room_id,
    roomNumber: r.rooms?.room_number ?? null,
    serviceDate: r.service_date,
    assignedToName: r.assigned_to_name,
    kind: r.kind,
    status: r.status,
    notes: r.notes,
    startedAt: r.started_at,
    completedAt: r.completed_at,
    createdAt: r.created_at,
  }))
}

export async function generateAssignments(serviceDate: string): Promise<void> {
  const { error } = await supabase.rpc('generate_housekeeping_assignments', {
    p_service_date: serviceDate,
  })
  if (error) throw new Error(error.message)
}

// Cambia el estado (y deja constancia en la bitácora de eventos) vía
// change_housekeeping_assignment_status: la lógica de timestamps
// (started_at/completed_at) ahora vive en la RPC, no acá.
export async function updateAssignmentStatus(
  assignmentId: string,
  status: AssignmentStatus,
  note?: string,
): Promise<void> {
  const { error } = await supabase.rpc('change_housekeeping_assignment_status', {
    p_assignment_id: assignmentId,
    p_status: status,
    p_note: note ?? null,
  })
  if (error) throw new Error(error.message)
}

// Nota suelta, sin cambiar el estado: se pasa el status actual como
// p_status (la RPC lo trata como evento "solo nota" cuando no cambia).
export async function addAssignmentNote(
  assignmentId: string,
  currentStatus: AssignmentStatus,
  note: string,
): Promise<void> {
  const { error } = await supabase.rpc('change_housekeeping_assignment_status', {
    p_assignment_id: assignmentId,
    p_status: currentStatus,
    p_note: note,
  })
  if (error) throw new Error(error.message)
}

// Historial de eventos (cambios de estado + notas) para el tablero,
// más reciente primero.
export async function fetchAssignmentEvents(
  assignmentIds: string[],
): Promise<HousekeepingAssignmentEvent[]> {
  const { data, error } = await supabase.rpc('list_housekeeping_assignment_events', {
    p_assignment_ids: assignmentIds,
  })
  if (error) throw new Error(error.message)

  return (data as unknown as HousekeepingAssignmentEventRow[]).map((r) => ({
    id: r.id,
    assignmentId: r.assignment_id,
    fromStatus: r.from_status,
    toStatus: r.to_status,
    note: r.note,
    createdByName: r.created_by_name,
    createdAt: r.created_at,
  }))
}

// Nombre de la mucama por texto libre (reemplaza al dropdown de empleados).
export async function assignStaffName(
  assignmentId: string,
  name: string,
): Promise<void> {
  const { error } = await supabase
    .from('housekeeping_assignments')
    .update({ assigned_to_name: name.trim() || null })
    .eq('id', assignmentId)
  if (error) throw new Error(error.message)
}
