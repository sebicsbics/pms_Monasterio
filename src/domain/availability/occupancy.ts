// Disponibilidad — dominio puro (sin React/Supabase).
//
// Una reserva ocupa las NOCHES [checkIn, checkOut): la fecha de salida la
// habitación ya queda libre. Las fechas son 'YYYY-MM-DD', comparables como
// texto (orden lexicográfico == cronológico en ese formato).

export interface OccupancySpan {
  roomId: string
  checkIn: string // 'YYYY-MM-DD' inclusive
  checkOut: string // 'YYYY-MM-DD' exclusive
}

// Lista de fechas 'YYYY-MM-DD' entre from y to, ambas inclusive.
export function dateRange(from: string, to: string): string[] {
  const out: string[] = []
  if (!from || !to || from > to) return out
  const d = new Date(`${from}T00:00:00`)
  const end = new Date(`${to}T00:00:00`)
  while (d <= end) {
    out.push(d.toISOString().slice(0, 10))
    d.setDate(d.getDate() + 1)
  }
  return out
}

// ¿La habitación `roomId` está ocupada la noche `date`?
export function isOccupied(
  spans: OccupancySpan[],
  roomId: string,
  date: string,
): boolean {
  return spans.some(
    (s) => s.roomId === roomId && s.checkIn <= date && date < s.checkOut,
  )
}
