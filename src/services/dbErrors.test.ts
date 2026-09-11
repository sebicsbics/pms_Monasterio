import { describe, expect, it } from 'vitest'
import { toUserMessage } from './dbErrors'

describe('toUserMessage', () => {
  it('translates the reservation_guests_no_overlap exclusion violation', () => {
    const error = {
      code: '23P01',
      message:
        'conflicting key value violates exclusion constraint "reservation_guests_no_overlap"',
    }
    expect(toUserMessage(error)).toBe(
      'Esta persona ya está alojada en otra habitación en esas fechas.',
    )
  })

  it('returns the original message for a different 23P01 (other exclusion constraint)', () => {
    const error = { code: '23P01', message: 'some other exclusion constraint' }
    expect(toUserMessage(error)).toBe('some other exclusion constraint')
  })

  it('returns the original message for non-overlap errors (business validation in Spanish)', () => {
    const error = { code: undefined, message: 'La habitación admite 1 huésped(es)' }
    expect(toUserMessage(error)).toBe('La habitación admite 1 huésped(es)')
  })

  it('falls back to a generic message when there is no message at all', () => {
    expect(toUserMessage({})).toBe('Error desconocido')
  })
})
