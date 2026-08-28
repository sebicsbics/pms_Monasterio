import { supabase } from './supabase'
import type { RoomOperationalStatus } from '../domain/rooms/room'
import { fetchPendingForReservation } from './rateDiscountRequestsService'
import {
  companionsToPayload,
  type CheckInPaymentInput,
  type CompanionGuest,
} from './arrivals'
import { recordAnticipo } from './anticipos'
import { uploadReceipt } from './receipts'

// Mensaje uniforme para el banner "descuento pendiente de aprobación",
// reusado en los 3 puntos de entrada de tarifa (create_reservation,
// walk_in_check_in, override_reservation_rate).
export function pendingDiscountMessage(pct: number): string {
  return (
    `Descuento pendiente de aprobación (${pct}%). ` +
    'Se facturó a precio de lista hasta que reception_admin lo apruebe.'
  )
}

export interface WalkInData {
  roomId: string
  roomTypeId: string
  firstName: string
  lastName: string
  document: string
  email: string
  birthDate: string // 'YYYY-MM-DD' o ''
  countryCode: string // ISO-3, ej 'BOL'
  city: string
  wantsOffers: boolean
  nights: number
  // Tarifa editable al momento del check-in (root/reception). Si difiere
  // de la tarifa del tipo de habitación, la justificación es OBLIGATORIA
  // — se valida en la RPC (walk_in_check_in en
  // 20260717000000_walkin_editable_rate.sql), no solo acá.
  rateBs?: number | null
  rateReason?: string | null
  // Perfil de viaje del titular (registro turístico).
  originCity?: string
  travelPurpose?: string
  occupation?: string
  transportMeans?: string
  // Acompañantes: perfil completo de los demás huéspedes de la habitación.
  companions?: CompanionGuest[]
  // Agencia/empresa (texto libre + categoría). Ver CheckInProfile en
  // arrivals.ts para la misma nota sobre por qué vive en la reserva.
  agencyName?: string
  channelCode?: string
}

// Check-in de walk-in: llama a la función atómica de PostgreSQL, que
// registra al titular y a los acompañantes. Devuelve un aviso de
// "descuento pendiente" (o null) si la tarifa pedida superó el 20% y quien
// hizo el check-in no es reception_admin — el check-in igual se completa,
// facturado a precio de lista mientras tanto (ver
// 20260722020000_discount_approval_workflow.sql).
// Resultado del walk-in. Devuelve el `reservationId` que creó la RPC
// —antes se descartaba— porque el cobro opcional lo necesita para
// encadenar record_anticipo. `discountMessage` es el aviso de "descuento
// pendiente" de siempre (null si no aplica).
export interface WalkInOutcome {
  reservationId: string
  discountMessage: string | null
}

export async function walkInCheckIn(data: WalkInData): Promise<WalkInOutcome> {
  const { data: reservationId, error } = await supabase.rpc('walk_in_check_in_with_guests', {
    p_room_id: data.roomId,
    p_room_type_id: data.roomTypeId,
    p_first_name: data.firstName,
    p_last_name: data.lastName,
    p_document: data.document,
    p_email: data.email,
    p_birth_date: data.birthDate || null,
    p_country_code: data.countryCode,
    p_city: data.city,
    p_wants_offers: data.wantsOffers,
    p_nights: data.nights,
    p_rate_bs: data.rateBs ?? null,
    p_rate_reason: data.rateReason ?? null,
    p_origin_city: data.originCity ?? '',
    p_travel_purpose: data.travelPurpose ?? '',
    p_occupation: data.occupation ?? '',
    p_transport_means: data.transportMeans ?? '',
    p_companions: companionsToPayload(data.companions ?? []),
    p_agency_name: data.agencyName ?? null,
    p_channel_code: data.channelCode ?? null,
  })
  if (error) throw new Error(error.message)
  const id = reservationId as string
  if (!data.rateBs) return { reservationId: id, discountMessage: null }
  const pending = await fetchPendingForReservation(id)
  return {
    reservationId: id,
    discountMessage: pending ? pendingDiscountMessage(pending.computedDiscountPct) : null,
  }
}

// Resultado del walk-in + cobro. Extiende WalkInOutcome con el desenlace
// del cobro, que es INDEPENDIENTE del check-in (ver abajo).
export interface WalkInPaymentOutcome extends WalkInOutcome {
  paymentRecorded: boolean
  paymentError: string | null
}

