// Ficha de un huésped YA registrado, tal como vuelve de la búsqueda por
// documento (lookup_guest_by_document).
//
// A propósito NO trae los campos circunstanciales del viaje —procedencia,
// motivo, transporte—: cambian en cada estadía y precargarlos con los de
// la visita anterior sería registrar datos turísticos falsos.
export interface GuestProfileMatch {
  personId: string
  firstName: string
  lastName: string
  email: string | null
  birthDate: string | null
  countryCode: string | null
  city: string | null
  occupation: string | null
  wantsOffers: boolean
}

// Los campos que un formulario de huésped puede autocompletar. Cada
// pantalla toma los que tiene (el check-in de Llegadas, por ejemplo, no
// edita el nombre: ese viene de la reserva).
export interface GuestPrefill {
  firstName: string
  lastName: string
  email: string
  birthDate: string
  countryCode: string
  city: string
  occupation: string
  wantsOffers: boolean
}

/**
 * Traduce la ficha encontrada a valores de formulario.
 *
 * Un campo vacío en la base se traduce a string vacío, NUNCA se inventa:
 * el recepcionista tiene que ver qué falta y completarlo. `birthDate` se
 * recorta a yyyy-mm-dd porque es lo único que acepta `<input type="date">`.
 */
export function guestPrefill(match: GuestProfileMatch): GuestPrefill {
  return {
    firstName: match.firstName ?? '',
    lastName: match.lastName ?? '',
    email: match.email ?? '',
    birthDate: match.birthDate ? match.birthDate.slice(0, 10) : '',
    countryCode: match.countryCode ?? '',
    city: match.city ?? '',
    occupation: match.occupation ?? '',
    wantsOffers: match.wantsOffers,
  }
}
