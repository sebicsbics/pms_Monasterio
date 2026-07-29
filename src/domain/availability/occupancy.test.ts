import { describe, expect, it } from 'vitest'
import { dateRange, isOccupied, type OccupancySpan } from './occupancy'

describe('dateRange', () => {
  it('lists every date between from and to inclusive', () => {
    expect(dateRange('2026-07-27', '2026-07-30')).toEqual([
      '2026-07-27',
      '2026-07-28',
      '2026-07-29',
      '2026-07-30',
    ])
  })

  it('returns a single date when from equals to', () => {
    expect(dateRange('2026-07-27', '2026-07-27')).toEqual(['2026-07-27'])
  })

  it('crosses month boundaries', () => {
    expect(dateRange('2026-07-30', '2026-08-01')).toEqual([
      '2026-07-30',
      '2026-07-31',
      '2026-08-01',
    ])
  })

  it('returns empty when the range is inverted', () => {
    expect(dateRange('2026-07-30', '2026-07-27')).toEqual([])
  })
})

describe('isOccupied — ocupa las noches [checkIn, checkOut)', () => {
  const spans: OccupancySpan[] = [
    { roomId: 'r1', checkIn: '2026-07-27', checkOut: '2026-07-30' },
  ]

  it('is occupied on the check-in night', () => {
    expect(isOccupied(spans, 'r1', '2026-07-27')).toBe(true)
  })

  it('is occupied on an intermediate night', () => {
    expect(isOccupied(spans, 'r1', '2026-07-29')).toBe(true)
  })

  it('is FREE on the check-out day (room is released)', () => {
    expect(isOccupied(spans, 'r1', '2026-07-30')).toBe(false)
  })

  it('is free before the check-in', () => {
    expect(isOccupied(spans, 'r1', '2026-07-26')).toBe(false)
  })

  it('does not leak occupancy to another room', () => {
    expect(isOccupied(spans, 'r2', '2026-07-28')).toBe(false)
  })
})
