import { COUNTRIES } from '../../shared/data/countries'
import type { AssignmentKind } from '../housekeeping/assignment'
import type { InHouseStay } from './in-house'

// Un huésped tal como llega de la vista `stay_guests` para armar la hoja
// de desayuno (titular + acompañantes, con su nacionalidad).
export interface BreakfastGuestRow {
  reservationId: string
  personId: string
  firstName: string
  lastName: string
  isHolder: boolean
  countryCode: string | null
}

export interface BreakfastGuest {
  name: string
  nationality: string
}

// Una habitación en la hoja: todos los que desayunan, en una línea.
//
// `cleaningKind` es el trabajo de housekeeping del día: la camarera usa
// ESTA misma hoja para saber qué habitación limpiar y cuál habilitar, así
// que la columna va acá y no en una segunda hoja que se le pierde.
export interface BreakfastRoom {
  reservationId: string
  roomNumber: string
  guests: BreakfastGuest[]
  cleaningKind: AssignmentKind | null
}

const COUNTRY_NAMES = new Map(COUNTRIES.map((c) => [c.code, c.name]))

// El código ISO-3 no le dice nada a nadie en una hoja impresa: se resuelve
// al nombre en español. Un código desconocido se muestra tal cual (es más
// útil que esconderlo); sin país en la ficha, un guion.
function nationality(code: string | null): string {
  if (!code) return '—'
  return COUNTRY_NAMES.get(code) ?? code
}

function fullName(first: string, last: string): string {
  return `${first} ${last}`.trim()
}

/**
 * Arma la hoja de desayuno: una fila por habitación ocupada, con TODOS sus
 * huéspedes y su nacionalidad, ordenada por número de habitación.
 *
 * Las habitaciones mandan: si una reserva vieja no tiene cargadas las
 * fichas de los acompañantes, la habitación igual sale en la hoja con el
 * titular. Una habitación que falta en esta hoja es una habitación que se
 * queda sin desayuno.
 *
 * `cleaningByRoomId` trae el tablero de housekeeping del día (limpieza o
 * habilitar). Si una habitación no tiene asignación, la columna sale
 * vacía en vez de suponer un tipo de limpieza: inventarlo mandaría a la
 * camarera a hacer el trabajo equivocado.
 */
export function buildBreakfastSheet(
  stays: InHouseStay[],
  guests: BreakfastGuestRow[],
  cleaningByRoomId: ReadonlyMap<string, AssignmentKind> = new Map(),
): BreakfastRoom[] {
  const byReservation = new Map<string, BreakfastGuestRow[]>()
  for (const g of guests) {
    const list = byReservation.get(g.reservationId)
    if (list) list.push(g)
    else byReservation.set(g.reservationId, [g])
  }

  return stays
    .map((stay) => {
      const rows = byReservation.get(stay.reservationId) ?? []
      const guests: BreakfastGuest[] =
        rows.length > 0
          ? rows
              .slice()
              .sort(
                (a, b) =>
                  Number(b.isHolder) - Number(a.isHolder) ||
                  fullName(a.firstName, a.lastName).localeCompare(
                    fullName(b.firstName, b.lastName),
                  ),
              )
              .map((g) => ({
                name: fullName(g.firstName, g.lastName),
                nationality: nationality(g.countryCode),
              }))
          : [
              {
                name: fullName(stay.firstName, stay.lastName),
                nationality: nationality(stay.countryCode),
              },
            ]

      return {
        reservationId: stay.reservationId,
        roomNumber: stay.roomNumber,
        guests,
        cleaningKind: cleaningByRoomId.get(stay.roomId) ?? null,
      }
    })
    .sort((a, b) => Number(a.roomNumber) - Number(b.roomNumber))
}

// Hora a la que cierra la atención de desayuno. Después de eso, la hoja
// que interesa ya es la de la mañana siguiente.
const BREAKFAST_CLOSES_AT_HOUR = 10

/**
 * Fecha del próximo desayuno, en ISO local (yyyy-mm-dd).
 *
 * La hoja se arma de noche para la mañana siguiente, así que por defecto
 * apunta a mañana. Pero si la reimprimen de madrugada o durante el
 * servicio, el desayuno que viene es el de HOY — imprimir la hoja de
 * mañana les daría la lista de huéspedes equivocada.
 *
 * Se calcula en hora LOCAL a propósito: `toISOString()` daría UTC y en
 * Bolivia (UTC-4) la hoja de la noche saldría con la fecha del día
 * siguiente equivocada.
 */
export function nextBreakfastDate(now: Date = new Date()): string {
  const target = new Date(now.getFullYear(), now.getMonth(), now.getDate())
  if (now.getHours() >= BREAKFAST_CLOSES_AT_HOUR) {
    target.setDate(target.getDate() + 1)
  }
  const month = String(target.getMonth() + 1).padStart(2, '0')
  const day = String(target.getDate()).padStart(2, '0')
  return `${target.getFullYear()}-${month}-${day}`
}

/**
 * Reparte las habitaciones en columnas para que la hoja entre en UNA
 * página con el hotel lleno.
 *
 * Achicar la letra hasta que entre tiene un límite: a partir de cierto
 * punto la camarera no puede leerla. El papel A4 en cambio tiene ancho de
 * sobra —la tabla es angosta— así que cuando la lista pasa de
 * `maxRowsPerColumn` se usan dos columnas en vez de encoger.
 *
 * Se corta por cantidad de HUÉSPEDES (que es lo que ocupa alto), nunca
 * por el medio de una habitación: el número va una sola vez arriba, y la
 * mitad que cayera en la otra columna quedaría huérfana.
 */
export function splitIntoColumns(
  rooms: BreakfastRoom[],
  maxRowsPerColumn: number,
): BreakfastRoom[][] {
  const totalRows = rooms.reduce((n, r) => n + r.guests.length, 0)
  if (totalRows <= maxRowsPerColumn) return [rooms]

  const half = totalRows / 2
  const left: BreakfastRoom[] = []
  const right: BreakfastRoom[] = []
  let used = 0

  for (const room of rooms) {
    // La habitación entera va donde empieza: si al agregarla ya se pasó
    // de la mitad, la siguiente arranca la segunda columna.
    if (used < half) {
      left.push(room)
      used += room.guests.length
    } else {
      right.push(room)
    }
  }

  return [left, right]
}
