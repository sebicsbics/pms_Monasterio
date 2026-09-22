// Data de referencia: categorías de canal para la casilla de
// agencia/empresa del check-in. Los códigos son los mismos que
// reservation_channels.code en la base (FK), así el desplegable nunca
// puede mandar un valor que la base rechace.
export interface Channel {
  code: string
  label: string
}

export const CHANNELS: Channel[] = [
  { code: 'DIRECTO', label: 'Directo' },
  { code: 'OTA', label: 'OTA' },
  { code: 'AGENCIA', label: 'Agencia' },
  { code: 'EMPRESA', label: 'Empresa' },
  { code: 'REFERIDO', label: 'Referido' },
  { code: 'EVENTO', label: 'Evento' },
]

export const DEFAULT_CHANNEL_CODE = 'DIRECTO'

// Canal sugerido cuando el check-in viene de una reserva institucional
// con cuenta por cobrar ya cargada (fix/institutional-ui-coherence):
// 'persona' no tiene un canal propio en esta lista, así que se deja el
// default en vez de inventar una categoría que la cuenta no dice.
export function channelCodeForAccountKind(kind: 'empresa' | 'agencia' | 'persona'): string {
  if (kind === 'empresa') return 'EMPRESA'
  if (kind === 'agencia') return 'AGENCIA'
  return DEFAULT_CHANNEL_CODE
}
