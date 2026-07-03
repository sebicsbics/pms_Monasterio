import { supabase } from './supabase'
import type { Employee } from '../domain/employees/employee'

interface EmployeeRow {
  person_id: string
  job_title: string
  hire_date: string
  salary: number | null
  status: string
  people: { first_name: string; last_name: string; email: string | null } | null
}

// La RLS de la tabla employees solo devuelve filas a root/accountant.
export async function fetchEmployees(): Promise<Employee[]> {
  const { data, error } = await supabase
    .from('employees')
    .select(
      'person_id, job_title, hire_date, salary, status, people ( first_name, last_name, email )',
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
  }))
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
