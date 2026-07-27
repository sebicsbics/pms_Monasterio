import { supabase } from './supabase'
import type { Arrival } from '../domain/stays/arrival'

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
  method: string
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
    method: r.method,
  }))
}

export interface CheckInProfile {
  document: string
  birthDate: string
  countryCode: string
  city: string
  wantsOffers: boolean
}

// Perfil completo de un acompañante (huésped no titular de la habitación).
export interface CompanionGuest {
  firstName: string
  lastName: string
  document: string
  birthDate: string
  countryCode: string
  city: string
}

// Convierte un acompañante al shape jsonb que espera la RPC. Solo se
// mandan los que tengan al menos nombre y apellido.
function toCompanionPayload(g: CompanionGuest) {
  return {
    first_name: g.firstName.trim(),
    last_name: g.lastName.trim(),
    document: g.document.trim(),
    birth_date: g.birthDate || '',
    country_code: g.countryCode.trim().toUpperCase(),
    city: g.city.trim(),
  }
}

// Check-in desde una reserva: completa el perfil del titular, registra a
// los acompañantes (perfil completo cada uno) y ocupa la habitación.
export async function checkInFromReservation(
  reservationId: string,
  profile: CheckInProfile,
  companions: CompanionGuest[] = [],
): Promise<void> {
  const validCompanions = companions.filter(
    (g) => g.firstName.trim() !== '' && g.lastName.trim() !== '',
  )
  const { error } = await supabase.rpc('check_in_reservation_with_guests', {
    p_reservation_id: reservationId,
    p_document: profile.document,
    p_birth_date: profile.birthDate || null,
    p_country_code: profile.countryCode,
    p_city: profile.city,
    p_wants_offers: profile.wantsOffers,
    p_companions: validCompanions.map(toCompanionPayload),
  })
  if (error) throw new Error(error.message)
}
