import { supabase } from './supabase'
import type { InHouseStay } from '../domain/stays/in-house'
import type { BreakfastGuestRow } from '../domain/stays/breakfast'

interface InHouseRow {
  reservation_id: string
  room_id: string
  room_number: string
  floor: number
  zone: string | null
  room_type: string
  first_name: string
  last_name: string
  email: string | null
  country_code: string | null
  city: string | null
  check_in_date: string
  check_out_date: string
  room_total_bs: number
  guest_count: number
}

// Lista de huéspedes actualmente hospedados (lee la vista in_house).
export async function fetchInHouse(): Promise<InHouseStay[]> {
  const { data, error } = await supabase.from('in_house').select('*')
  if (error) throw new Error(error.message)

  return (data as unknown as InHouseRow[])
    .map((r) => ({
      reservationId: r.reservation_id,
      roomId: r.room_id,
      roomNumber: r.room_number,
      floor: r.floor,
      zone: r.zone,
      roomType: r.room_type,
      firstName: r.first_name,
      lastName: r.last_name,
      email: r.email,
      countryCode: r.country_code,
      city: r.city,
      checkInDate: r.check_in_date,
      checkOutDate: r.check_out_date,
      roomTotalBs: Number(r.room_total_bs),
      guestCount: Number(r.guest_count) || 1,
    }))
    .sort((a, b) => Number(a.roomNumber) - Number(b.roomNumber))
}

interface StayGuestCountryRow {
  reservation_id: string
  person_id: string
  first_name: string
  last_name: string
  is_holder: boolean
  country_code: string | null
}

// Todos los huéspedes hospedados (titular + acompañantes) con su
// nacionalidad, para armar la hoja de desayuno. La vista `stay_guests` ya
// filtra por estadías en curso, así que no hace falta acotar por reserva.
export async function fetchBreakfastGuests(): Promise<BreakfastGuestRow[]> {
  const { data, error } = await supabase
    .from('stay_guests')
    .select('reservation_id, person_id, first_name, last_name, is_holder, country_code')
  if (error) throw new Error(error.message)

  return (data as unknown as StayGuestCountryRow[]).map((r) => ({
    reservationId: r.reservation_id,
    personId: r.person_id,
    firstName: r.first_name,
    lastName: r.last_name,
    isHolder: r.is_holder,
    countryCode: r.country_code,
  }))
}
