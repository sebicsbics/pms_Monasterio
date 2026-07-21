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

// Vocabulario operacional de reservation_method. Única fuente de verdad para
// el dropdown de la UI y el CHECK constraint en la base de datos (ver
// supabase/migrations/20260718000003_reservation_method_check.sql). No
// confundir con reservation_channels (taxonomía de canales para analítica
// ETL sobre historical_stays) — son conceptos distintos y deliberadamente
// no están vinculados.
export const RESERVATION_METHODS: readonly ReservationMethod[] = [
  'phone',
  'whatsapp',
  'email',
  'web',
  'walk-in',
]
