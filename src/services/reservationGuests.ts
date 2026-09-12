import { supabase } from './supabase'
import type { PreloadedOccupant } from '../domain/reservations/holderSelection'

interface ReservationGuestRow {
  role: 'holder' | 'companion'
  confirmed_at: string | null
  people: {
    id: string
    first_name: string
    last_name: string
    email: string | null
    birth_date: string | null
    guests:
      | {
          passport_number: string | null
          country_code: string | null
          city: string | null
          origin_city: string | null
          travel_purpose: string | null
          occupation: string | null
          transport_means: string | null
        }[]
      | null
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
    .select(
      'role, confirmed_at, people:person_id(id, first_name, last_name, email, birth_date, guests(passport_number, country_code, city, origin_city, travel_purpose, occupation, transport_means))',
    )
    .eq('reservation_id', reservationId)
  if (error) throw new Error(error.message)

  return (data as unknown as ReservationGuestRow[]).map((r) => {
    const guest = r.people.guests?.[0]
    return {
      personId: r.people.id,
      firstName: r.people.first_name,
      lastName: r.people.last_name,
      document: guest?.passport_number ?? null,
      email: r.people.email,
      role: r.role,
      confirmedAt: r.confirmed_at,
      birthDate: r.people.birth_date,
      countryCode: guest?.country_code ?? null,
      city: guest?.city ?? null,
      originCity: guest?.origin_city ?? null,
      travelPurpose: guest?.travel_purpose ?? null,
      occupation: guest?.occupation ?? null,
      transportMeans: guest?.transport_means ?? null,
    }
  })
}
