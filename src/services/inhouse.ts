import { supabase } from './supabase'
import type { InHouseStay } from '../domain/stays/in-house'

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
