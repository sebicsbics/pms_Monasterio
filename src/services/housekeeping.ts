import { supabase } from './supabase'
import type {
  HousekeepingAssignment,
  AssignmentStatus,
} from '../domain/housekeeping/assignment'

interface HousekeepingAssignmentRow {
  id: string
  room_id: string
  service_date: string
  assigned_to: string | null
  kind: HousekeepingAssignment['kind']
  status: AssignmentStatus
  notes: string | null
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
      'id, room_id, service_date, assigned_to, kind, status, notes, completed_at, created_at, rooms ( room_number )',
    )
    .eq('service_date', serviceDate)
    .order('created_at', { ascending: true })
  if (error) throw new Error(error.message)

  return (data as unknown as HousekeepingAssignmentRow[]).map((r) => ({
    id: r.id,
    roomId: r.room_id,
    roomNumber: r.rooms?.room_number ?? null,
    serviceDate: r.service_date,
    assignedTo: r.assigned_to,
    kind: r.kind,
    status: r.status,
    notes: r.notes,
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

export async function updateAssignmentStatus(
  assignmentId: string,
  status: AssignmentStatus,
): Promise<void> {
  const { error } = await supabase
    .from('housekeeping_assignments')
    .update({
      status,
      completed_at: status === 'done' ? new Date().toISOString() : null,
    })
    .eq('id', assignmentId)
  if (error) throw new Error(error.message)
}

export async function assignStaff(
  assignmentId: string,
  personId: string | null,
): Promise<void> {
  const { error } = await supabase
    .from('housekeeping_assignments')
    .update({ assigned_to: personId })
    .eq('id', assignmentId)
  if (error) throw new Error(error.message)
}

export { fetchAssignableStaff } from './tasks'
