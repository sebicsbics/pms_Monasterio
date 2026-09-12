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
            email: null,
            birth_date: '1990-01-01',
            guests: [
              {
                passport_number: '123',
                country_code: 'BOL',
                city: 'La Paz',
                origin_city: 'Santa Cruz',
                travel_purpose: 'turismo',
                occupation: 'ingeniera',
                transport_means: 'auto',
              },
            ],
          },
        },
        {
          role: 'companion',
          confirmed_at: '2026-09-11T10:00:00Z',
          people: {
            id: 'p-2',
            first_name: 'Luis',
            last_name: 'Gómez',
            email: null,
            birth_date: null,
            guests: [
              {
                passport_number: null,
                country_code: null,
                city: null,
                origin_city: null,
                travel_purpose: null,
                occupation: null,
                transport_means: null,
              },
            ],
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
        email: null,
        role: 'holder',
        confirmedAt: null,
        birthDate: '1990-01-01',
        countryCode: 'BOL',
        city: 'La Paz',
        originCity: 'Santa Cruz',
        travelPurpose: 'turismo',
        occupation: 'ingeniera',
        transportMeans: 'auto',
      },
      {
        personId: 'p-2',
        firstName: 'Luis',
        lastName: 'Gómez',
        document: null,
        email: null,
        role: 'companion',
        confirmedAt: '2026-09-11T10:00:00Z',
        birthDate: null,
        countryCode: null,
        city: null,
        originCity: null,
        travelPurpose: null,
        occupation: null,
        transportMeans: null,
      },
    ])
  })

  // PostgREST devuelve el embed uno-a-uno `guests` como OBJETO, no como
  // lista: people.id es la PK y guests.person_id es a la vez FK y PK, así
  // que la relación es 1:1. El fixture de arriba (lista) era una suposición
  // y por eso el test pasaba en verde mientras el check-in mostraba el
  // documento vacío en la app real. Este caso replica la respuesta textual
  // del servidor local:
  //   {"people":{"guests":{"passport_number":"5666468"}, ...}}
  it('maps the one-to-one guests embed when it comes back as an object', async () => {
    eqMock.mockResolvedValueOnce({
      data: [
        {
          role: 'holder',
          confirmed_at: null,
          people: {
            id: 'p-1',
            first_name: 'sebastian',
            last_name: 'davalos',
            email: 'sebas@gmail.com',
            birth_date: null,
            guests: {
              passport_number: '5666468',
              country_code: 'BOL',
              city: 'Sucre',
              origin_city: null,
              travel_purpose: null,
              occupation: null,
              transport_means: null,
            },
          },
        },
      ],
      error: null,
    })
    const [holder] = await fetchPreloadedOccupants('res-1')
    expect(holder.document).toBe('5666468')
    expect(holder.countryCode).toBe('BOL')
    expect(holder.city).toBe('Sucre')
  })

  it('surfaces the query error unchanged', async () => {
    eqMock.mockResolvedValueOnce({ data: null, error: { message: 'boom' } })
    await expect(fetchPreloadedOccupants('res-1')).rejects.toThrow('boom')
  })
})
