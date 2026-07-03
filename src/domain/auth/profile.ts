export type UserRole = 'root' | 'accountant' | 'reception'

export interface Profile {
  id: string
  fullName: string
  role: UserRole
}

// Etiquetas legibles de cada rol.
export const ROLE_LABEL: Record<UserRole, string> = {
  root: 'Administrador',
  accountant: 'Contaduría',
  reception: 'Recepción',
}
