// Respaldo de un cobro que NO es efectivo.
//
// Regla única del sistema, aplicada en todos los puntos donde se elige
// forma de pago (check-out, caja chica, anticipos, eventos, cuentas por
// cobrar):
//   - QR      → foto del comprobante (OBLIGATORIA: ningún huésped se va
//               sin mostrar el comprobante).
//   - TARJETA → código de referencia (OBLIGATORIO: sin él no se puede
//               conciliar el voucher con el extracto del POS).
// Cualquier otra forma de pago no pide respaldo. Ambas reglas se vuelven
// a exigir en las RPC (assert_payment_proof) — esto es sólo la primera
// barrera, la de la UI.

export interface PaymentProof {
  receipt: File | null
  paymentReference: string
}

export const EMPTY_PAYMENT_PROOF: PaymentProof = {
  receipt: null,
  paymentReference: '',
}

export function needsReceiptPhoto(method: string | null | undefined): boolean {
  return method === 'QR'
}

export function needsPaymentReference(method: string | null | undefined): boolean {
  return method === 'TARJETA'
}

// Mensaje de error si falta un respaldo obligatorio, o null si está bien.
// Se usa para deshabilitar el botón y para el mensaje al usuario; la regla
// se vuelve a exigir en las RPC (fuente de verdad).
export function paymentProofError(
  method: string | null | undefined,
  proof: PaymentProof,
): string | null {
  if (needsReceiptPhoto(method) && proof.receipt === null) {
    return 'La foto del comprobante es obligatoria para pagos por QR'
  }
  if (needsPaymentReference(method) && proof.paymentReference.trim() === '') {
    return 'El código de referencia es obligatorio para pagos con tarjeta'
  }
  return null
}

// Deja solo el respaldo que corresponde a la forma de pago elegida: si
// recepción cargó una foto y después cambió a tarjeta, esa foto no se
// manda. Evita comprobantes pegados a la forma de pago equivocada.
export function proofForMethod(
  method: string | null | undefined,
  proof: PaymentProof,
): { receipt: File | null; paymentReference: string | null } {
  return {
    receipt: needsReceiptPhoto(method) ? proof.receipt : null,
    paymentReference: needsPaymentReference(method)
      ? proof.paymentReference.trim() || null
      : null,
  }
}
