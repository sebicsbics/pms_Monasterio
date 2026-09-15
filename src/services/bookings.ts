import { supabase } from './supabase'
import type { PaymentProof } from '../domain/payments/paymentProof'
import { EMPTY_PAYMENT_PROOF, proofForMethod } from '../domain/payments/paymentProof'
import { uploadReceipt } from './receipts'

// Adelanto contra una reserva de grupo (payer_mode='client', stage 6).
// A diferencia de recordAnticipo (por reserva individual, each_stay),
// record_booking_advance escribe en booking_balances y devuelve
// directamente el id del MOVIMIENTO DE CAJA (no una fila propia) — en
// MIXTO es el de la pata efectivo, igual que record_mixed_income.
export async function recordBookingAdvance(input: {
  bookingId: string
  amountBs: number
  paymentMethod: string
  notes: string | null
  proof?: PaymentProof
  mixed?: { cashBs: number; nonCashBs: number; nonCashMethod: string } | null
}): Promise<string> {
  const { receipt, paymentReference } = proofForMethod(
    input.mixed ? input.mixed.nonCashMethod : input.paymentMethod,
    input.proof ?? EMPTY_PAYMENT_PROOF,
  )
  const { data, error } = await supabase.rpc('record_booking_advance', {
    p_booking_id: input.bookingId,
    p_amount_bs: input.amountBs,
    p_payment_method: input.paymentMethod,
    p_receipt_path: await uploadReceipt(receipt),
    p_payment_reference: paymentReference,
    p_cash_bs: input.mixed?.cashBs ?? null,
    p_non_cash_bs: input.mixed?.nonCashBs ?? null,
    p_non_cash_method: input.mixed?.nonCashMethod ?? null,
    p_notes: input.notes,
  })
  if (error) throw new Error(error.message)
  return data as string
}
