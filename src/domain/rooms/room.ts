// Estado OPERATIVO de recepción (lo que pinta el tablero).
export type RoomOperationalStatus =
  | 'available' // limpia y libre, lista para vender
  | 'occupied' // hay un huésped hospedado
  | 'dirty' // el huésped salió; pendiente de limpieza
  | 'maintenance' // fuera de servicio

// Tipo de habitación (define precio y ocupación).
export interface RoomType {
  id: string
  name: string
  basePriceBs: number
  maxOccupancy: number
}

// Habitación física del hotel.
export interface Room {
  id: string
  roomNumber: string
  floor: number
  zone: string | null // patio (Primer/Segundo/Tercer Patio)
  operationalStatus: RoomOperationalStatus
  defaultType: RoomType | null // tipo mostrado por defecto
  typeOptions: RoomType[] // tipos vendibles (las duales tienen 2)
}

// ¿Es una habitación dual (se puede vender como más de un tipo)?
export function isDualRoom(room: Room): boolean {
  return room.typeOptions.length > 1
}
