import type { RoomType } from '../rooms/room'

// Una misma habitación física puede aparecer en room_type_options con
// VARIAS fichas de tipo/precio (ej. habitación 7: "Simple Estándar" 1px
// a 350 Bs y "Matrimonial" 2px a 480 Bs — ver DEFECT 2,
// fix/bulk-headcount-room-type-and-errors). Elegir siempre la primera
// (la más barata, que es como vienen ordenadas desde available_rooms)
// sin mirar la cantidad de huéspedes hace que una reserva de 2 personas
// dispare, incorrectamente, el aviso de sobre-ocupación de un tipo que
// ni siquiera se está usando.

// Tipos que efectivamente alcanzan para esa cantidad de huéspedes — para
// ofrecerle al usuario un selector cuando hay más de uno.
export function fittingRoomTypes(suitableTypes: RoomType[], guests: number): RoomType[] {
  return suitableTypes.filter((t) => t.maxOccupancy >= guests)
}

// Tipo por defecto: el más barato que alcanza. Si ninguno alcanza (sobre-
// ocupación real, ej. 3 personas en una habitación cuyas fichas topean en
// 2), se usa el de mayor capacidad como base — igual va a pedir motivo de
// excepción, el override sigue vigente.
export function selectDefaultRoomType(
  suitableTypes: RoomType[],
  guests: number,
): RoomType | null {
  if (suitableTypes.length === 0) return null
  const fitting = fittingRoomTypes(suitableTypes, guests)
  if (fitting.length > 0) {
    // Ya vienen ordenados por precio ascendente (available_rooms): el
    // primero que alcanza es el más barato que igual sirve.
    return fitting[0]
  }
  return suitableTypes.reduce((best, t) => (t.maxOccupancy > best.maxOccupancy ? t : best))
}
