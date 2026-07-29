import { supabase } from './supabase'
import type {
  HousekeepingAssignment,
  AssignmentStatus,
} from '../domain/housekeeping/assignment'

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

// Cambia el estado y mantiene los timestamps para medir la duración:
//  - en_progreso: marca started_at (arranca el cronómetro).
//  - hecha: marca completed_at (para el cronómetro).
//  - pendiente: resetea ambos.
export async function updateAssignmentStatus(
  assignmentId: string,
  status: AssignmentStatus,
): Promise<void> {
  const now = new Date().toISOString()
  const patch: Record<string, unknown> = { status }
  if (status === 'in_progress') {
    patch.started_at = now
    patch.completed_at = null
  } else if (status === 'done') {
    patch.completed_at = now
  } else {
    // pendiente: vuelve a foja cero.
    patch.started_at = null
    patch.completed_at = null
  }
  const { error } = await supabase
    .from('housekeeping_assignments')
    .update(patch)
    .eq('id', assignmentId)
  if (error) throw new Error(error.message)
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
