import { describe, expect, it, vi } from 'vitest'

const eqMock = vi.fn()
const selectMock = vi.fn(() => ({ eq: eqMock }))
const fromMock = vi.fn((..._args: unknown[]) => ({ select: selectMock }))

vi.mock('./supabase', () => ({
  supabase: {
    from: (...args: unknown[]) => fromMock(...args),
  },
}))

import { fetchPreloadedOccupants } from './reservationGuests'

describe('fetchPreloadedOccupants', () => {
  it('queries reservation_guests filtered by reservation id', async () => {
    eqMock.mockResolvedValueOnce({ data: [], error: null })
    await fetchPreloadedOccupants('res-1')
    expect(fromMock).toHaveBeenCalledWith('reservation_guests')
    expect(eqMock).toHaveBeenCalledWith('reservation_id', 'res-1')
  })

  it('maps rows (nested people/guests) into PreloadedOccupant', async () => {
    eqMock.mockResolvedValueOnce({
      data: [
        {
          role: 'holder',
          confirmed_at: null,
          people: {
            id: 'p-1',
            first_name: 'Ana',
            last_name: 'Pérez',
            guests: [{ passport_number: '123' }],
          },
        },
        {
          role: 'companion',
          confirmed_at: '2026-09-11T10:00:00Z',
          people: {
            id: 'p-2',
            first_name: 'Luis',
            last_name: 'Gómez',
            guests: [{ passport_number: null }],
          },
        },
      ],
      error: null,
    })
    const result = await fetchPreloadedOccupants('res-1')
    expect(result).toEqual([
      {
        personId: 'p-1',
        firstName: 'Ana',
        lastName: 'Pérez',
        document: '123',
        role: 'holder',
        confirmedAt: null,
      },
      {
        personId: 'p-2',
        firstName: 'Luis',
        lastName: 'Gómez',
        document: null,
        role: 'companion',
        confirmedAt: '2026-09-11T10:00:00Z',
      },
    ])
  })

  it('surfaces the query error unchanged', async () => {
    eqMock.mockResolvedValueOnce({ data: null, error: { message: 'boom' } })
    await expect(fetchPreloadedOccupants('res-1')).rejects.toThrow('boom')
  })
})
