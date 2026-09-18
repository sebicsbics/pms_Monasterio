import { supabase } from './supabase'
import type { PreloadedOccupant } from '../domain/reservations/holderSelection'

interface ReservationGuestRow {
  role: 'holder' | 'companion'
  confirmed_at: string | null
  // Campos de viaje: datos de ESTA estadía, viven como columnas propias de
  // reservation_guests (Slice 8b, feat/booking-20-travel-fields-writesites),
  // no del embed guests de abajo — ese es por PERSONA (histórico) y leerlos
  // de ahí haría que una nueva estadía mostrara los datos de una anterior
  // (R8.4).
  origin_city: string | null
  travel_purpose: string | null
  transport_means: string | null
  people: {
    id: string
    first_name: string
    last_name: string
    email: string | null
    birth_date: string | null
    // PostgREST devuelve este embed como OBJETO, no como lista: la relación
    // people→guests es 1:1 (guests.person_id es FK y PK a la vez). Se acepta
    // la lista igual por robustez ante un cambio de forma del servidor.
    guests: GuestEmbed | GuestEmbed[] | null
  }
}

interface GuestEmbed {
  passport_number: string | null
  country_code: string | null
  city: string | null
  occupation: string | null
}

function firstGuest(embed: GuestEmbed | GuestEmbed[] | null): GuestEmbed | undefined {
  if (!embed) return undefined
  return Array.isArray(embed) ? embed[0] : embed
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
      'role, confirmed_at, origin_city, travel_purpose, transport_means, people:person_id(id, first_name, last_name, email, birth_date, guests(passport_number, country_code, city, occupation))',
    )
    .eq('reservation_id', reservationId)
  if (error) throw new Error(error.message)

  return (data as unknown as ReservationGuestRow[]).map((r) => {
    const guest = firstGuest(r.people.guests)
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
      originCity: r.origin_city,
      travelPurpose: r.travel_purpose,
      occupation: guest?.occupation ?? null,
      transportMeans: r.transport_means,
    }
  })
}
