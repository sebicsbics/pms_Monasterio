// Anticipos (adelantos de huésped) — dominio puro, sin dependencias de
// React/Supabase.
//
// El hotel NO reembolsa anticipos (decisión de negocio): si el huésped no
// viene, la reserva se reprograma o se cancela. Al cancelar, el anticipo
// queda 'forfeited' (perdido). Por eso acá no hay lógica de reembolso.

export type AnticipoStatus = 'active' | 'forfeited'

export interface Anticipo {
  id: string
  reservationId: string
  amountBs: number
  paymentMethod: string
  status: AnticipoStatus
  cashMovementId: string | null
  receivedBy: string
  receivedAt: string
  notes: string | null
}

// Traduce el mensaje crudo de add_cash_movement (sin caja abierta) a un
// mensaje accionable para recepción/reception_admin. record_anticipo puede
// fallar por este motivo (llama a add_cash_movement), que requiere una
// cash_session abierta.
export function userFacingAnticipoError(message: string): string {
  if (message.includes('No hay una caja abierta')) {
    return 'No hay una caja abierta. Abrí la caja antes de registrar un anticipo.'
  }
  return message
}
