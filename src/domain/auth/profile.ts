export type UserRole = 'root' | 'accountant' | 'reception' | 'reception_admin'

export interface Profile {
  id: string
  username: string
  fullName: string
  role: UserRole
  mustChangePassword: boolean
}

// Etiquetas legibles de cada rol.
export const ROLE_LABEL: Record<UserRole, string> = {
  root: 'Administrador',
  accountant: 'Contaduría',
  reception: 'Recepción',
  reception_admin: 'Recepción (Admin)',
}
