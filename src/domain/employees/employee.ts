export interface Employee {
  personId: string
  firstName: string
  lastName: string
  email: string | null
  jobTitle: string
  hireDate: string
  salary: number | null
  status: string
  // Usuario del sistema vinculado (null si el empleado no tiene login).
  userId: string | null
  accountUsername: string | null
  accountRole: string | null
}

// Perfil de sistema disponible para vincular a un empleado.
export interface SystemProfile {
  id: string
  username: string | null
  fullName: string | null
  role: string
}
