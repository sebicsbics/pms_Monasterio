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
  reembolso_anticipo: 'Reembolso anticipo',
  otro_egreso: 'Otro egreso',
}

export function categoryLabel(kind: MovementKind, code: string): string {
  const map = kind === 'income' ? INCOME_CATEGORIES : EXPENSE_CATEGORIES
  return map[code] ?? code
}

// Formas de pago admitidas EN CAJA CHICA. El catálogo `payment_methods`
// es global y tiene más códigos (CTAS_POR_COBRAR, MIXTO, CORTESÍA…) que
// sí valen para el check-out o los eventos, pero no para un movimiento de
// caja: acá solo entra plata de verdad, por uno de estos cuatro medios.
export const CAJA_PAYMENT_METHODS = ['EFECTIVO', 'DEPOSITO', 'TARJETA', 'QR'] as const

// El único medio que toca el efectivo físico que cuenta el recepcionista
// al cerrar. `null` = movimiento histórico anterior a que existiera la
// columna payment_method: en esa época todo era efectivo.
export function isCashMovement(m: CashMovement): boolean {
  return m.paymentMethod == null || m.paymentMethod === 'EFECTIVO'
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
