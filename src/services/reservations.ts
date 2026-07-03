import { supabase } from './supabase'
import type { AvailableRoom } from '../domain/reservations/availability'
import type { RoomType } from '../domain/rooms/room'

interface AvailableRoomRow {
  room_id: string
  room_number: string
  floor: number
  zone: string | null
  suitable_types: RoomType[] // jsonb ya en camelCase desde la función
}

// Busca habitaciones disponibles para el rango y cantidad de personas.
export async function searchAvailableRooms(
  checkIn: string,
  checkOut: string,
  pax: number,
): Promise<AvailableRoom[]> {
  const { data, error } = await supabase.rpc('available_rooms', {
    p_check_in: checkIn,
    p_check_out: checkOut,
    p_pax: pax,
  })
  if (error) throw new Error(error.message)

  return (data as AvailableRoomRow[]).map((r) => ({
    roomId: r.room_id,
    roomNumber: r.room_number,
    floor: r.floor,
    zone: r.zone,
    suitableTypes: r.suitable_types.map((t) => ({
      id: t.id,
      name: t.name,
      basePriceBs: Number(t.basePriceBs),
      maxOccupancy: t.maxOccupancy,
    })),
  }))
}

export interface ReservationInput {
  roomId: string
  roomTypeId: string
  firstName: string
  lastName: string
  phone: string
  email: string
  checkIn: string
  checkOut: string
  numGuests: number
  method: string
}

export async function createReservation(data: ReservationInput): Promise<void> {
  const { error } = await supabase.rpc('create_reservation', {
    p_room_id: data.roomId,
    p_room_type_id: data.roomTypeId,
    p_first_name: data.firstName,
    p_last_name: data.lastName,
    p_phone: data.phone,
    p_email: data.email,
    p_check_in: data.checkIn,
    p_check_out: data.checkOut,
    p_num_guests: data.numGuests,
    p_method: data.method,
  })
  if (error) throw new Error(error.message)
}
