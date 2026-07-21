import { supabase } from './supabase'
import type { RoomOperationalStatus } from '../domain/rooms/room'

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
}

// Check-in de walk-in: llama a la función atómica de PostgreSQL.
export async function walkInCheckIn(data: WalkInData): Promise<void> {
  const { error } = await supabase.rpc('walk_in_check_in', {
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
  })
  if (error) throw new Error(error.message)
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
export async function overrideReservationRate(
  reservationId: string,
  newRateBs: number,
  reason: string,
): Promise<void> {
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
