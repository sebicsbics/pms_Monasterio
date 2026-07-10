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
  })
  if (error) throw new Error(error.message)
}

// Check-out: devuelve el total a cobrar (Bs).
export async function checkOutRoom(
  roomId: string,
  paymentMethod: string,
): Promise<number> {
  const { data, error } = await supabase.rpc('check_out_room', {
    p_room_id: roomId,
    p_payment_method: paymentMethod,
  })
  if (error) throw new Error(error.message)
  return Number(data)
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
