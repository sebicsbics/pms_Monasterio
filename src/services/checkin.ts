import { supabase } from './supabase'
import type { RoomOperationalStatus } from '../domain/rooms/room'
import { fetchPendingForReservation } from './rateDiscountRequestsService'
import { companionsToPayload, type CompanionGuest } from './arrivals'

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
}

// Check-in de walk-in: llama a la función atómica de PostgreSQL, que
// registra al titular y a los acompañantes. Devuelve un aviso de
// "descuento pendiente" (o null) si la tarifa pedida superó el 20% y quien
// hizo el check-in no es reception_admin — el check-in igual se completa,
// facturado a precio de lista mientras tanto (ver
// 20260722020000_discount_approval_workflow.sql).
export async function walkInCheckIn(data: WalkInData): Promise<string | null> {
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
  })
  if (error) throw new Error(error.message)
  if (!data.rateBs) return null
  const pending = await fetchPendingForReservation(reservationId as string)
  return pending ? pendingDiscountMessage(pending.computedDiscountPct) : null
}

export interface CheckOutReceipt {
  receipt: File | null
  paymentReference: string | null
}

// Check-out: sube el comprobante (si hay imagen) al bucket privado
// 'receipts' reusando la convención exacta de cash.ts (ruta plana
// `${año}/${uuid}.${ext}`, mismo bucket) y devuelve el total a cobrar (Bs).
export async function checkOutRoom(
  roomId: string,
  paymentMethod: string,
  receipt: CheckOutReceipt = { receipt: null, paymentReference: null },
): Promise<number> {
  let receiptPath: string | null = null
  if (receipt.receipt) {
    const ext = (receipt.receipt.name.split('.').pop() ?? 'jpg').toLowerCase()
    const path = `${new Date().getFullYear()}/${crypto.randomUUID()}.${ext}`
    const { error: upErr } = await supabase.storage
      .from('receipts')
      .upload(path, receipt.receipt, { contentType: receipt.receipt.type })
    if (upErr) throw new Error(upErr.message)
    receiptPath = path
  }
  const { data, error } = await supabase.rpc('check_out_room', {
    p_room_id: roomId,
    p_payment_method: paymentMethod,
    p_receipt_path: receiptPath,
    p_payment_reference: receipt.paymentReference,
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
