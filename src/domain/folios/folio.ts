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

// Un anticipo tal como vive en la base: lo recibido, su estado, y lo ya
// devuelto (que NO es una columna del anticipo: los reembolsos viven en
// la bitácora `anticipo_corrections`, append-only).
export interface AnticipoAmounts {
  amountBs: number
  refundedBs: number
  status: string // 'active' | 'forfeited'
}

/**
 * Anticipos NETOS de la reserva: lo que el huésped tiene a favor.
 *
 * Dos reglas, las dos con plata de por medio:
 *  - Solo cuentan los ACTIVOS. Un anticipo 'forfeited' es el del no-show
 *    que perdió el adelanto: esa plata se la quedó el hotel, no es un
 *    pago a cuenta del folio de nadie.
 *  - Se resta lo reembolsado, porque ya salió de caja.
 *
 * Cada anticipo se piso en 0: un reembolso mayor al anticipo sería un
 * dato corrupto y no puede convertirse en un cargo extra al huésped.
 */
export function netAnticipos(anticipos: AnticipoAmounts[]): number {
  return anticipos
    .filter((a) => a.status === 'active')
    .reduce((sum, a) => sum + Math.max(a.amountBs - a.refundedBs, 0), 0)
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
