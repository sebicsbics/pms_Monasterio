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
          method: 'web',
        },
      ],
      error: null,
    })
    const [arrival] = await fetchArrivals('2026-07-27', '2026-07-27')
    expect(arrival.reservationId).toBe('res-1')
    expect(arrival.roomNumber).toBe('101')
    expect(arrival.numGuests).toBe(2)
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
  }

  it('sends an empty companions array when none are given', async () => {
    rpcMock.mockClear()
    await checkInFromReservation('res-1', profile)
    expect(rpcMock).toHaveBeenCalledWith('check_in_reservation_with_guests', {
      p_reservation_id: 'res-1',
      p_document: '123',
      p_birth_date: null,
      p_country_code: 'BOL',
      p_city: 'La Paz',
      p_wants_offers: false,
      p_companions: [],
    })
  })

  it('maps and sends only companions that have first and last name', async () => {
    rpcMock.mockClear()
    await checkInFromReservation('res-2', profile, [
      { firstName: 'Ana', lastName: 'Pérez', document: 'X9', birthDate: '1990-01-01', countryCode: 'bol', city: 'Tarija' },
      { firstName: '', lastName: '', document: '', birthDate: '', countryCode: '', city: '' },
    ])
    const payload = rpcMock.mock.calls[0][1] as { p_companions: unknown[] }
    expect(payload.p_companions).toEqual([
      {
        first_name: 'Ana',
        last_name: 'Pérez',
        document: 'X9',
        birth_date: '1990-01-01',
        country_code: 'BOL',
        city: 'Tarija',
      },
    ])
  })

  it('surfaces the occupancy-cap error unchanged', async () => {
    rpcMock.mockResolvedValueOnce({
      data: null,
      error: { message: 'La reserva admite 2 huésped(es); estás registrando 3' },
    })
    await expect(checkInFromReservation('res-3', profile)).rejects.toThrow('La reserva admite 2')
  })
})
