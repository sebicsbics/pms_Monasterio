import { supabase } from './supabase'
import type { Anticipo, AnticipoListItem, AnticipoStatus } from '../domain/anticipos/anticipos'
import type { PaymentProof } from '../domain/payments/paymentProof'
import { EMPTY_PAYMENT_PROOF, proofForMethod } from '../domain/payments/paymentProof'
import { uploadReceipt } from './receipts'

function mapAnticipo(r: Record<string, unknown>): Anticipo {
  return {
    id: r.id as string,
    reservationId: r.reservation_id as string,
    amountBs: Number(r.amount_bs),
    paymentMethod: r.payment_method as string,
    status: r.status as Anticipo['status'],
    cashMovementId: (r.cash_movement_id as string | null) ?? null,
    receiptPath: (r.receipt_path as string | null) ?? null,
    paymentReference: (r.payment_reference as string | null) ?? null,
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
  proof?: PaymentProof
  mixed?: { cashBs: number; nonCashBs: number; nonCashMethod: string } | null
}): Promise<Anticipo> {
  const { receipt, paymentReference } = proofForMethod(
    input.mixed ? input.mixed.nonCashMethod : input.paymentMethod,
    input.proof ?? EMPTY_PAYMENT_PROOF,
  )
  const { data, error } = await supabase.rpc('record_anticipo', {
    p_reservation_id: input.reservationId,
    p_amount_bs: input.amountBs,
    p_payment_method: input.paymentMethod,
    p_notes: input.notes,
    p_receipt_path: await uploadReceipt(receipt),
    p_payment_reference: paymentReference,
    p_cash_bs: input.mixed?.cashBs ?? null,
    p_non_cash_bs: input.mixed?.nonCashBs ?? null,
    p_non_cash_method: input.mixed?.nonCashMethod ?? null,
  })
  if (error) throw new Error(error.message)
  return mapAnticipo(data as Record<string, unknown>)
}

export async function modifyAnticipo(
  anticipoId: string,
  newAmountBs: number,
  newPaymentMethod: string,
  reason: string,
  proof: PaymentProof = EMPTY_PAYMENT_PROOF,
  mixed: { cashBs: number; nonCashBs: number; nonCashMethod: string } | null = null,
): Promise<Anticipo> {
  // Con MIXTO el respaldo pertenece a la parte electrónica: resolverlo
  // contra 'MIXTO' lo descartaría (no es ni QR ni tarjeta).
  const { receipt, paymentReference } = proofForMethod(
    mixed ? mixed.nonCashMethod : newPaymentMethod,
    proof,
  )
  const { data, error } = await supabase.rpc('modify_anticipo', {
    p_anticipo_id: anticipoId,
    p_new_amount_bs: newAmountBs,
    p_new_payment_method: newPaymentMethod,
    p_reason: reason,
    p_receipt_path: await uploadReceipt(receipt),
    p_payment_reference: paymentReference,
    p_cash_bs: mixed?.cashBs ?? null,
    p_non_cash_bs: mixed?.nonCashBs ?? null,
    p_non_cash_method: mixed?.nonCashMethod ?? null,
  })
  if (error) throw new Error(error.message)
  return mapAnticipo(data as Record<string, unknown>)
}

// Todos los anticipos con su contexto, para la lista y el selector de
// corrección. El join lo resuelve la RPC.
export async function listAnticipos(
  onlyActive = false,
  limit = 200,
): Promise<AnticipoListItem[]> {
  const { data, error } = await supabase.rpc('list_anticipos', {
    p_only_active: onlyActive,
    p_limit: limit,
  })
  if (error) throw new Error(error.message)
  return (data as Record<string, unknown>[]).map((r) => ({
    id: r.id as string,
    reservationId: r.reservation_id as string,
    roomNumber: r.room_number as string,
    guestName: r.guest_name as string,
    checkInDate: r.check_in_date as string,
    checkOutDate: r.check_out_date as string,
    reservationStatus: r.reservation_status as string,
    amountBs: Number(r.amount_bs),
    paymentMethod: r.payment_method as string,
    status: r.status as AnticipoStatus,
    receiptPath: (r.receipt_path as string | null) ?? null,
    paymentReference: (r.payment_reference as string | null) ?? null,
    receivedByName: (r.received_by_name as string | null) ?? '—',
    receivedAt: r.received_at as string,
    notes: (r.notes as string | null) ?? null,
  }))
}
