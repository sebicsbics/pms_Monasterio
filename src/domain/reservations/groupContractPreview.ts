// Total del contrato institucional (payerMode='client') a previsualizar en
// vivo mientras se completa el formulario de alta. Pura: sin React ni
// Supabase — decisión #339, regla de fórmula única simplificada:
// - room: suma de totales por habitación (ya con la tarifa/noches
//   aplicada por el caller), cortesía ya llega en 0.
// - person: agreedUnitPriceBs × numGuests × nights por habitación, sumado.
// En ambos casos una habitación cortesía no aporta al total.
export interface ContractRoomInput {
  isCourtesy: boolean
  numGuests: number
  // Total ya calculado para esa habitación en modo 'room' (p.ej.
  // nights × tarifa por noche). Ignorado en modo 'person'.
  roomTotalBs: number
}

export function computeContractPreview(params: {
  rooms: ContractRoomInput[]
  rateMode: 'room' | 'person'
  nights: number
  agreedUnitPriceBs: number | null
}): number {
  const { rooms, rateMode, nights, agreedUnitPriceBs } = params
  return rooms.reduce((sum, room) => {
    if (room.isCourtesy) return sum
    if (rateMode === 'person') {
      return sum + (agreedUnitPriceBs ?? 0) * room.numGuests * nights
    }
    return sum + room.roomTotalBs
  }, 0)
}
