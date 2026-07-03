import type { RoomType } from '../rooms/room'

// Una habitación disponible para un rango de fechas, con sus tipos aptos
// según la cantidad de personas solicitada.
export interface AvailableRoom {
  roomId: string
  roomNumber: string
  floor: number
  zone: string | null
  suitableTypes: RoomType[]
}

// Canales por los que puede llegar una reserva.
export type ReservationMethod = 'web' | 'email' | 'phone' | 'whatsapp' | 'walk-in'
