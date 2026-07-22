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
// Cola de aprobación de descuentos (change: discount-approval-workflow):
// SOLO root/reception_admin — reception y accountant pueden leer la tabla
// rate_discount_requests pero NO deben ver la cola de aprobación (paridad
// con approve_rate_discount_request/reject_rate_discount_request, que
// también son root/reception_admin-only).
export const DISCOUNT_APPROVAL: UserRole[] = ['root', 'reception_admin']
