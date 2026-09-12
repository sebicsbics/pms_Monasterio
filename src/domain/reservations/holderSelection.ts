// Decisión de "quién es el titular" al hacer check-in de una reserva sin
// titular resuelto (guest_id null — ver arrival.holderFirstName/LastName).
// Recepción elige entre un ocupante ya precargado (bulk/contacto-no-titular)
// o escribe un nombre nuevo. Esta lógica es PURA: separa la decisión de la
// llamada a la RPC (check_in_reservation_with_guests, p_holder_*).

export type HolderSelection =
  | { kind: 'existing'; personId: string }
  | { kind: 'new'; firstName: string; lastName: string }
  | { kind: 'none' }

export interface HolderRpcParams {
  holderPersonId?: string
  holderFirstName?: string
  holderLastName?: string
}

// needsHolder = true cuando la reserva llega al check-in sin titular
// (arrival.holderFirstName/LastName null). Si ya tiene titular, no hay
// nada que resolver: la selección de la UI se ignora.
export function holderRpcParams(
  needsHolder: boolean,
  selection: HolderSelection,
): HolderRpcParams {
  if (!needsHolder) return {}
  if (selection.kind === 'existing') return { holderPersonId: selection.personId }
  if (selection.kind === 'new') {
    const firstName = selection.firstName.trim()
    const lastName = selection.lastName.trim()
    if (!firstName || !lastName) return {}
    return { holderFirstName: firstName, holderLastName: lastName }
  }
  return {}
}

export function isHolderSelectionComplete(
  needsHolder: boolean,
  selection: HolderSelection,
): boolean {
  if (!needsHolder) return true
  if (selection.kind === 'existing') return true
  if (selection.kind === 'new') {
    return selection.firstName.trim() !== '' && selection.lastName.trim() !== ''
  }
  return false
}

// Forma de la UI de check-in cuando falta titular. Si no hay ocupantes
// precargados, la única opción real es cargar un nombre nuevo — no tiene
// sentido forzar un radio "Nuevo huésped" para llegar ahí (bug reportado en
// el smoke test manual: caja ámbar con un solo radio, imposible destildar).
// Si hay ocupantes, la elección es real y se muestra la lista.
export type HolderUiShape = 'direct-new' | 'choose-occupant'

export function holderUiShape(occupants: PreloadedOccupant[]): HolderUiShape {
  return occupants.length === 0 ? 'direct-new' : 'choose-occupant'
}

// Selección inicial acorde a la forma de la UI: sin ocupantes, arrancamos
// directo en "new" (vacío) para que los campos de nombre aparezcan sin
// click previo; con ocupantes, arrancamos en "none" para no asumir por
// recepción quién es el titular.
export function initialHolderSelection(occupants: PreloadedOccupant[]): HolderSelection {
  return occupants.length === 0 ? { kind: 'new', firstName: '', lastName: '' } : { kind: 'none' }
}

export interface PreloadedOccupant {
  personId: string
  firstName: string
  lastName: string
  document: string | null
  email: string | null
  role: 'holder' | 'companion'
  confirmedAt: string | null
}

export interface CompanionDraft {
  firstName: string
  lastName: string
  document: string
}

// Ocupantes precargados que NO se eligieron como titular pasan a la lista
// de acompañantes a confirmar. Check-in = CONFIRMAR datos ya cargados: si
// se cargó documento al reservar (bulk/individual), viaja acá para que el
// formulario de check-in no lo pida de nuevo vacío (issue 5 del smoke test
// manual, change reservation-booker-vs-guest PR7).
export function companionsFromOccupants(
  occupants: PreloadedOccupant[],
  excludeHolderPersonId: string | null,
): CompanionDraft[] {
  return occupants
    .filter((o) => o.personId !== excludeHolderPersonId)
    .map((o) => ({ firstName: o.firstName, lastName: o.lastName, document: o.document ?? '' }))
}
