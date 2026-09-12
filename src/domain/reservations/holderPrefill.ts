// Qué valores debe traer el formulario de check-in cuando el titular de la
// habitación YA es conocido (guest_id resuelto al reservar, o recién elegido
// de la lista de ocupantes precargados). Check-in = CONFIRMAR datos ya
// guardados, no volver a pedirlos en blanco (bug: reserva bulk con
// documento cargado llegaba al check-in con el campo Documento vacío,
// porque el prellenado solo corría cuando se ELEGÍA titular de la lista
// ámbar, y esa lista no aparece si el titular ya viene resuelto). Esta
// lógica es PURA: separa "qué ocupante es el titular a confirmar" de la UI.

import type { PreloadedOccupant } from './holderSelection'
import type { HolderSelection } from './holderSelection'

export interface HolderPrefillFields {
  document: string
  birthDate: string
  countryCode: string
  city: string
  originCity: string
  travelPurpose: string
  occupation: string
  transportMeans: string
}

export const EMPTY_HOLDER_PREFILL: HolderPrefillFields = {
  document: '',
  birthDate: '',
  countryCode: '',
  city: '',
  originCity: '',
  travelPurpose: '',
  occupation: '',
  transportMeans: '',
}

// El ocupante precargado a confirmar como titular:
// - si la reserva ya llegó con titular (needsHolder=false), es la fila con
//   role==='holder' (guest_id ya apunta a esa persona desde que se reservó).
// - si la reserva llegó sin titular y recepción eligió uno de la lista
//   ámbar, es ese ocupante elegido (holderSelection.kind === 'existing').
// - si se está cargando un titular nuevo (kind 'new'/'none'), no hay nada
//   que confirmar: no hay ocupante precargado que le corresponda.
export function holderToPrefill(
  occupants: PreloadedOccupant[],
  needsHolder: boolean,
  selection: HolderSelection,
): PreloadedOccupant | undefined {
  if (!needsHolder) return occupants.find((o) => o.role === 'holder')
  if (selection.kind === 'existing') {
    return occupants.find((o) => o.personId === selection.personId)
  }
  return undefined
}

// Traduce el ocupante precargado a los valores del formulario. Todo lo que
// no esté cargado en la base queda en blanco (no se inventa nada), y sigue
// siendo editable — esto solo decide el valor INICIAL.
export function holderPrefillFields(
  holder: PreloadedOccupant | undefined,
): HolderPrefillFields {
  if (!holder) return EMPTY_HOLDER_PREFILL
  return {
    document: holder.document ?? '',
    birthDate: holder.birthDate ?? '',
    countryCode: holder.countryCode ?? '',
    city: holder.city ?? '',
    originCity: holder.originCity ?? '',
    travelPurpose: holder.travelPurpose ?? '',
    occupation: holder.occupation ?? '',
    transportMeans: holder.transportMeans ?? '',
  }
}
