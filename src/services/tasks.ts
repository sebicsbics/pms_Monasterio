import { supabase } from './supabase'
import type {
  Task,
  TaskType,
  TaskStatus,
  AssignableStaff,
} from '../domain/tasks/task'

interface TaskRow {
  id: string
  task_type: TaskType
  room_id: string | null
  assigned_to: string | null
  status: TaskStatus
  notes: string | null
  created_at: string
  rooms: { room_number: string } | null
}

export async function fetchTasks(): Promise<Task[]> {
  const { data, error } = await supabase
    .from('tasks')
    .select(
      'id, task_type, room_id, assigned_to, status, notes, created_at, rooms ( room_number )',
    )
    .order('created_at', { ascending: false })
  if (error) throw new Error(error.message)

  return (data as unknown as TaskRow[]).map((r) => ({
    id: r.id,
    taskType: r.task_type,
    roomId: r.room_id,
    roomNumber: r.rooms?.room_number ?? null,
    assignedTo: r.assigned_to,
    status: r.status,
    notes: r.notes,
    createdAt: r.created_at,
  }))
}

// Personal asignable (mucamas, etc.) — vista segura sin sueldos.
export async function fetchAssignableStaff(): Promise<AssignableStaff[]> {
  // assignable_staff pasó de vista SECURITY DEFINER a función (mismo resultado,
  // sin el advisory del linter). La función ya devuelve ordenado por nombre.
  const { data, error } = await supabase.rpc('assignable_staff')
  if (error) throw new Error(error.message)
  return (data as Record<string, unknown>[]).map((r) => ({
    personId: r.person_id as string,
    fullName: r.full_name as string,
    jobTitle: r.job_title as string,
  }))
}

export async function createTask(input: {
  taskType: TaskType
  roomId: string | null
  assignedTo: string | null
  notes: string
}): Promise<void> {
  const { error } = await supabase.from('tasks').insert({
    task_type: input.taskType,
    room_id: input.roomId,
    assigned_to: input.assignedTo,
    notes: input.notes || null,
  })
  if (error) throw new Error(error.message)
}

export async function updateTaskStatus(
  taskId: string,
  status: TaskStatus,
): Promise<void> {
  const { error } = await supabase
    .from('tasks')
    .update({
      status,
      completed_at: status === 'done' ? new Date().toISOString() : null,
    })
    .eq('id', taskId)
  if (error) throw new Error(error.message)
}
