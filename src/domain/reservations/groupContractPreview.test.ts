import { describe, expect, it } from 'vitest'
import { computeContractPreview } from './groupContractPreview'

describe('computeContractPreview', () => {
  it('room mode: suma los totales por habitación, la cortesía aporta 0', () => {
    const total = computeContractPreview({
      rooms: [
        { isCourtesy: false, numGuests: 2, roomTotalBs: 500 },
        { isCourtesy: true, numGuests: 1, roomTotalBs: 300 },
      ],
      rateMode: 'room',
      nights: 3,
      agreedUnitPriceBs: null,
    })
    expect(total).toBe(500)
  })

  it('person mode: unitPriceBs × numGuests × nights por habitación, sumado', () => {
    const total = computeContractPreview({
      rooms: [
        { isCourtesy: false, numGuests: 2, roomTotalBs: 0 },
        { isCourtesy: false, numGuests: 3, roomTotalBs: 0 },
      ],
      rateMode: 'person',
      nights: 4,
      agreedUnitPriceBs: 100,
    })
    // (100*2*4) + (100*3*4) = 800 + 1200 = 2000
    expect(total).toBe(2000)
  })

  it('sin habitaciones devuelve 0', () => {
    const total = computeContractPreview({
      rooms: [],
      rateMode: 'room',
      nights: 2,
      agreedUnitPriceBs: null,
    })
    expect(total).toBe(0)
  })
})
