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

// Llegadas hasta la fecha dada (reservas confirmadas sin check-in).
export async function fetchArrivals(date: string): Promise<Arrival[]> {
  const { data, error } = await supabase.rpc('arrivals', { p_date: date })
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

// Check-in desde una reserva: completa el perfil y ocupa la habitación.
export async function checkInFromReservation(
  reservationId: string,
  profile: CheckInProfile,
): Promise<void> {
  const { error } = await supabase.rpc('check_in_reservation', {
    p_reservation_id: reservationId,
    p_document: profile.document,
    p_birth_date: profile.birthDate || null,
    p_country_code: profile.countryCode,
    p_city: profile.city,
    p_wants_offers: profile.wantsOffers,
  })
  if (error) throw new Error(error.message)
}