// Walk-in + cobro opcional. Gemela de checkInWithOptionalPayment
// (arrivals.ts): mismo contrato, misma decisión de negocio, para que los
// dos puntos de entrada de check-in se comporten igual.
//
// Si `payment` es null, solo corre el walk-in. Si el walk-in falla, esta
// función rechaza y NO se cobra: no tiene sentido cobrarle a un huésped
// que no quedó in-house. Si el walk-in sale bien pero el cobro falla por
// cualquier motivo (típicamente caja cerrada), el error se atrapa acá:
// el check-in NO se revierte y quien llama recibe `paymentError` para
// mostrar un aviso no bloqueante.
export async function walkInWithOptionalPayment(
  data: WalkInData,
  payment: CheckInPaymentInput | null,
): Promise<WalkInPaymentOutcome> {
  const outcome = await walkInCheckIn(data)

  if (!payment) {
    return { ...outcome, paymentRecorded: false, paymentError: null }
  }

  try {
    await recordAnticipo({
      reservationId: outcome.reservationId,
      amountBs: payment.amountBs,
      paymentMethod: payment.paymentMethod,
      notes: payment.notes,
      proof: payment.proof,
      mixed: payment.mixed,
    })
    return { ...outcome, paymentRecorded: true, paymentError: null }
  } catch (e) {
    return { ...outcome, paymentRecorded: false, paymentError: (e as Error).message }
  }
}

export interface CheckOutReceipt {
  receipt: File | null
  paymentReference: string | null
}

// Desglose del pago mixto, ya resuelto a números. null si no es MIXTO.
export interface MixedSplit {
  cashBs: number
  nonCashBs: number
  nonCashMethod: string
}

// Check-out: sube el comprobante (si hay imagen) al bucket privado
// 'receipts' reusando la convención exacta de cash.ts (ruta plana
// `${año}/${uuid}.${ext}`, mismo bucket) y devuelve el total a cobrar (Bs).
export async function checkOutRoom(
  roomId: string,
  paymentMethod: string,
  receipt: CheckOutReceipt = { receipt: null, paymentReference: null },
  receivableAccountId: string | null = null,
  mixed: MixedSplit | null = null,
): Promise<number> {
  const { data, error } = await supabase.rpc('check_out_room', {
    p_room_id: roomId,
    p_payment_method: paymentMethod,
    p_receipt_path: await uploadReceipt(receipt.receipt),
    p_payment_reference: receipt.paymentReference,
    p_receivable_account_id: receivableAccountId,
    p_cash_bs: mixed?.cashBs ?? null,
    p_non_cash_bs: mixed?.nonCashBs ?? null,
    p_non_cash_method: mixed?.nonCashMethod ?? null,
  })
  if (error) throw new Error(error.message)
  return Number(data)
}

// Tarifa editable en check-in / carga de reserva. La justificación es
// OBLIGATORIA: se valida acá (fail-fast, antes de golpear la RPC) y de
// nuevo en la RPC (que es la que realmente hace cumplir la regla — ver
// override_reservation_rate en 20260716030000_rate_overrides.sql).
// Devuelve un aviso de "descuento pendiente" (o null) — ver walkInCheckIn.
export async function overrideReservationRate(
  reservationId: string,
  newRateBs: number,
  reason: string,
): Promise<string | null> {
  const trimmedReason = reason.trim()
  if (!trimmedReason) {
    throw new Error('La justificación es obligatoria')
  }
  if (!(newRateBs > 0)) {
    throw new Error('La tarifa debe ser un monto positivo')
  }
  const { error } = await supabase.rpc('override_reservation_rate', {
    p_reservation_id: reservationId,
    p_new_rate: newRateBs,
    p_reason: trimmedReason,
  })
  if (error) throw new Error(error.message)
  const pending = await fetchPendingForReservation(reservationId)
  return pending ? pendingDiscountMessage(pending.computedDiscountPct) : null
}

// Cambio simple de estado operativo (limpiar / mantenimiento).
export async function setRoomStatus(
  roomId: string,
  status: RoomOperationalStatus,
): Promise<void> {
  const { error } = await supabase
    .from('rooms')
    .update({ operational_status: status })
    .eq('id', roomId)
  if (error) throw new Error(error.message)
}
