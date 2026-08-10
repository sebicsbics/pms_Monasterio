import { createContext, useContext, type ReactNode } from 'react'
import { canWrite, type UserRole } from '../../domain/auth/profile'

// Rol del usuario disponible en cualquier vista sin enhebrarlo por props.
//
// Existe por el rol `owner` (solo lectura): gatear sus acciones requería
// pasar `role` a una docena de componentes que no lo necesitaban para nada
// más. El contexto evita ensuciar esas firmas.
//
// Esto es comodidad de UI, NO seguridad: lo que impide escribir a owner son
// las políticas de la base y los guards de las RPC.
const RoleContext = createContext<UserRole | null>(null)

export function RoleProvider({
  role,
  children,
}: {
  role: UserRole | null
  children: ReactNode
}) {
  return <RoleContext.Provider value={role}>{children}</RoleContext.Provider>
}

export function useRole(): UserRole | null {
  return useContext(RoleContext)
}

// ¿Este usuario puede ejecutar acciones de escritura?
export function useCanWrite(): boolean {
  return canWrite(useContext(RoleContext))
}
