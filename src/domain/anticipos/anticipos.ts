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
  receiptPath: string | null // foto del comprobante QR
  paymentReference: string | null // número de transacción de tarjeta
  receivedBy: string
  receivedAt: string
  notes: string | null
}

// Un anticipo con el contexto de su reserva ya resuelto (habitación,
// huésped, fechas). Es lo que se muestra en la lista de anticipos y en el
// selector de corrección: sin esto, elegir un anticipo obligaba a conocer
// de memoria el UUID de la reserva.
export interface AnticipoListItem {
  id: string
  reservationId: string
  roomNumber: string
  guestName: string
  checkInDate: string
  checkOutDate: string
  reservationStatus: string
  amountBs: number
  paymentMethod: string
  status: AnticipoStatus
  receiptPath: string | null
  paymentReference: string | null
  receivedByName: string
  receivedAt: string
  notes: string | null
}

// Etiqueta corta para el dropdown: habitación, huésped y monto son lo que
// permite reconocer un anticipo de un vistazo en el mostrador.
export function anticipoLabel(a: AnticipoListItem): string {
  return `Hab. ${a.roomNumber} · ${a.guestName} · Bs ${a.amountBs.toFixed(2)} · ${a.paymentMethod}`
}

// Sólo los anticipos 'active' se pueden corregir: en cuanto la reserva se
// cancela quedan 'forfeited' y se congelan (lo exige modify_anticipo).
export function isCorrectable(a: AnticipoListItem): boolean {
  return a.status === 'active'
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
