import { supabase } from './supabase'
import type {
  Receivable,
  ReceivableAccount,
  ReceivableAccountKind,
  ReceivableStatus,
} from '../domain/receivables/receivable'
import type { PaymentProof } from '../domain/payments/paymentProof'
import { EMPTY_PAYMENT_PROOF, proofForMethod } from '../domain/payments/paymentProof'
import { uploadReceipt } from './receipts'

interface AccountRow {
  id: string
  name: string
  kind: ReceivableAccountKind
  contact: string | null
  notes: string | null
  is_active: boolean
}

export async function listReceivableAccounts(
  activeOnly = false,
): Promise<ReceivableAccount[]> {
  let q = supabase
    .from('receivable_accounts')
    .select('id, name, kind, contact, notes, is_active')
    .order('name', { ascending: true })
  if (activeOnly) q = q.eq('is_active', true)
  const { data, error } = await q
  if (error) throw new Error(error.message)
  return (data as AccountRow[]).map((r) => ({
    id: r.id,
    name: r.name,
    kind: r.kind,
    contact: r.contact,
    notes: r.notes,
    isActive: r.is_active,
  }))
}

export async function createReceivableAccount(input: {
  name: string
  kind: ReceivableAccountKind
  contact: string | null
  notes: string | null
}): Promise<void> {
  const { error } = await supabase.from('receivable_accounts').insert({
    name: input.name.trim(),
    kind: input.kind,
    contact: input.contact?.trim() || null,
    notes: input.notes?.trim() || null,
  })
  if (error) throw new Error(error.message)
}

interface ReceivableRow {
  id: string
  account_id: string
  account_name: string
  reservation_id: string | null
  room_number: string | null
  guest_name: string | null
  amount_bs: number | string
  concept: string | null
  status: ReceivableStatus
  created_at: string
  settled_at: string | null
  settle_method: string | null
  cancel_reason: string | null
}

export async function listReceivables(filters: {
  accountId?: string | null
  status?: ReceivableStatus | null
} = {}): Promise<Receivable[]> {
  const { data, error } = await supabase.rpc('list_receivables', {
    p_account_id: filters.accountId || null,
    p_status: filters.status || null,
  })
  if (error) throw new Error(error.message)
  return (data as ReceivableRow[]).map((r) => ({
    id: r.id,
    accountId: r.account_id,
    accountName: r.account_name,
    reservationId: r.reservation_id,
    roomNumber: r.room_number,
    guestName: r.guest_name,
    amountBs: Number(r.amount_bs),
    concept: r.concept,
    status: r.status,
    createdAt: r.created_at,
    settledAt: r.settled_at,
    settleMethod: r.settle_method,
    cancelReason: r.cancel_reason,
  }))
}

export async function settleReceivable(
  id: string,
  method: string,
  proof: PaymentProof = EMPTY_PAYMENT_PROOF,
): Promise<void> {
  const { receipt, paymentReference } = proofForMethod(method, proof)
  const { error } = await supabase.rpc('settle_receivable', {
    p_id: id,
    p_method: method,
    p_receipt_path: await uploadReceipt(receipt),
    p_payment_reference: paymentReference,
  })
  if (error) throw new Error(error.message)
}

export async function cancelReceivable(id: string, reason: string): Promise<void> {
  const trimmed = reason.trim()
  if (!trimmed) throw new Error('La justificación es obligatoria')
  const { error } = await supabase.rpc('cancel_receivable', { p_id: id, p_reason: trimmed })
  if (error) throw new Error(error.message)
}
