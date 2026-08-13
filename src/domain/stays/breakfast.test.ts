import { describe, expect, it } from 'vitest'
import {
  buildBreakfastSheet,
  nextBreakfastDate,
  splitIntoColumns,
  type BreakfastGuestRow,
  type BreakfastRoom,
} from './breakfast'
import type { InHouseStay } from './in-house'

function stay(patch: Partial<InHouseStay> = {}): InHouseStay {
  return {
    reservationId: 'res-1',
    roomId: 'room-1',
    roomNumber: '101',
    floor: 1,
    zone: null,
    roomType: 'Matrimonial',
    firstName: 'Ana',
    lastName: 'Pérez',
    email: null,
    countryCode: 'BOL',
    city: null,
    checkInDate: '2026-08-12',
    checkOutDate: '2026-08-15',
    roomTotalBs: 350,
    guestCount: 1,
    ...patch,
  }
}

function guest(patch: Partial<BreakfastGuestRow> = {}): BreakfastGuestRow {
  return {
    reservationId: 'res-1',
    personId: 'p1',
    firstName: 'Ana',
    lastName: 'Pérez',
    isHolder: true,
    countryCode: 'BOL',
    ...patch,
  }
}

describe('buildBreakfastSheet', () => {
  it('lists every guest of the room, holder first', () => {
    const rooms = buildBreakfastSheet(
      [stay({ guestCount: 2 })],
      [
        guest({ personId: 'p2', firstName: 'Luis', isHolder: false }),
        guest({ personId: 'p1', firstName: 'Ana', isHolder: true }),
      ],
    )

    expect(rooms).toHaveLength(1)
    expect(rooms[0].guests.map((g) => g.name)).toEqual(['Ana Pérez', 'Luis Pérez'])
  })

  it('orders rooms numerically, not alphabetically', () => {
    const rooms = buildBreakfastSheet(
      [
        stay({ reservationId: 'a', roomNumber: '10' }),
        stay({ reservationId: 'b', roomNumber: '2' }),
        stay({ reservationId: 'c', roomNumber: '100' }),
      ],
      [
        guest({ reservationId: 'a', personId: 'p1' }),
        guest({ reservationId: 'b', personId: 'p2' }),
        guest({ reservationId: 'c', personId: 'p3' }),
      ],
    )

    expect(rooms.map((r) => r.roomNumber)).toEqual(['2', '10', '100'])
  })

  it('resolves the ISO-3 code to a Spanish country name', () => {
    const rooms = buildBreakfastSheet([stay()], [guest({ countryCode: 'ARG' })])
    expect(rooms[0].guests[0].nationality).toBe('Argentina')
  })

  it('keeps an unknown code as-is instead of hiding it', () => {
    const rooms = buildBreakfastSheet([stay()], [guest({ countryCode: 'XXX' })])
    expect(rooms[0].guests[0].nationality).toBe('XXX')
  })

  it('shows a dash when the guest has no country on file', () => {
    const rooms = buildBreakfastSheet([stay()], [guest({ countryCode: null })])
    expect(rooms[0].guests[0].nationality).toBe('—')
  })

  // Una reserva vieja puede no tener las fichas de los acompañantes
  // cargadas. La habitación TIENE que salir igual en la hoja: si no,
  // las camareras no le llevan el desayuno a nadie de esa habitación.
  it('falls back to the holder from the stay when no guest rows exist', () => {
    const rooms = buildBreakfastSheet([stay({ firstName: 'Ana', lastName: 'Pérez' })], [])

    expect(rooms).toHaveLength(1)
    expect(rooms[0].guests).toEqual([{ name: 'Ana Pérez', nationality: 'Bolivia' }])
  })

  it('ignores guest rows whose room is no longer in house', () => {
    const rooms = buildBreakfastSheet([stay()], [guest({ reservationId: 'gone' })])
    expect(rooms.map((r) => r.roomNumber)).toEqual(['101'])
  })

  it('totals the guests across every room', () => {
    const rooms = buildBreakfastSheet(
      [stay({ reservationId: 'a', roomNumber: '1' }), stay({ reservationId: 'b', roomNumber: '2' })],
      [
        guest({ reservationId: 'a', personId: 'p1' }),
        guest({ reservationId: 'a', personId: 'p2', isHolder: false }),
        guest({ reservationId: 'b', personId: 'p3' }),
      ],
    )

    expect(rooms.reduce((n, r) => n + r.guests.length, 0)).toBe(3)
  })

  it('returns nothing when the hotel is empty', () => {
    expect(buildBreakfastSheet([], [])).toEqual([])
  })
})

