import { supabase } from './supabase'
import type { GuestProfileMatch } from '../domain/guests/guestProfile'

interface GuestLookupRow {
  person_id: string
  first_name: string
  last_name: string
  email: string | null
  birth_date: string | null
  country_code: string | null
  city: string | null
  occupation: string | null
  wants_offers: boolean
}

/**
 * Busca un huésped ya registrado por documento / pasaporte.
 *
 * Devuelve null si no existe: que no esté no es un error, es el caso
 * normal de un huésped nuevo.
 */
export async function lookupGuestByDocument(
  document: string,
): Promise<GuestProfileMatch | null> {
  const doc = document.trim()
  if (!doc) return null

  const { data, error } = await supabase.rpc('lookup_guest_by_document', {
    p_document: doc,
  })
  if (error) throw new Error(error.message)

  const rows = (data ?? []) as unknown as GuestLookupRow[]
  const r = rows[0]
  if (!r) return null

  return {
    personId: r.person_id,
    firstName: r.first_name,
    lastName: r.last_name,
    email: r.email,
    birthDate: r.birth_date,
    countryCode: r.country_code,
    city: r.city,
    occupation: r.occupation,
    wantsOffers: Boolean(r.wants_offers),
  }
}
