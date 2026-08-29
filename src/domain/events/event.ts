export type EventStatus = 'scheduled' | 'done' | 'cancelled'
// Subconjunto operativo del catálogo canónico `payment_methods` (ver
// supabase/migrations/20260703130000_seed_channels_and_payments.sql).
// Eventos solo ofrece estos 4 en el selector; debe coincidir 1:1 con los
// códigos reales del catálogo, no inventar un vocabulario propio.
//
// Son los mismos 4 que `payment_records_income` acepta en caja: un cobro de
// evento es plata que entra igual que cualquier otra. DEPOSITO estaba acá
// como TRANSFERENCIA, un sinónimo que el catálogo arrastraba del Excel
// histórico y que se retiró en 20260829000000_unify_deposito_transferencia.
export type PaymentMethod = 'EFECTIVO' | 'QR' | 'DEPOSITO' | 'TARJETA'

export const EVENT_STATUS_LABEL: Record<EventStatus, string> = {
  scheduled: 'Programado',
  done: 'Realizado',
  cancelled: 'Cancelado',
}

export const PAYMENT_METHOD_LABEL: Record<PaymentMethod, string> = {
  EFECTIVO: 'Efectivo',
  QR: 'QR',
  DEPOSITO: 'Depósito',
  TARJETA: 'Tarjeta',
}

export interface EventType {
  id: string
  name: string
}

export interface EventArea {
  id: string
  name: string
}

export interface EventPayment {
  id: string
  amountBs: number
  method: PaymentMethod
  isDeposit: boolean
  paidAt: string
}

export interface HotelEvent {
  id: string
  title: string
  typeName: string | null
  eventDate: string
  startTime: string | null
  endTime: string | null
  priceBs: number
  status: EventStatus
  notes: string | null
  areas: string[]
  payments: EventPayment[]
  paidBs: number
}
