import { describe, expect, it } from 'vitest'
import { occupantCountWarning } from './occupants'

describe('occupantCountWarning', () => {
  it('returns null when no occupants were preloaded (holder set at check-in)', () => {
    expect(occupantCountWarning(2, 0)).toBeNull()
  })

  it('returns null when the preloaded count matches num_guests', () => {
    expect(occupantCountWarning(2, 2)).toBeNull()
  })

  it('warns (does not block) when fewer occupants were preloaded than estimated', () => {
    expect(occupantCountWarning(3, 1)).toBe(
      'Cargaste 1 huésped(es) pero la habitación estima 3.',
    )
  })

  it('warns (does not block) when more occupants were preloaded than estimated', () => {
    expect(occupantCountWarning(2, 4)).toBe(
      'Cargaste 4 huésped(es), más que los 2 estimados para la habitación.',
    )
  })
})
