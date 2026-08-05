import { describe, expect, it, vi } from 'vitest'

const rpcMock = vi.fn(async (..._args: unknown[]) => ({
  data: [] as unknown[] | null,
  error: null as { message: string } | null,
}))

vi.mock('./supabase', () => ({
  supabase: {
    rpc: (...args: unknown[]) => rpcMock(...args),
  },
}))

import { checkInFromReservation, fetchArrivals } from './arrivals'

describe('fetchArrivals', () => {
  it('sends the from/to range to the arrivals RPC', async () => {
    rpcMock.mockClear()
    await fetchArrivals('2026-07-27', '2026-08-02')
    expect(rpcMock).toHaveBeenCalledWith('arrivals', {
      p_from: '2026-07-27',
      p_to: '2026-08-02',
    })
  })

  it('passes null lower bound when omitted (includes overdue arrivals)', async () => {
    rpcMock.mockClear()
    await fetchArrivals(null, '2026-07-27')
    expect(rpcMock).toHaveBeenCalledWith('arrivals', {
      p_from: null,
      p_to: '2026-07-27',
    })
  })

  it('maps the row shape into Arrival objects', async () => {
    rpcMock.mockResolvedValueOnce({
      data: [
        {
          reservation_id: 'res-1',
          room_id: 'room-1',
          room_number: '101',
          room_type: 'Matrimonial',
          first_name: 'Ana',
          last_name: 'Pérez',
          phone: '555',
          email: null,
          check_in_date: '2026-07-27',
          check_out_date: '2026-07-29',
          num_guests: 2,
          max_occupancy: 3,
          method: 'web',
          anticipo_total_bs: '150.00',
        },
      ],
      error: null,
    })
    const [arrival] = await fetchArrivals('2026-07-27', '2026-07-27')
    expect(arrival.reservationId).toBe('res-1')
    expect(arrival.roomNumber).toBe('101')
    expect(arrival.numGuests).toBe(2)
    expect(arrival.maxOccupancy).toBe(3)
    expect(arrival.anticipoTotalBs).toBe(150)
  })

  it('surfaces the RPC error message unchanged', async () => {
    rpcMock.mockResolvedValueOnce({ data: null, error: { message: 'boom' } })
    await expect(fetchArrivals('2026-07-27', '2026-07-27')).rejects.toThrow('boom')
  })
})

describe('checkInFromReservation', () => {
  const profile = {
    document: '123',
    birthDate: '',
    countryCode: 'BOL',
    city: 'La Paz',
    wantsOffers: false,
    originCity: 'Cochabamba',
    travelPurpose: 'Turismo',
    occupation: 'Ingeniero',
    transportMeans: 'Auto',
  }

  it('sends an empty companions array and the traveler profile when none are given', async () => {
    rpcMock.mockClear()
    await checkInFromReservation('res-1', profile)
    expect(rpcMock).toHaveBeenCalledWith('check_in_reservation_with_guests', {
      p_reservation_id: 'res-1',
      p_document: '123',
      p_birth_date: null,
      p_country_code: 'BOL',
      p_city: 'La Paz',
      p_wants_offers: false,
      p_origin_city: 'Cochabamba',
      p_travel_purpose: 'Turismo',
      p_occupation: 'Ingeniero',
      p_transport_means: 'Auto',
      p_companions: [],
    })
  })

  it('maps and sends only companions that have first and last name', async () => {
    rpcMock.mockClear()
    await checkInFromReservation('res-2', profile, [
      { firstName: 'Ana', lastName: 'Pérez', isMinor: false, document: 'X9', birthDate: '1990-01-01', countryCode: 'bol', city: 'Tarija', originCity: 'Sucre', travelPurpose: 'Trabajo', occupation: 'Médica', transportMeans: 'Bus' },
      { firstName: '', lastName: '', isMinor: false, document: '', birthDate: '', countryCode: '', city: '', originCity: '', travelPurpose: '', occupation: '', transportMeans: '' },
    ])
    const payload = rpcMock.mock.calls[0][1] as { p_companions: unknown[] }
    expect(payload.p_companions).toEqual([
      {
        first_name: 'Ana',
        last_name: 'Pérez',
        is_minor: false,
        document: 'X9',
        birth_date: '1990-01-01',
        country_code: 'BOL',
        city: 'Tarija',
        origin_city: 'Sucre',
        travel_purpose: 'Trabajo',
        occupation: 'Médica',
        transport_means: 'Bus',
      },
    ])
  })

  it('blanks out adult fields for a minor companion but keeps name and birthdate', async () => {
    rpcMock.mockClear()
    await checkInFromReservation('res-4', profile, [
      { firstName: 'Niño', lastName: 'Pérez', isMinor: true, document: 'X9', birthDate: '2015-05-05', countryCode: 'BOL', city: 'Tarija', originCity: 'Sucre', travelPurpose: 'Trabajo', occupation: 'x', transportMeans: 'Bus' },
    ])
    const payload = rpcMock.mock.calls[0][1] as { p_companions: Record<string, unknown>[] }
    expect(payload.p_companions[0]).toEqual({
      first_name: 'Niño',
      last_name: 'Pérez',
      is_minor: true,
      birth_date: '2015-05-05',
      document: '',
      country_code: '',
      city: '',
      origin_city: '',
      travel_purpose: '',
      occupation: '',
      transport_means: '',
    })
  })

  it('surfaces the occupancy-cap error unchanged', async () => {
    rpcMock.mockResolvedValueOnce({
      data: null,
      error: { message: 'La reserva admite 2 huésped(es); estás registrando 3' },
    })
    await expect(checkInFromReservation('res-3', profile)).rejects.toThrow('La reserva admite 2')
  })
})
