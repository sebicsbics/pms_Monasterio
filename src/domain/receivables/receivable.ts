export type ReceivableAccountKind = 'empresa' | 'agencia' | 'persona'

export const ACCOUNT_KIND_LABEL: Record<ReceivableAccountKind, string> = {
  empresa: 'Empresa',
  agencia: 'Agencia',
  persona: 'Persona',
}

export type ReceivableStatus = 'pending' | 'paid' | 'cancelled'

export const RECEIVABLE_STATUS_LABEL: Record<ReceivableStatus, string> = {
  pending: 'Pendiente',
  paid: 'Cobrada',
  cancelled: 'Anulada',
}

export interface ReceivableAccount {
  id: string
  name: string
  kind: ReceivableAccountKind
  contact: string | null
  notes: string | null
  isActive: boolean
}

export interface Receivable {
  id: string
  accountId: string
  accountName: string
  reservationId: string | null
  roomNumber: string | null
  guestName: string | null
  amountBs: number
  concept: string | null
  status: ReceivableStatus
  createdAt: string
  settledAt: string | null
  settleMethod: string | null
  cancelReason: string | null
}
