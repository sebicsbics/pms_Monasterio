import type { UserRole } from './profile'

// Grupos de roles usados para gatear pestañas/acciones en la UI. Extraídos a
// un módulo puro (sin dependencias de React/Supabase) para poder testear
// membresía de roles sin montar el árbol de App.tsx ni requerir env vars.
export const OPERATIONS: UserRole[] = ['root', 'reception', 'reception_admin']
export const SHARED: UserRole[] = ['root', 'accountant', 'reception', 'reception_admin']
export const FINANCE: UserRole[] = ['root', 'accountant']
// Mismo alcance que la tabla `tasks`/`housekeeping_assignments` (que este
// módulo replica): root, reception y reception_admin.
export const HOUSEKEEPING: UserRole[] = ['root', 'reception', 'reception_admin']
