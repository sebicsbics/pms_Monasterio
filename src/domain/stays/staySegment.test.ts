import { describe, expect, it } from 'vitest'
import { segmentNights, segmentTotalBs, type StaySegment } from './staySegment'

function segment(patch: Partial<StaySegment> = {}): StaySegment {
  return {
    id: 's1',
    roomId: 'r1',
    roomNumber: '101',
    roomType: 'Matrimonial',
    rateBs: 350,
    startDate: '2026-08-01',
    endDate: '2026-08-04',
    reason: null,
    ...patch,
  }
}

describe('segmentNights', () => {
  it('counts the range as [start, end): 3 nights', () => {
    expect(segmentNights(segment())).toBe(3)
  })

  it('counts a single night', () => {
    expect(
      segmentNights(segment({ startDate: '2026-08-01', endDate: '2026-08-02' })),
    ).toBe(1)
  })

  it('is not thrown off by a DST-style month boundary', () => {
    expect(
      segmentNights(segment({ startDate: '2026-10-30', endDate: '2026-11-02' })),
    ).toBe(3)
  })
})

describe('segmentTotalBs', () => {
  it('multiplies nights by the nightly rate', () => {
    expect(segmentTotalBs(segment())).toBe(1050)
  })

  it('handles a moved guest: 2 nights at 500 in the new room', () => {
    expect(
      segmentTotalBs(
        segment({ startDate: '2026-08-04', endDate: '2026-08-06', rateBs: 500 }),
      ),
    ).toBe(1000)
  })

  it('sums to the stay total across segments', () => {
    const segments = [
      segment({ startDate: '2026-08-01', endDate: '2026-08-04', rateBs: 350 }),
      segment({ id: 's2', startDate: '2026-08-04', endDate: '2026-08-06', rateBs: 500 }),
    ]
    expect(segments.reduce((sum, s) => sum + segmentTotalBs(s), 0)).toBe(2050)
  })
})
