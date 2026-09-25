import { describe, expect, it } from 'vitest'
import { formatInsufficientLabel, formatPartialRange } from './palette'

describe('formatPartialRange', () => {
  it('formats a range spanning different months', () => {
    expect(formatPartialRange('2020-09-01', '2020-12-30')).toBe('parcial: sep–dic')
  })

  it('collapses to a single month when desde and hasta share month', () => {
    expect(formatPartialRange('2013-09-05', '2013-09-30')).toBe('parcial: sep')
  })

  it('returns null when either date is missing', () => {
    expect(formatPartialRange(null, '2020-12-30')).toBeNull()
    expect(formatPartialRange('2020-09-01', null)).toBeNull()
    expect(formatPartialRange(null, null)).toBeNull()
  })
})

describe('formatInsufficientLabel', () => {
  it('formats a same-month day range', () => {
    expect(formatInsufficientLabel('2022-01-01', '2022-01-02')).toBe(
      'datos insuficientes (1–2 ene)',
    )
  })

  it('formats a cross-month day range', () => {
    expect(formatInsufficientLabel('2023-12-29', '2024-01-03')).toBe(
      'datos insuficientes (29 dic–3 ene)',
    )
  })

  it('falls back to a plain label when a date is missing', () => {
    expect(formatInsufficientLabel(null, '2022-01-02')).toBe('datos insuficientes')
  })
})
