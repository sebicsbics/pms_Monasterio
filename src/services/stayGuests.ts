import { supabase } from './supabase'
import type { StayGuest } from '../domain/stays/stayGuest'
import { companionsToPayload, type CompanionGuest } from './arrivals'

interface StayGuestRow {
  person_id: string
  first_name: string
  last_name: string
  is_holder: boolean
  is_minor: boolean
  document: string | null
}

// Todos los huéspedes de la habitación ocupada (titular primero).
export async function fetchStayGuests(roomId: string): Promise<StayGuest[]> {
  const { data, error } = await supabase
    .from('stay_guests')
    .select('person_id, first_name, last_name, is_holder, is_minor, document')
    .eq('room_id', roomId)
  if (error) throw new Error(error.message)

  return (data as unknown as StayGuestRow[])
    .map((r) => ({
      personId: r.person_id,
      firstName: r.first_name,
      lastName: r.last_name,
      isHolder: r.is_holder,
      isMinor: r.is_minor,
      document: r.document,
    }))
    .sort((a, b) => Number(b.isHolder) - Number(a.isHolder))
}

// Agrega huéspedes a una habitación YA ocupada (llegó la esposa dos días
// después). El incremento se cobra como una línea del folio — no toca la
// tarifa de la habitación. Devuelve la ocupación resultante.
export async function addGuestsToStay(
  roomId: string,
  companions: CompanionGuest[],
  extraChargeBs: number,
  chargeDescription: string,
): Promise<number> {
  const payload = companionsToPayload(companions)
  if (payload.length === 0) {
    throw new Error('Cada huésped requiere nombre y apellido')
  }
  const { data, error } = await supabase.rpc('add_guests_to_stay', {
    p_room_id: roomId,
    p_companions: payload,
    p_extra_charge_bs: extraChargeBs,
    p_charge_description: chargeDescription.trim() || null,
  })
  if (error) throw new Error(error.message)
  return Number(data)
}
