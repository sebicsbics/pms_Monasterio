export type MovementKind = 'income' | 'expense'

export const INCOME_CATEGORIES: Record<string, string> = {
  cobro_habitacion: 'Cobro habitación',
  venta_minibar: 'Venta minibar',
  evento: 'Evento / salón',
  adelanto: 'Adelanto / seña',
  reembolso: 'Reembolso recibido',
  otro_ingreso: 'Otro ingreso',
}

export const EXPENSE_CATEGORIES: Record<string, string> = {
  compras: 'Compras / insumos',
  limpieza: 'Limpieza',
  mantenimiento: 'Mantenimiento',
  transporte: 'Transporte',
  servicios: 'Servicios (luz, agua, etc.)',
  sueldos: 'Adelanto de sueldo',
  otro_egreso: 'Otro egreso',
}

export function categoryLabel(kind: MovementKind, code: string): string {
  const map = kind === 'income' ? INCOME_CATEGORIES : EXPENSE_CATEGORIES
  return map[code] ?? code
}

export interface CashSession {
  id: string
  openedAt: string
  openingBalanceBs: number
  closedAt: string | null
  countedBalanceBs: number | null
  status: 'open' | 'closed'
  notes: string | null
}

export interface CashMovement {
  id: string
  kind: MovementKind
  category: string
  amountBs: number
  concept: string | null
  receiptPath: string | null
  paymentMethod: string | null
  createdAt: string
  voided: boolean
  voidReason: string | null
}
