export type UserRole =
  | 'root'
  | 'accountant'
  | 'reception'
  | 'reception_admin'
  | 'owner'

// Roles que VEN todo el sistema pero no pueden modificar nada. El dueño
// del hotel quiere revisar los datos sin riesgo de cambiarlos por error;
// cualquier modificación la pide a root, que la ejecuta.
//
// Esto es la capa de UI: la barrera real está en la base (owner no figura
// en el guard de ninguna RPC, y las tablas de escritura directa quedaron
// restringidas por rol en 20260809010000). Ocultar los botones evita que
// el owner choque contra errores, no es lo que lo detiene.
export const READ_ONLY_ROLES: UserRole[] = ['owner']

export function canWrite(role: UserRole | null | undefined): boolean {
  return role != null && !READ_ONLY_ROLES.includes(role)
}

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
  owner: 'Propietario (solo lectura)',
}
