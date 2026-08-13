import { describe, expect, it } from 'vitest'
import { MIN_FIT_SCALE, fitScale } from './fitToPage'

describe('fitScale', () => {
  it('does not scale up content that already fits', () => {
    expect(fitScale(500, 1000)).toBe(1)
  })

  it('leaves content that exactly fills the page untouched', () => {
    expect(fitScale(1000, 1000)).toBe(1)
  })

  it('shrinks content to the available height', () => {
    expect(fitScale(1250, 1000)).toBe(0.8)
  })

  // Por debajo de este punto la hoja deja de ser legible a un metro de
  // distancia en la cocina: es preferible que salga en dos páginas a que
  // salga en una que nadie puede leer.
  it('refuses to shrink past the legibility floor', () => {
    expect(fitScale(10000, 1000)).toBe(MIN_FIT_SCALE)
  })

  it('treats a missing measurement as "no scaling"', () => {
    expect(fitScale(0, 1000)).toBe(1)
    expect(fitScale(1200, 0)).toBe(1)
  })
})
