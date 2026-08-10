// Reglas de duración de un turno.
//
// Un turno de recepción es de 8 a 12 horas. Cuando alguien se va sin
// fichar la salida, el fichaje queda abierto acumulando horas — en
// producción llegó a 104. Estas funciones marcan esos casos para que root
// los vea sin tener que revisar la tabla entera a ojo.

// Por encima de esto el turno no es plausible: nadie trabaja 16 horas
// seguidas en recepción, así que es un fichaje que quedó abierto.
export const IMPLAUSIBLE_SHIFT_HOURS = 16

export function shiftHours(clockIn: string, clockOut: string | null): number {
  const end = clockOut ? new Date(clockOut).getTime() : Date.now()
  return (end - new Date(clockIn).getTime()) / 3_600_000
}

export function isImplausibleShift(clockIn: string, clockOut: string | null): boolean {
  return shiftHours(clockIn, clockOut) > IMPLAUSIBLE_SHIFT_HOURS
}

export function formatShiftHours(clockIn: string, clockOut: string | null): string {
  const h = shiftHours(clockIn, clockOut)
  const hours = Math.floor(h)
  const minutes = Math.round((h - hours) * 60)
  return `${hours}h ${String(minutes).padStart(2, '0')}m`
}

// Valor inicial sugerido para cerrar un turno olvidado: la entrada más un
// turno normal. Cerrar con la hora ACTUAL registraría igual las horas
// falsas que se acumularon desde que la persona se fue.
export const SUGGESTED_SHIFT_HOURS = 8

export function suggestedClockOut(clockIn: string): Date {
  const suggested = new Date(
    new Date(clockIn).getTime() + SUGGESTED_SHIFT_HOURS * 3_600_000,
  )
  const now = new Date()
  return suggested > now ? now : suggested
}

// 'YYYY-MM-DDTHH:mm' en hora local, que es lo que espera un
// <input type="datetime-local">.
export function toLocalInputValue(d: Date): string {
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`
}
