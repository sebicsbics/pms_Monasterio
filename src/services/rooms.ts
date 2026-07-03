import { supabase } from './supabase'
import type {
  Room,
  RoomType,
  RoomOperationalStatus,
} from '../domain/rooms/room'

// --- Formas crudas que devuelve Supabase (snake_case, anidado) ---
interface RoomTypeRow {
  id: string
  name: string
  base_price_bs: number
  max_occupancy: number
}

interface RoomRow {
  id: string
  room_number: string
  floor: number | null
  zone: string | null
  operational_status: RoomOperationalStatus
  default_type: RoomTypeRow | null
  options: { room_types: RoomTypeRow }[]
}

function toRoomType(r: RoomTypeRow): RoomType {
  return {
    id: r.id,
    name: r.name,
    basePriceBs: Number(r.base_price_bs),
    maxOccupancy: r.max_occupancy,
  }
}

// Trae todas las habitaciones con su tipo por defecto y sus tipos ofrecibles.
export async function fetchRooms(): Promise<Room[]> {
  const { data, error } = await supabase.from('rooms').select(`
      id, room_number, floor, zone, operational_status,
      default_type:room_types!rooms_room_type_id_fkey ( id, name, base_price_bs, max_occupancy ),
      options:room_type_options ( room_types ( id, name, base_price_bs, max_occupancy ) )
    `)

  if (error) {
    throw new Error(`No se pudieron cargar las habitaciones: ${error.message}`)
  }

  const rows = (data ?? []) as unknown as RoomRow[]

  return rows
    .map((row) => ({
      id: row.id,
      roomNumber: row.room_number,
      floor: row.floor ?? 0,
      zone: row.zone,
      operationalStatus: row.operational_status,
      defaultType: row.default_type ? toRoomType(row.default_type) : null,
      typeOptions: row.options.map((o) => toRoomType(o.room_types)),
    }))
    // Orden numérico por número de habitación (evita 10 antes que 2).
    .sort((a, b) => Number(a.roomNumber) - Number(b.roomNumber))
}
