// Decisión de "¿hace falta pedir un motivo?" cuando la ocupación resultante
// supera room_types.max_occupancy. Pura: separa la decisión de UI de la
// llamada a la RPC (check_in_reservation_with_guests / walk_in_check_in_with_guests
// / add_guests_to_stay / create_bulk_reservation, todas con p_occupancy_reason).
// No hay flujo de aprobación — con motivo, la RPC completa de inmediato.

// maxOccupancy null = el tipo de habitación no tiene tope declarado: nunca
// hace falta motivo.
export function needsOccupancyReason(
  resultingOccupancy: number,
  maxOccupancy: number | null,
): boolean {
  if (maxOccupancy == null) return false
  return resultingOccupancy > maxOccupancy
}

// Motivo trimeado a mandar en el payload de la RPC. undefined cuando no
// hace falta (dentro del máximo) o cuando el campo quedó vacío — igual que
// holderRpcParams, se omite del payload en vez de mandar '' o null, para
// que la RPC vea su propio default.
export function occupancyReasonParam(
  resultingOccupancy: number,
  maxOccupancy: number | null,
  reason: string,
): { occupancyReason?: string } {
  if (!needsOccupancyReason(resultingOccupancy, maxOccupancy)) return {}
  const trimmed = reason.trim()
  if (!trimmed) return {}
  return { occupancyReason: trimmed }
}
