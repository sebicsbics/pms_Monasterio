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
  status: TaskStatus
  notes: string | null
  assigned_to_name: string | null
  created_at: string
  created_by: string | null
  created_by_name: string | null
}

// Trae las tareas vía RPC list_tasks: resuelve el nombre del creador
// server-side (profiles no es legible entre usuarios desde el cliente).
export async function fetchTasks(): Promise<Task[]> {
  const { data, error } = await supabase.rpc('list_tasks')
  if (error) throw new Error(error.message)

  return (data as TaskRow[]).map((r) => ({
    id: r.id,
    taskType: r.task_type,
    status: r.status,
    notes: r.notes,
    assignedToName: r.assigned_to_name,
    createdAt: r.created_at,
    createdBy: r.created_by,
    createdByName: r.created_by_name,
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
  assignedToName: string
  notes: string
}): Promise<void> {
  // created_by lo completa la DB con auth.uid() (default de la columna).
  const { error } = await supabase.from('tasks').insert({
    task_type: input.taskType,
    assigned_to_name: input.assignedToName.trim() || null,
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
