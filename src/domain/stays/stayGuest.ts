// Un huésped registrado en una estadía: el titular de la reserva o un
// acompañante. Es lo que se muestra sobre el folio en el tablero.
export interface StayGuest {
  personId: string
  firstName: string
  lastName: string
  isHolder: boolean
  isMinor: boolean
  document: string | null
}

export function guestFullName(g: StayGuest): string {
  return `${g.firstName} ${g.lastName}`.trim()
}
