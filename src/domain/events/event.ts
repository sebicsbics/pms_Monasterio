export type EventStatus = 'scheduled' | 'done' | 'cancelled'
export type PaymentMethod = 'efectivo' | 'qr' | 'transferencia' | 'tarjeta'

export const EVENT_STATUS_LABEL: Record<EventStatus, string> = {
  scheduled: 'Programado',
  done: 'Realizado',
  cancelled: 'Cancelado',
}

export const PAYMENT_METHOD_LABEL: Record<PaymentMethod, string> = {
  efectivo: 'Efectivo',
  qr: 'QR',
  transferencia: 'Transferencia',
  tarjeta: 'Tarjeta',
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
