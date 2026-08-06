import { needsPaymentReference, needsReceiptPhoto, type PaymentProof } from './paymentProof'

// Pago mixto: parte en efectivo y parte por un medio electrónico.
//
// MIXTO no es una forma de pago en sí, es DOS: el efectivo entra al cajón
// y cuenta para el arqueo, lo electrónico no. Por eso se registra como dos
// movimientos de caja separados y no como uno solo etiquetado "mixto" —
// eso volvería a mezclar justo lo que la pestaña "Otros medios" separa.
export type NonCashMethod = 'QR' | 'TARJETA'

export const NON_CASH_METHODS: { code: NonCashMethod; label: string }[] = [
  { code: 'QR', label: 'QR' },
  { code: 'TARJETA', label: 'Tarjeta' },
]

export interface MixedPayment {
  cashBs: string // se guardan como texto: son inputs
  nonCashBs: string
  nonCashMethod: NonCashMethod
}

export const EMPTY_MIXED_PAYMENT: MixedPayment = {
  cashBs: '',
  nonCashBs: '',
  nonCashMethod: 'QR',
}

export function isMixed(method: string | null | undefined): boolean {
  return method === 'MIXTO'
}

// Completa la otra mitad cuando se conoce el total: si recepción escribe
// 300 sobre un total de 450, lo electrónico es 150. Evita el descuadre más
// probable, que es tipear los dos montos a mano.
export function completeSplit(
  total: number,
  edited: 'cash' | 'nonCash',
  value: string,
): Partial<MixedPayment> {
  const n = Number(value)
  if (value.trim() === '' || !Number.isFinite(n) || n < 0) {
    return edited === 'cash' ? { cashBs: value } : { nonCashBs: value }
  }
  const other = Math.round((total - n) * 100) / 100
  const rest = other > 0 ? String(other) : '0'
  return edited === 'cash'
    ? { cashBs: value, nonCashBs: rest }
    : { nonCashBs: value, cashBs: rest }
}

// Mensaje de error del desglose, o null si está bien. La misma regla se
// vuelve a exigir en record_mixed_income (fuente de verdad).
export function mixedPaymentError(
  total: number,
  split: MixedPayment,
  proof: PaymentProof,
): string | null {
  const cash = Number(split.cashBs)
  const nonCash = Number(split.nonCashBs)

  if (!Number.isFinite(cash) || !Number.isFinite(nonCash) ||
      split.cashBs.trim() === '' || split.nonCashBs.trim() === '') {
    return 'Ingresá cuánto se paga en efectivo y cuánto por el otro medio'
  }
  if (cash <= 0 || nonCash <= 0) {
    return 'Un pago mixto necesita monto en ambos medios; si es uno solo, elegí esa forma de pago'
  }
  if (Math.abs(cash + nonCash - total) > 0.01) {
    const diff = cash + nonCash - total
    return diff > 0
      ? `El desglose se pasa por ${diff.toFixed(2)} Bs del total (${total.toFixed(2)} Bs)`
      : `Faltan ${(-diff).toFixed(2)} Bs para llegar al total (${total.toFixed(2)} Bs)`
  }
  // La parte electrónica exige su respaldo igual que un pago simple.
  if (needsReceiptPhoto(split.nonCashMethod) && proof.receipt === null) {
    return 'La foto del comprobante es obligatoria para la parte pagada por QR'
  }
  if (needsPaymentReference(split.nonCashMethod) && proof.paymentReference.trim() === '') {
    return 'El código de referencia es obligatorio para la parte pagada con tarjeta'
  }
  return null
}
