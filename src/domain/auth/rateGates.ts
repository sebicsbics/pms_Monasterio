import type { UserRole } from './profile'

// Puede editar la tarifa de una reserva (check-in, walk-in, override
// post-check-in): root, reception y reception_admin — paridad de escritura
// (REQ-2), NO es una de las 3 RPC de folio (check_out_room, add_folio_charge,
// add_folio_product_charge) excluidas por el límite de dinero (REQ-3).
export function canEditRate(role: UserRole | null | undefined): boolean {
  return role === 'root' || role === 'reception' || role === 'reception_admin'
}