describe('nextBreakfastDate', () => {
  // La hoja se arma de noche PARA el desayuno de la mañana siguiente.
  it('points to tomorrow when generated at night', () => {
    expect(nextBreakfastDate(new Date(2026, 7, 12, 23, 30))).toBe('2026-08-13')
  })

  it('points to tomorrow during the afternoon shift', () => {
    expect(nextBreakfastDate(new Date(2026, 7, 12, 16, 0))).toBe('2026-08-13')
  })

  // Pero si la reimprimen de madrugada o temprano, el desayuno que viene
  // es el de HOY: darles la hoja de mañana sería el huésped equivocado.
  it('points to today when reprinted in the early morning', () => {
    expect(nextBreakfastDate(new Date(2026, 7, 13, 5, 0))).toBe('2026-08-13')
  })

  it('still points to today at 09:59, while breakfast is being served', () => {
    expect(nextBreakfastDate(new Date(2026, 7, 13, 9, 59))).toBe('2026-08-13')
  })

  it('rolls to tomorrow once service closed at 10:00', () => {
    expect(nextBreakfastDate(new Date(2026, 7, 13, 10, 0))).toBe('2026-08-14')
  })

  it('crosses month and year boundaries in local time', () => {
    expect(nextBreakfastDate(new Date(2026, 11, 31, 22, 0))).toBe('2027-01-01')
  })
})

function room(roomNumber: string, guests: number): BreakfastRoom {
  return {
    reservationId: `res-${roomNumber}`,
    roomNumber,
    guests: Array.from({ length: guests }, (_, i) => ({
      name: `Huésped ${roomNumber}-${i}`,
      nationality: 'Bolivia',
    })),
  }
}

describe('splitIntoColumns', () => {
  // Con pocas habitaciones, una sola columna: partir en dos una lista
  // corta solo deja media hoja en blanco y se lee peor.
  it('keeps a short list in a single column', () => {
    const rooms = [room('1', 1), room('2', 2)]
    expect(splitIntoColumns(rooms, 10)).toEqual([rooms])
  })

  it('splits into two balanced columns when the list is long', () => {
    const rooms = [room('1', 1), room('2', 1), room('3', 1), room('4', 1)]
    const [left, right] = splitIntoColumns(rooms, 2)
    expect(left.map((r) => r.roomNumber)).toEqual(['1', '2'])
    expect(right.map((r) => r.roomNumber)).toEqual(['3', '4'])
  })

  // Una habitación NO se puede partir entre columnas: el número va una
  // sola vez y la mitad de abajo quedaría sin habitación.
  it('never splits a room across the two columns', () => {
    const rooms = [room('1', 3), room('2', 3)]
    const columns = splitIntoColumns(rooms, 2)
    expect(columns.every((col) => col.every((r) => r.guests.length === 3))).toBe(true)
    expect(columns.flat()).toHaveLength(2)
  })

  it('balances by guests, not by rooms', () => {
    // 1 habitación de 5 + 3 de 1: el corte va después de la primera.
    const rooms = [room('1', 5), room('2', 1), room('3', 1), room('4', 1)]
    const [left, right] = splitIntoColumns(rooms, 4)
    expect(left.map((r) => r.roomNumber)).toEqual(['1'])
    expect(right.map((r) => r.roomNumber)).toEqual(['2', '3', '4'])
  })

  it('keeps every room and never duplicates one', () => {
    const rooms = [room('1', 2), room('2', 2), room('3', 2), room('4', 2)]
    const flat = splitIntoColumns(rooms, 3).flat()
    expect(flat.map((r) => r.roomNumber)).toEqual(['1', '2', '3', '4'])
  })

  it('handles an empty sheet', () => {
    expect(splitIntoColumns([], 10)).toEqual([[]])
  })
})
