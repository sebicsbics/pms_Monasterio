// La ocupación precargada (huéspedes cargados por habitación en el alta en
// bulk) no tiene por qué coincidir con num_guests (la estimación con la que
// se buscó disponibilidad) — la justificación real de ocupación llega en
// una etapa posterior (PR4). Acá solo avisamos, nunca bloqueamos.
export function occupantCountWarning(
  numGuests: number,
  occupantsCount: number,
): string | null {
  if (occupantsCount === 0) return null
  if (occupantsCount === numGuests) return null
  return occupantsCount < numGuests
    ? `Cargaste ${occupantsCount} huésped(es) pero la habitación estima ${numGuests}.`
    : `Cargaste ${occupantsCount} huésped(es), más que los ${numGuests} estimados para la habitación.`
}
