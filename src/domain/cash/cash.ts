export type MovementKind = 'income' | 'expense'

export const INCOME_CATEGORIES: Record<string, string> = {
  cobro_habitacion: 'Cobro habitación',
  venta_minibar: 'Venta minibar',
  evento: 'Evento / salón',
  cobro_cuenta: 'Cobro cuenta por cobrar',
  adelanto: 'Adelanto / seña',
  // Sin categoría de reembolso: el hotel NO reembolsa (ver
  // domain/anticipos). Ofrecerla en el desplegable invitaba a registrar
  // un movimiento que la operación no tiene. `categoryLabel` igual sabe
  // mostrar un código desconocido tal cual, así que un movimiento
  // histórico con esa categoría se seguiría viendo.
  otro_ingreso: 'Otro ingreso',
}

export const EXPENSE_CATEGORIES: Record<string, string> = {
  compras: 'Compras / insumos',
  limpieza: 'Limpieza',
  mantenimiento: 'Mantenimiento',
  transporte: 'Transporte',
  servicios: 'Servicios (luz, agua, etc.)',
  sueldos: 'Adelanto de sueldo',
  ajuste_anticipo: 'Ajuste de anticipo',
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

// Formas de pago válidas para un ANTICIPO. Son las de caja más MIXTO: un
// anticipo es plata que YA entró, así que CTAS_POR_COBRAR (plata que
// todavía no entró) es una contradicción, y cortesías o intercambios no
// generan adelanto que registrar.
export const ANTICIPO_PAYMENT_METHODS = [
  ...CAJA_PAYMENT_METHODS,
  'MIXTO',
] as const

export function isAnticipoMethod(code: string): boolean {
  return (ANTICIPO_PAYMENT_METHODS as readonly string[]).includes(code)
}

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

// Un turno de caja cerrado (o el abierto), con el arqueo ya resuelto por
// `cash_session_history`. Es lo que necesita gerencia para el arqueo
// mensual: quién abrió, con cuánto, con cuánto cerró y qué diferencia hubo.
export interface CashSessionSummary {
  id: string
  openedAt: string
  openedByName: string
  openingBalanceBs: number
  closedAt: string | null
  closedByName: string | null
  countedBalanceBs: number | null
  cashIncomeBs: number
  cashExpenseBs: number
  // Esperado contando SÓLO el efectivo del cajón.
  expectedBs: number
  differenceBs: number | null
  otherIncomeBs: number
  otherExpenseBs: number
  movements: number
  status: 'open' | 'closed'
  notes: string | null
}

// Instante en que la caja dejó de cargar a mano los cobros por
// QR/depósito/tarjeta y pasó a registrarlos con su `payment_method`. Cae en
// el hueco real entre el último turno abierto bajo el criterio viejo
// (05/08 19:04Z) y el primero abierto bajo el nuevo (06/08 04:36Z).
export const OTHER_MEANS_CRITERION_END = Date.parse('2026-08-06T00:00:00Z')

// ¿A este turno le corresponde el criterio ANTERIOR al split, que sumaba
// todos los movimientos sin importar la forma de pago?
//
// Sólo a los que se arquearon así. Aplicarlo a un turno nuevo no informa
// nada: desde el split, lo que se cuenta al cerrar son billetes y lo
// "otro" está en el banco, así que la resta da siempre `-otros` — un
// faltante de cinco cifras en turnos que cerraron exactos.
export function usesOtherMeansCriterion(s: CashSessionSummary): boolean {
  return Date.parse(s.openedAt) < OTHER_MEANS_CRITERION_END
}

// Esperado bajo el criterio ANTERIOR al split efectivo/otros medios.
//
// Se conserva porque los turnos cerrados antes del cambio se arquearon con
// ese criterio: mostrar sólo el nuevo haría aparecer descuadres de cientos
// de bolivianos en turnos que cerraron cuadrados, y en un arqueo eso señala
// a una persona por un cambio de fórmula. `null` en los turnos posteriores:
// ahí el número no es un esperado de caja, es ruido.
export function expectedWithOtherMeansBs(s: CashSessionSummary): number | null {
  if (!usesOtherMeansCriterion(s)) return null
  return s.expectedBs + s.otherIncomeBs - s.otherExpenseBs
}

export function differenceWithOtherMeansBs(s: CashSessionSummary): number | null {
  const expected = expectedWithOtherMeansBs(s)
  if (expected === null || s.countedBalanceBs === null) return null
  return s.countedBalanceBs - expected
}
