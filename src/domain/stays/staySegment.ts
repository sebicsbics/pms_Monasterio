// Un tramo de la estadía: cuántas noches estuvo en qué habitación y a qué
// tarifa. Cuando el huésped se muda, la estadía pasa a tener 2+ tramos y
// el total de la reserva es la suma de todos.
export interface StaySegment {
  id: string
  roomId: string
  roomNumber: string
  roomType: string
  rateBs: number // por noche
  startDate: string // 'YYYY-MM-DD'
  endDate: string // exclusivo: noches = end - start
  reason: string | null
}

export function segmentNights(s: StaySegment): number {
  const ms = new Date(`${s.endDate}T00:00:00`).getTime() -
    new Date(`${s.startDate}T00:00:00`).getTime()
  return Math.round(ms / 86_400_000)
}

export function segmentTotalBs(s: StaySegment): number {
  return segmentNights(s) * s.rateBs
}
