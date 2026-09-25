import { describe, expect, it } from 'vitest'
import { formatPartialRange } from './palette'

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
