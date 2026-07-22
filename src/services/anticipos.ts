import { supabase } from './supabase'
import type { Anticipo } from '../domain/anticipos/anticipos'

function mapAnticipo(r: Record<string, unknown>): Anticipo {
  return {
    id: r.id as string,
    reservationId: r.reservation_id as string,
    amountBs: Number(r.amount_bs),
    refundedAmountBs: Number(r.refunded_amount_bs),
    paymentMethod: r.payment_method as string,
    status: r.status as Anticipo['status'],
    cashMovementId: (r.cash_movement_id as string | null) ?? null,
    receivedBy: r.received_by as string,
    receivedAt: r.received_at as string,
    notes: (r.notes as string | null) ?? null,
  }
}

export async function fetchAnticipos(reservationId: string): Promise<Anticipo[]> {
  const { data, error } = await supabase
    .from('anticipos')
    .select('*')
    .eq('reservation_id', reservationId)
    .order('received_at', { ascending: false })
  if (error) throw new Error(error.message)
  return (data ?? []).map(mapAnticipo)
}

export async function recordAnticipo(input: {
  reservationId: string
  amountBs: number
  paymentMethod: string
  notes: string | null
}): Promise<Anticipo> {
  const { data, error } = await supabase.rpc('record_anticipo', {
    p_reservation_id: input.reservationId,
    p_amount_bs: input.amountBs,
    p_payment_method: input.paymentMethod,
    p_notes: input.notes,
  })
  if (error) throw new Error(error.message)
  return mapAnticipo(data as Record<string, unknown>)
}

export async function refundAnticipo(
  anticipoId: string,
  refundBs: number,
  reason: string,
): Promise<Anticipo> {
  const { data, error } = await supabase.rpc('refund_anticipo', {
    p_anticipo_id: anticipoId,
    p_refund_bs: refundBs,
    p_reason: reason,
  })
  if (error) throw new Error(error.message)
  return mapAnticipo(data as Record<string, unknown>)
}

export async function modifyAnticipo(
  anticipoId: string,
  newAmountBs: number,
  newPaymentMethod: string,
  reason: string,
): Promise<Anticipo> {
  const { data, error } = await supabase.rpc('modify_anticipo', {
    p_anticipo_id: anticipoId,
    p_new_amount_bs: newAmountBs,
    p_new_payment_method: newPaymentMethod,
    p_reason: reason,
  })
  if (error) throw new Error(error.message)
  return mapAnticipo(data as Record<string, unknown>)
}
