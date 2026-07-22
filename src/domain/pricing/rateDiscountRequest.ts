import type { UserRole } from '../auth/profile'

export type RateDiscountRequestStatus = 'pending' | 'approved' | 'rejected'

export interface RateDiscountRequest {
  id: string
  reservationId: string
  roomTypeId: string
  basePriceBs: number
  requestedPriceBs: number
  computedDiscountPct: number
  reason: string
  requestedBy: string
  status: RateDiscountRequestStatus
  resolvedBy: string | null
  resolvedAt: string | null
  appliedAt: string | null
  createdAt: string
}

// Solo reception_admin (o root) aprueba/rechaza solicitudes de descuento
// (approve_rate_discount_request / reject_rate_discount_request en
// 20260722020000_discount_approval_workflow.sql). El queue NO debe ser
// visible para reception ni accountant, aunque ambos puedan leer la tabla.
export function canApproveDiscountRequests(role: UserRole | null | undefined): boolean {
  return role === 'root' || role === 'reception_admin'
}
