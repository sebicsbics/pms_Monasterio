import { supabase } from './supabase'
import type { RateDiscountRequest } from '../domain/pricing/rateDiscountRequest'

interface RateDiscountRequestRow {
  id: string
  reservation_id: string
  room_type_id: string
  base_price_bs: number
  requested_price_bs: number
  computed_discount_pct: number
  reason: string
  requested_by: string
  status: RateDiscountRequest['status']
  resolved_by: string | null
  resolved_at: string | null
  applied_at: string | null
  created_at: string
}

function toDomain(row: RateDiscountRequestRow): RateDiscountRequest {
  return {
    id: row.id,
    reservationId: row.reservation_id,
    roomTypeId: row.room_type_id,
    basePriceBs: Number(row.base_price_bs),
    requestedPriceBs: Number(row.requested_price_bs),
    computedDiscountPct: Number(row.computed_discount_pct),
    reason: row.reason,
    requestedBy: row.requested_by,
    status: row.status,
    resolvedBy: row.resolved_by,
    resolvedAt: row.resolved_at,
    appliedAt: row.applied_at,
    createdAt: row.created_at,
  }
}

// Cola de solicitudes pendientes (visible solo para reception_admin/root
// en la UI — la tabla también la puede leer reception/accountant, ver
// canApproveDiscountRequests en src/domain/pricing/rateDiscountRequest.ts).
export async function fetchPendingRequests(): Promise<RateDiscountRequest[]> {
  const { data, error } = await supabase
    .from('rate_discount_requests')
    .select('*')
    .eq('status', 'pending')
    .order('created_at', { ascending: true })
  if (error) throw new Error(error.message)
  return (data as RateDiscountRequestRow[]).map(toDomain)
}

// Chequeo liviano post-RPC: create_reservation/walk_in_check_in/
// override_reservation_rate mantienen su firma de retorno original (ver
// ADR en el diseño); el frontend detecta un descuento pendiente
// consultando esto justo después de llamar la RPC.
export async function fetchPendingForReservation(
  reservationId: string,
): Promise<RateDiscountRequest | null> {
  const { data, error } = await supabase
    .from('rate_discount_requests')
    .select('*')
    .eq('reservation_id', reservationId)
    .eq('status', 'pending')
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle()
  if (error) throw new Error(error.message)
  return data ? toDomain(data as RateDiscountRequestRow) : null
}

export async function approveRequest(requestId: string): Promise<void> {
  const { error } = await supabase.rpc('approve_rate_discount_request', {
    p_request_id: requestId,
  })
  if (error) throw new Error(error.message)
}

export async function rejectRequest(requestId: string, note?: string | null): Promise<void> {
  const { error } = await supabase.rpc('reject_rate_discount_request', {
    p_request_id: requestId,
    p_note: note ?? null,
  })
  if (error) throw new Error(error.message)
}
