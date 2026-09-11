// Traducción centralizada de errores de Postgres a mensajes de usuario.
// Hoy solo cubre el EXCLUDE de reservation_guests_no_overlap (SQLSTATE
// 23P01, exclusion_violation) que Postgres reporta con su texto crudo
// ("conflicting key value violates exclusion constraint..."). El resto de
// los errores (validaciones de negocio con RAISE EXCEPTION) ya vienen en
// español desde la RPC — se devuelven sin tocar.
//
// Ver 20260911040000_stay_overlap_constraint.sql (constraint) y change
// reservation-booker-vs-guest, PR4, 8/8.

interface PostgrestLikeError {
  code?: string | null
  message?: string
}

const OVERLAP_CONSTRAINT = 'reservation_guests_no_overlap'
const OVERLAP_MESSAGE =
  'Esta persona ya está alojada en otra habitación en esas fechas.'

export function toUserMessage(error: PostgrestLikeError): string {
  if (error.code === '23P01' && error.message?.includes(OVERLAP_CONSTRAINT)) {
    return OVERLAP_MESSAGE
  }
  return error.message ?? 'Error desconocido'
}
