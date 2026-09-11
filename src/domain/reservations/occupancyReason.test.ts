import { describe, expect, it } from 'vitest'
import { needsOccupancyReason, occupancyReasonParam } from './occupancyReason'

describe('needsOccupancyReason', () => {
  it('is false when resulting occupancy is within the max', () => {
    expect(needsOccupancyReason(2, 2)).toBe(false)
    expect(needsOccupancyReason(1, 2)).toBe(false)
  })

  it('is true when resulting occupancy exceeds the max', () => {
    expect(needsOccupancyReason(3, 2)).toBe(true)
  })

  it('is false when the room type has no declared max', () => {
    expect(needsOccupancyReason(99, null)).toBe(false)
  })
})

describe('occupancyReasonParam', () => {
  it('returns empty params when within the max (no reason needed)', () => {
    expect(occupancyReasonParam(2, 2, 'motivo que sobra')).toEqual({})
  })

  it('returns the trimmed reason when over the max and a reason was typed', () => {
    expect(occupancyReasonParam(3, 2, '  Cuna adicional  ')).toEqual({
      occupancyReason: 'Cuna adicional',
    })
  })

  it('returns empty params when over the max but the reason is blank', () => {
    expect(occupancyReasonParam(3, 2, '   ')).toEqual({})
  })

  it('returns empty params when there is no max to compare against', () => {
    expect(occupancyReasonParam(50, null, 'motivo')).toEqual({})
  })
})
