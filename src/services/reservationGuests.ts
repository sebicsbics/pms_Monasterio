import { supabase } from './supabase'
import type { PreloadedOccupant } from '../domain/reservations/holderSelection'

interface ReservationGuestRow {
  role: 'holder' | 'companion'
  confirmed_at: string | null
  people: {
    id: string
    first_name: string
    last_name: string
    guests: { passport_number: string | null }[] | null
  }
}

// Ocupantes precargados de una reserva confirmada (aún sin check-in):
// titular (si ya se conoce) y acompañantes cargados al reservar, cada uno
// con su propia fila en reservation_guests (confirmed_at null = pendiente
// de confirmar documentos en el check-in). Alimenta el selector de titular
// del check-in cuando la reserva llega sin guest_id.
export async function fetchPreloadedOccupants(
  reservationId: string,
): Promise<PreloadedOccupant[]> {
  const { data, error } = await supabase
    .from('reservation_guests')
    .select('role, confirmed_at, people:person_id(id, first_name, last_name, guests(passport_number))')
    .eq('reservation_id', reservationId)
  if (error) throw new Error(error.message)

  return (data as unknown as ReservationGuestRow[]).map((r) => ({
    personId: r.people.id,
    firstName: r.people.first_name,
    lastName: r.people.last_name,
    document: r.people.guests?.[0]?.passport_number ?? null,
    role: r.role,
    confirmedAt: r.confirmed_at,
  }))
}
