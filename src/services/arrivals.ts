import { supabase } from './supabase'
import type { Arrival } from '../domain/stays/arrival'
import { recordAnticipo } from './anticipos'
import type { PaymentProof } from '../domain/payments/paymentProof'
import { toUserMessage } from './dbErrors'

interface ArrivalRow {
  reservation_id: string
  room_id: string
  room_number: string
  room_type: string
  first_name: string
  last_name: string
  phone: string | null
  email: string | null
  check_in_date: string
  check_out_date: string
  num_guests: number | null
  max_occupancy: number | null
  method: string
  anticipo_total_bs: number | string | null
  holder_first_name: string | null
  holder_last_name: string | null
}

// Llegadas (reservas confirmadas sin check-in) dentro de un rango de
// fechas de entrada [from, to]. `from` en null = sin cota inferior, así
// las llegadas vencidas (deberían haber llegado y no lo hicieron) siguen
// apareciendo en la vista de "hoy".
export async function fetchArrivals(
  from: string | null,
  to: string,
): Promise<Arrival[]> {
  const { data, error } = await supabase.rpc('arrivals', { p_from: from, p_to: to })
  if (error) throw new Error(error.message)

  return (data as ArrivalRow[]).map((r) => ({
    reservationId: r.reservation_id,
    roomId: r.room_id,
    roomNumber: r.room_number,
    roomType: r.room_type,
    firstName: r.first_name,
    lastName: r.last_name,
    phone: r.phone,
    email: r.email,
    checkInDate: r.check_in_date,
    checkOutDate: r.check_out_date,
    numGuests: r.num_guests,
    maxOccupancy: r.max_occupancy,
    method: r.method,
    anticipoTotalBs: Number(r.anticipo_total_bs ?? 0),
    holderFirstName: r.holder_first_name,
    holderLastName: r.holder_last_name,
  }))
}

export interface CheckInProfile {
  document: string
  birthDate: string
  countryCode: string
  city: string
  wantsOffers: boolean
  // Correo del titular para las promociones (checkbox wantsOffers). Se
  // omite del payload cuando no aplica: ver
  // domain/reservations/checkinEmail.ts para cuándo es obligatorio/válido.
  // Vacío/undefined NO borra un correo ya cargado (la RPC hace
  // NULLIF + coalesce).
  email?: string
  // Perfil de viaje (registro turístico).
  originCity: string
  travelPurpose: string
  occupation: string
  transportMeans: string
  // Agencia/empresa por la que llegó (texto libre + categoría). Ambos
  // opcionales — se guardan en la reserva, no en el huésped, porque la
  // misma persona puede venir por canales distintos en cada viaje.
  agencyName?: string
  channelCode?: string
  // Titular a resolver cuando la reserva llega al check-in sin uno
  // (guest_id null — ver Arrival.holderFirstName/LastName). Se omiten del
  // payload cuando no aplican, para que el flujo de contacto-titular de
  // siempre mande exactamente lo mismo que manda hoy. Ver
  // src/domain/reservations/holderSelection.ts para la decisión de cuál
  // usar.
  holderPersonId?: string
  holderFirstName?: string
  holderLastName?: string
  // Motivo obligatorio SOLO cuando la ocupación resultante supera
  // arrival.maxOccupancy — ver domain/reservations/occupancyReason.ts. Se
  // omite del payload cuando no aplica (dentro del máximo).
  occupancyReason?: string
}

// Perfil de un acompañante (huésped no titular de la habitación). Si es
// menor de 14 (isMinor) no se le piden los datos de adulto.
export interface CompanionGuest {
  firstName: string
  lastName: string
  isMinor: boolean
  document: string
  birthDate: string
  countryCode: string
  city: string
  originCity: string
  travelPurpose: string
  occupation: string
  transportMeans: string
}

