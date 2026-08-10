import type { UserRole } from './profile'

// Grupos de roles usados para gatear pestañas/acciones en la UI. Extraídos a
// un módulo puro (sin dependencias de React/Supabase) para poder testear
// membresía de roles sin montar el árbol de App.tsx ni requerir env vars.
// `owner` se suma a TODOS los grupos de visibilidad: ve el sistema entero.
// No puede escribir nada (ver canWrite y las políticas de la base), así que
// ampliar la visibilidad no amplía lo que puede hacer.
export const OPERATIONS: UserRole[] = ['root', 'reception', 'reception_admin', 'owner']
export const SHARED: UserRole[] = ['root', 'accountant', 'reception', 'reception_admin', 'owner']
export const FINANCE: UserRole[] = ['root', 'accountant', 'owner']
// Mismo alcance que la tabla `tasks`/`housekeeping_assignments` (que este
// módulo replica): root, reception y reception_admin.
export const HOUSEKEEPING: UserRole[] = ['root', 'reception', 'reception_admin', 'owner']
// Cola de aprobación de descuentos (change: discount-approval-workflow):
// SOLO root/reception_admin — reception y accountant pueden leer la tabla
// rate_discount_requests pero NO deben ver la cola de aprobación (paridad
// con approve_rate_discount_request/reject_rate_discount_request, que
// también son root/reception_admin-only).
export const DISCOUNT_APPROVAL: UserRole[] = ['root', 'reception_admin']
// Anticipos (adelantos de huésped, change: anticipos-management): la
// corrección/modificación es SOLO root/reception_admin (modify_anticipo es
// reception_admin-only vía guard inline en la RPC). Registrar un anticipo
// usa OPERATIONS (reception también puede registrar), NO este grupo.
export const ANTICIPOS_ADMIN: UserRole[] = ['root', 'reception_admin']

// ---------------------------------------------------------------------
// Pestañas que el dueño NO ve.
//
// `owner` está en los grupos de visibilidad porque ve la operación
// entera, pero hay pantallas que no le aportan nada: colas de aprobación
// que nunca va a resolver, el legajo del personal, la bitácora de
// accesos y su propio perfil (no es un empleado con datos que editar).
// Se listan aparte en vez de sacarlo de FINANCE o SHARED, que gatean
// también Analítica, Caja o el Tablero — pantallas que sí debe ver.
// ---------------------------------------------------------------------
export const FINANCE_STAFF: UserRole[] = ['root', 'accountant']
export const STAFF: UserRole[] = ['root', 'accountant', 'reception', 'reception_admin']
