import type { AnticipoStatus } from '../anticipos/anticipos'

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

// Un anticipo tal como vive en la base: lo recibido y su estado.
//
// No hay monto reembolsado porque el hotel NO reembolsa anticipos (regla
// de negocio, ver domain/anticipos): un anticipo o está vigente, o se
// perdió. Nada vuelve a salir de caja.
export interface AnticipoAmounts {
  amountBs: number
  status: AnticipoStatus
}

/**
 * Anticipos de la reserva que el huésped tiene a favor.
 *
 * Solo cuentan los ACTIVOS. Un anticipo 'forfeited' es el del no-show que
 * perdió el adelanto al cancelar: esa plata ya es del hotel, no es un
 * pago a cuenta del folio de nadie.
 */
export function netAnticipos(anticipos: AnticipoAmounts[]): number {
  return anticipos
    .filter((a) => a.status === 'active')
    .reduce((sum, a) => sum + a.amountBs, 0)
}

/**
 * Saldo a cobrar en el check-out: el folio menos lo ya adelantado.
 *
 * Nunca baja de 0. Si el anticipo excede el folio (el huésped se fue
 * antes de lo previsto), el check-out cobra 0 y ahí termina: el hotel no
 * devuelve la diferencia. Qué hacer con ese excedente —acreditarlo a
 * otra habitación, dejarlo a favor— es una decisión de mostrador, no algo
 * que el sistema resuelva sacando plata de caja.
 */
export function balanceDue(totalBs: number, anticipoTotalBs: number): number {
  return Math.max(totalBs - anticipoTotalBs, 0)
}

// Modalidad de pago del booking al que pertenece la reserva (stage 6,
// group-billing): 'each_stay' es el caso de siempre (cada habitación paga
// lo suyo); 'client' es una reserva institucional/agencia.
export type PayerMode = 'client' | 'each_stay'

/**
 * Total a considerar para el check-out: habitación + extras, EXCEPTO para
 * una reserva institucional (payer_mode='client'), donde check_out_room
 * cobra SOLO los extras de esta habitación -- el cargo de habitación es
 * parte del contrato del grupo, que se salda al cerrarse el grupo o al
 * saldar su cuenta por cobrar, nunca en el check-out individual (feat/
 * booking-17, decisión #391). Sin esta distinción, el preview mostraría
 * un monto que el RPC nunca va a cobrar.
 */
export function roomAndExtrasTotal(
  roomChargeBs: number,
  extrasTotalBs: number,
  payerMode: PayerMode,
): number {
  if (payerMode === 'client') return extrasTotalBs
  return roomChargeBs + extrasTotalBs
}
