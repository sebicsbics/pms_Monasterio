import { describe, expect, it } from 'vitest'
import { formatDate } from './date'

describe('formatDate', () => {
  it('formats a date-only ISO string (yyyy-mm-dd) as dd/mm/yyyy', () => {
    expect(formatDate('2026-07-16')).toBe('16/07/2026')
  })

  it('formats a full ISO timestamp as dd/mm/yyyy', () => {
    expect(formatDate('2026-01-05T14:30:00.000Z')).toBe('05/01/2026')
  })

  it('pads single-digit day and month with a leading zero', () => {
    expect(formatDate('2026-03-04')).toBe('04/03/2026')
  })

  it('returns an empty string for null', () => {
    expect(formatDate(null)).toBe('')
  })

  it('returns an empty string for undefined', () => {
    expect(formatDate(undefined)).toBe('')
  })

  it('returns an empty string for an empty string', () => {
    expect(formatDate('')).toBe('')
  })

  it('returns an empty string for an invalid date string', () => {
    expect(formatDate('not-a-date')).toBe('')
  })

  it('does not mutate the ISO storage format — only formats for display', () => {
    const iso = '2026-12-31'
    const formatted = formatDate(iso)
    expect(iso).toBe('2026-12-31')
    expect(formatted).toBe('31/12/2026')
  })
})
