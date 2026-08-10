import { describe, expect, it, vi, afterEach } from 'vitest'
import {
  formatShiftHours,
  IMPLAUSIBLE_SHIFT_HOURS,
  isImplausibleShift,
  shiftHours,
  suggestedClockOut,
  toLocalInputValue,
} from './shift'

const IN = '2026-08-05T11:00:00.000Z'
const plus = (hours: number) =>
  new Date(new Date(IN).getTime() + hours * 3_600_000).toISOString()

afterEach(() => {
  vi.useRealTimers()
})

describe('shiftHours', () => {
  it('measures a closed shift', () => {
    expect(shiftHours(IN, plus(8))).toBe(8)
  })

  it('measures an open shift against the current time', () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date(plus(3)))
    expect(shiftHours(IN, null)).toBe(3)
  })
})

describe('isImplausibleShift', () => {
  it('accepts a normal 8-hour shift', () => {
    expect(isImplausibleShift(IN, plus(8))).toBe(false)
  })

  it('accepts a long but possible 16-hour shift (the boundary)', () => {
    expect(isImplausibleShift(IN, plus(IMPLAUSIBLE_SHIFT_HOURS))).toBe(false)
  })

  it('flags anything past the boundary', () => {
    expect(isImplausibleShift(IN, plus(16.5))).toBe(true)
  })

  // El caso real que motivó el cambio: un fichaje que quedó abierto y
  // terminó registrando 104 horas.
  it('flags the 104-hour entry seen in production', () => {
    expect(isImplausibleShift(IN, plus(104))).toBe(true)
  })

  it('flags an open shift that has been running too long', () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date(plus(30)))
    expect(isImplausibleShift(IN, null)).toBe(true)
  })
})

describe('formatShiftHours', () => {
  it('shows hours and minutes', () => {
    expect(formatShiftHours(IN, plus(8.5))).toBe('8h 30m')
  })

  it('pads the minutes', () => {
    expect(formatShiftHours(IN, plus(8.0833))).toBe('8h 05m')
  })
})

describe('suggestedClockOut', () => {
  // Cerrar con la hora ACTUAL registraría las horas falsas acumuladas
  // desde que la persona se fue, que es justo lo que se quiere evitar.
  it('suggests entry + 8h, not the current time', () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date(plus(30)))
    expect(suggestedClockOut(IN).toISOString()).toBe(plus(8))
  })

  it('never suggests a future time for a shift still within its first hours', () => {
    vi.useFakeTimers()
    const now = new Date(plus(2))
    vi.setSystemTime(now)
    expect(suggestedClockOut(IN).getTime()).toBe(now.getTime())
  })
})

describe('toLocalInputValue', () => {
  it('formats for a datetime-local input, zero-padded', () => {
    expect(toLocalInputValue(new Date(2026, 7, 5, 9, 7))).toBe('2026-08-05T09:07')
  })
})
