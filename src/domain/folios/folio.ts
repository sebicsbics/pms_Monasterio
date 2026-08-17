// Un consumo cargado al folio (minibar, spa, restaurante...).
export interface FolioCharge {
  id: string
  description: string
  amountBs: number
}

// El folio de una estadía: cargo de habitación + consumos, menos lo que
// el huésped ya pagó por adelantado.
export interface Folio {
  reservationId: string
  roomType: string
  roomChargeBs: number // total por la(s) noche(s)
  charges: FolioCharge[]
  extrasTotalBs: number // suma de consumos
  totalBs: number // habitación + consumos
  anticipoTotalBs: number // anticipos netos (recibido − reembolsado)
  balanceDueBs: number // lo que falta cobrar en el check-out
}

// Un anticipo tal como vive en la base: lo recibido y lo ya devuelto.
export interface AnticipoAmounts {
  amountBs: number
  refundedAmountBs: number
}

/**
 * Anticipos NETOS de la reserva: lo que el huésped tiene a favor.
 *
 * Un anticipo reembolsado ya no es plata del hotel, así que se resta lo
 * devuelto. Nunca da negativo: `refunded_amount_bs <= amount_bs` está
 * garantizado por un check en la tabla.
 */
export function netAnticipos(anticipos: AnticipoAmounts[]): number {
  return anticipos.reduce((sum, a) => sum + (a.amountBs - a.refundedAmountBs), 0)
}

/**
 * Saldo a cobrar en el check-out: el folio menos lo ya adelantado.
 *
 * Nunca baja de 0. Si el anticipo excede el folio (el huésped se fue
 * antes de lo previsto), la diferencia es un reembolso que se hace por
 * `refund_anticipo` — el check-out no saca plata de caja solo.
 */
export function balanceDue(totalBs: number, anticipoTotalBs: number): number {
  return Math.max(totalBs - anticipoTotalBs, 0)
}
