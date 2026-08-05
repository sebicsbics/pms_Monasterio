import { supabase } from './supabase'
import type {
  CashMovement,
  CashSession,
  MovementKind,
} from '../domain/cash/cash'
import { uploadReceipt } from './receipts'

function mapSession(r: Record<string, unknown>): CashSession {
  return {
    id: r.id as string,
    openedAt: r.opened_at as string,
    openingBalanceBs: Number(r.opening_balance_bs),
    closedAt: (r.closed_at as string | null) ?? null,
    countedBalanceBs: r.counted_balance_bs == null ? null : Number(r.counted_balance_bs),
    status: r.status as 'open' | 'closed',
    notes: (r.notes as string | null) ?? null,
  }
}

function mapMovement(r: Record<string, unknown>): CashMovement {
  return {
    id: r.id as string,
    kind: r.kind as MovementKind,
    category: r.category as string,
    amountBs: Number(r.amount_bs),
    concept: (r.concept as string | null) ?? null,
    receiptPath: (r.receipt_path as string | null) ?? null,
    paymentMethod: (r.payment_method as string | null) ?? null,
    createdAt: r.created_at as string,
    voided: Boolean(r.voided),
    voidReason: (r.void_reason as string | null) ?? null,
  }
}

export async function fetchOpenSession(): Promise<CashSession | null> {
  const { data, error } = await supabase
    .from('cash_sessions')
    .select('*')
    .eq('status', 'open')
    .maybeSingle()
  if (error) throw new Error(error.message)
  return data ? mapSession(data) : null
}

export async function fetchSessions(limit = 60): Promise<CashSession[]> {
  const { data, error } = await supabase
    .from('cash_sessions')
    .select('*')
    .order('opened_at', { ascending: false })
    .limit(limit)
  if (error) throw new Error(error.message)
  return (data ?? []).map(mapSession)
}

export async function fetchMovements(sessionId: string): Promise<CashMovement[]> {
  const { data, error } = await supabase
    .from('cash_movements')
    .select('*')
    .eq('session_id', sessionId)
    .order('created_at', { ascending: false })
  if (error) throw new Error(error.message)
  return (data ?? []).map(mapMovement)
}

export async function openCashSession(opening: number): Promise<void> {
  const { error } = await supabase.rpc('open_cash_session', { p_opening: opening })
  if (error) throw new Error(error.message)
}

export async function closeCashSession(counted: number, notes: string): Promise<void> {
  const { error } = await supabase.rpc('close_cash_session', {
    p_counted: counted,
    p_notes: notes || null,
  })
  if (error) throw new Error(error.message)
}

// Sube el recibo (si hay) al bucket privado y crea el movimiento.
export async function addCashMovement(input: {
  kind: MovementKind
  category: string
  amount: number
  concept: string
  receipt: File | null
  paymentMethod?: string | null
  paymentReference?: string | null
}): Promise<void> {
  const { error } = await supabase.rpc('add_cash_movement', {
    p_kind: input.kind,
    p_category: input.category,
    p_amount: input.amount,
    p_concept: input.concept || null,
    p_receipt_path: await uploadReceipt(input.receipt),
    p_payment_method: input.paymentMethod ?? null,
    p_payment_reference: input.paymentReference?.trim() || null,
  })
  if (error) throw new Error(error.message)
}

export async function voidMovement(id: string, reason: string): Promise<void> {
  const { error } = await supabase.rpc('void_cash_movement', { p_id: id, p_reason: reason })
  if (error) throw new Error(error.message)
}

export { receiptUrl } from './receipts'
