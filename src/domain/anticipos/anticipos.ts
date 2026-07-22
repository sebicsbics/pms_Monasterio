// Anticipos (adelantos de huésped) — dominio puro, sin dependencias de
// React/Supabase. Estas 3 funciones DEBEN mantenerse en paridad numérica
// exacta con el guard SQL de refund_anticipo (>, <=, redondeo a 2
// decimales) — mismo riesgo #3 documentado en discount-approval-workflow
// (discount_pct/discountPct). Cualquier cambio acá debe replicarse en
// supabase/migrations/20260723000000_anticipos_management.sql y viceversa.

export type AnticipoStatus = 'active' | 'partially_refunded' | 'refunded'

export interface Anticipo {
  id: string
  reservationId: string
  amountBs: number
  refundedAmountBs: number
  paymentMethod: string
  status: AnticipoStatus
  cashMovementId: string | null
  receivedBy: string
  receivedAt: string
  notes: string | null
}

type Balance = Pick<Anticipo, 'amountBs' | 'refundedAmountBs'>

export function remainingBalance(a: Balance): number {
  return Math.round((a.amountBs - a.refundedAmountBs) * 100) / 100
}

export function canRefund(a: Balance, refundBs: number): boolean {
  return refundBs > 0 && refundBs <= remainingBalance(a)
}

export function nextStatus(a: Balance, refundBs: number): 'partially_refunded' | 'refunded' {
  return refundBs >= remainingBalance(a) ? 'refunded' : 'partially_refunded'
}

// Traduce el mensaje crudo de add_cash_movement (sin caja abierta) a un
// mensaje accionable para recepción/reception_admin. Tanto record_anticipo
// como refund_anticipo pueden fallar por este motivo (ambos llaman a
// add_cash_movement), que requiere una cash_session abierta.
export function userFacingAnticipoError(message: string): string {
  if (message.includes('No hay una caja abierta')) {
    return 'No hay una caja abierta. Abrí la caja antes de registrar o reembolsar un anticipo.'
  }
  return message
}