// Convierte los acompañantes al shape jsonb que esperan las RPC de
// check-in (Llegadas y walk-in). Solo se mandan los que tengan al menos
// nombre y apellido.
export function companionsToPayload(companions: CompanionGuest[]) {
  return companions
    .filter((g) => g.firstName.trim() !== '' && g.lastName.trim() !== '')
    .map((g) => ({
      first_name: g.firstName.trim(),
      last_name: g.lastName.trim(),
      is_minor: g.isMinor,
      birth_date: g.birthDate || '',
      // Los menores de 14 no cargan datos de adulto: se mandan en blanco.
      document: g.isMinor ? '' : g.document.trim(),
      country_code: g.isMinor ? '' : g.countryCode.trim().toUpperCase(),
      city: g.isMinor ? '' : g.city.trim(),
      origin_city: g.isMinor ? '' : g.originCity.trim(),
      travel_purpose: g.isMinor ? '' : g.travelPurpose.trim(),
      occupation: g.isMinor ? '' : g.occupation.trim(),
      transport_means: g.isMinor ? '' : g.transportMeans.trim(),
    }))
}

// Check-in desde una reserva: completa el perfil del titular, registra a
// los acompañantes (perfil completo cada uno) y ocupa la habitación.
export async function checkInFromReservation(
  reservationId: string,
  profile: CheckInProfile,
  companions: CompanionGuest[] = [],
): Promise<void> {
  const { error } = await supabase.rpc('check_in_reservation_with_guests', {
    p_reservation_id: reservationId,
    p_document: profile.document,
    p_birth_date: profile.birthDate || null,
    p_country_code: profile.countryCode,
    p_city: profile.city,
    p_wants_offers: profile.wantsOffers,
    p_email: profile.email?.trim() || null,
    p_origin_city: profile.originCity,
    p_travel_purpose: profile.travelPurpose,
    p_occupation: profile.occupation,
    p_transport_means: profile.transportMeans,
    p_companions: companionsToPayload(companions),
    p_agency_name: profile.agencyName ?? null,
    p_channel_code: profile.channelCode ?? null,
    ...(profile.holderPersonId ? { p_holder_person_id: profile.holderPersonId } : {}),
    ...(profile.holderFirstName ? { p_holder_first_name: profile.holderFirstName } : {}),
    ...(profile.holderLastName ? { p_holder_last_name: profile.holderLastName } : {}),
    ...(profile.occupancyReason ? { p_occupancy_reason: profile.occupancyReason } : {}),
  })
  if (error) throw new Error(toUserMessage(error))
}

// Cobro opcional al momento del check-in. NO es un concepto de dinero
// nuevo: es el mismo record_anticipo que usa RecordAnticipoView, invocado
// como un SEGUNDO llamado, secuencial, después del check-in.
export interface CheckInPaymentInput {
  amountBs: number
  paymentMethod: string
  notes: string | null
  proof?: PaymentProof
  mixed?: { cashBs: number; nonCashBs: number; nonCashMethod: string } | null
}

export interface CheckInPaymentOutcome {
  checkedIn: true
  paymentRecorded: boolean
  paymentError: string | null
}

// Check-in + cobro opcional, en ese orden y sin atomicidad entre los dos
// pasos (decisión de negocio: la plata no entra sin un turno de caja que
// la respalde, pero el check-in ya está hecho y NO se revierte por eso).
//
// Si `payment` es null (recepción no cargó monto), solo corre el check-in
// — record_anticipo nunca se llama (R2.2). Si el check-in falla, esta
// función rechaza y record_anticipo tampoco se llama: no tiene sentido
// cobrar una reserva que no quedó in-house. Si el check-in tiene éxito
// pero el cobro falla por CUALQUIER motivo (caja cerrada, validación,
// red), el error se atrapa acá: quien llama nunca ve un throw por el
// cobro, solo `paymentError` para mostrar un aviso no bloqueante.
export async function checkInWithOptionalPayment(
  reservationId: string,
  profile: CheckInProfile,
  companions: CompanionGuest[],
  payment: CheckInPaymentInput | null,
): Promise<CheckInPaymentOutcome> {
  await checkInFromReservation(reservationId, profile, companions)

  if (!payment) {
    return { checkedIn: true, paymentRecorded: false, paymentError: null }
  }

  try {
    await recordAnticipo({
      reservationId,
      amountBs: payment.amountBs,
      paymentMethod: payment.paymentMethod,
      notes: payment.notes,
      proof: payment.proof,
      mixed: payment.mixed,
    })
    return { checkedIn: true, paymentRecorded: true, paymentError: null }
  } catch (e) {
    return { checkedIn: true, paymentRecorded: false, paymentError: (e as Error).message }
  }
}
