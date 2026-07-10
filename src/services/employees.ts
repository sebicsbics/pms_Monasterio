import { supabase } from './supabase'
import type { Employee, SystemProfile } from '../domain/employees/employee'

interface EmployeeRow {
  person_id: string
  job_title: string
  hire_date: string
  salary: number | null
  status: string
  user_id: string | null
  people: { first_name: string; last_name: string; email: string | null } | null
  account: { username: string | null; role: string | null } | null
}

// La RLS de la tabla employees solo devuelve filas a root/accountant.
export async function fetchEmployees(): Promise<Employee[]> {
  const { data, error } = await supabase
    .from('employees')
    .select(
      'person_id, job_title, hire_date, salary, status, user_id, ' +
        'people ( first_name, last_name, email ), ' +
        'account:profiles ( username, role )',
    )
    .order('hire_date', { ascending: false })
  if (error) throw new Error(error.message)

  return (data as unknown as EmployeeRow[]).map((r) => ({
    personId: r.person_id,
    firstName: r.people?.first_name ?? '',
    lastName: r.people?.last_name ?? '',
    email: r.people?.email ?? null,
    jobTitle: r.job_title,
    hireDate: r.hire_date,
    salary: r.salary === null ? null : Number(r.salary),
    status: r.status,
    userId: r.user_id,
    accountUsername: r.account?.username ?? null,
    accountRole: r.account?.role ?? null,
  }))
}

// Perfiles del sistema (para vincular). Solo root/accountant por RLS.
export async function fetchSystemProfiles(): Promise<SystemProfile[]> {
  const { data, error } = await supabase
    .from('profiles')
    .select('id, username, full_name, role')
    .order('username')
  if (error) throw new Error(error.message)
  return (data ?? []).map((r: Record<string, unknown>) => ({
    id: r.id as string,
    username: (r.username as string | null) ?? null,
    fullName: (r.full_name as string | null) ?? null,
    role: r.role as string,
  }))
}

// Alta unificada: crea empleado y, opcionalmente, lo vincula a un usuario
// existente configurando su rol/username. Todo en una transacción (RPC).
export async function createStaffMember(input: {
  firstName: string
  lastName: string
  email: string
  jobTitle: string
  hireDate: string
  salary: number
  userId: string | null
  role: string | null
  username: string | null
}): Promise<void> {
  const { error } = await supabase.rpc('create_staff_member', {
    p_first_name: input.firstName,
    p_last_name: input.lastName,
    p_email: input.email,
    p_job_title: input.jobTitle,
    p_hire_date: input.hireDate || null,
    p_salary: input.salary,
    p_user_id: input.userId,
    p_role: input.role,
    p_username: input.username || null,
  })
  if (error) throw new Error(error.message)
}

// Activa/desactiva un empleado (soft). Preserva la historia (no borra).
export async function setEmployeeStatus(
  personId: string,
  status: 'active' | 'inactive',
): Promise<void> {
  const { error } = await supabase
    .from('employees')
    .update({ status })
    .eq('person_id', personId)
  if (error) throw new Error(error.message)
}

// Elimina un empleado (solo root; la faceta employee, la persona queda).
export async function deleteEmployee(personId: string): Promise<void> {
  const { error } = await supabase.rpc('delete_employee', { p_person_id: personId })
  if (error) throw new Error(error.message)
}

// Vincula (o desvincula con null) un empleado a un usuario del sistema.
export async function linkEmployeeUser(
  personId: string,
  userId: string | null,
): Promise<void> {
  const { error } = await supabase
    .from('employees')
    .update({ user_id: userId })
    .eq('person_id', personId)
  if (error) throw new Error(error.message)
}

export async function createEmployee(input: {
  firstName: string
  lastName: string
  email: string
  jobTitle: string
  hireDate: string
  salary: number
}): Promise<void> {
  const { error } = await supabase.rpc('create_employee', {
    p_first_name: input.firstName,
    p_last_name: input.lastName,
    p_email: input.email,
    p_job_title: input.jobTitle,
    p_hire_date: input.hireDate || null,
    p_salary: input.salary,
  })
  if (error) throw new Error(error.message)
}
