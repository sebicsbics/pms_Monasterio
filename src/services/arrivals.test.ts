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

// checkInWithOptionalPayment orquesta dos llamadas independientes:
// check-in (arriba, vía supabase.rpc mockeado) y recordAnticipo (un
// colaborador de otro módulo). Mockear recordAnticipo directamente aísla
// la prueba de la lógica de subida de comprobante/armado de payload que
// ya cubre anticipos.test.ts — acá solo importa el ORDEN y que un fallo
// del pago no tumbe el check-in ya confirmado.
const recordAnticipoMock = vi.fn()
vi.mock('./anticipos', () => ({
  recordAnticipo: (...args: unknown[]) => recordAnticipoMock(...args),
}))

import {
  checkInFromReservation,
  checkInWithOptionalPayment,
  fetchArrivals,
} from './arrivals'

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
          holder_first_name: null,
          holder_last_name: null,
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
    expect(arrival.holderFirstName).toBeNull()
    expect(arrival.holderLastName).toBeNull()
  })

  it('maps a non-null holder name when the room was preloaded with occupants', async () => {
    rpcMock.mockResolvedValueOnce({
      data: [
        {
          reservation_id: 'res-2',
          room_id: 'room-2',
          room_number: '102',
          room_type: 'Matrimonial',
          first_name: 'Org',
          last_name: 'Anizador',
          phone: '555',
          email: null,
          check_in_date: '2026-07-27',
          check_out_date: '2026-07-29',
          num_guests: 2,
          max_occupancy: 3,
          method: 'web',
          anticipo_total_bs: null,
          holder_first_name: 'Juan',
          holder_last_name: 'Titular',
        },
      ],
      error: null,
    })
    const [arrival] = await fetchArrivals('2026-07-27', '2026-07-27')
    expect(arrival.holderFirstName).toBe('Juan')
    expect(arrival.holderLastName).toBe('Titular')
  })

  it('maps null account fields for an each_stay reservation without an account row', async () => {
    rpcMock.mockResolvedValueOnce({
      data: [
        {
          reservation_id: 'res-3',
          room_id: 'room-3',
          room_number: '103',
          room_type: 'Simple',
          first_name: 'Luis',
          last_name: 'Gómez',
          phone: '555',
          email: null,
          check_in_date: '2026-07-27',
          check_out_date: '2026-07-28',
          num_guests: 1,
          max_occupancy: 2,
          method: 'walk_in',
          anticipo_total_bs: null,
          holder_first_name: 'Luis',
          holder_last_name: 'Gómez',
          account_name: null,
          account_kind: null,
        },
      ],
      error: null,
    })
    const [arrival] = await fetchArrivals('2026-07-27', '2026-07-27')
    expect(arrival.accountName).toBeNull()
    expect(arrival.accountKind).toBeNull()
  })

  it('maps the receivable account of an institutional (client) reservation', async () => {
    rpcMock.mockResolvedValueOnce({
      data: [
        {
          reservation_id: 'res-4',
          room_id: 'room-4',
          room_number: '104',
          room_type: 'Doble',
          first_name: 'Org',
          last_name: 'Anizador',
          phone: '555',
          email: null,
          check_in_date: '2026-07-27',
          check_out_date: '2026-07-29',
          num_guests: 2,
          max_occupancy: 2,
          method: 'web',
          anticipo_total_bs: null,
          holder_first_name: null,
          holder_last_name: null,
          account_name: 'Viajes del Sur',
          account_kind: 'agencia',
        },
      ],
      error: null,
    })
    const [arrival] = await fetchArrivals('2026-07-27', '2026-07-27')
    expect(arrival.accountName).toBe('Viajes del Sur')
    expect(arrival.accountKind).toBe('agencia')
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
      p_email: null,
      p_origin_city: 'Cochabamba',
      p_travel_purpose: 'Turismo',
      p_occupation: 'Ingeniero',
      p_transport_means: 'Auto',
      p_companions: [],
      p_agency_name: null,
      p_channel_code: null,
    })
  })

  it('forwards the trimmed email when present in the profile', async () => {
    rpcMock.mockClear()
    await checkInFromReservation('res-10', { ...profile, email: '  ana@example.com  ' })
    expect(rpcMock).toHaveBeenCalledWith(
      'check_in_reservation_with_guests',
      expect.objectContaining({ p_email: 'ana@example.com' }),
    )
  })

  it('sends null (not empty string) when email is blank', async () => {
    rpcMock.mockClear()
    await checkInFromReservation('res-11', { ...profile, email: '   ' })
    expect(rpcMock).toHaveBeenCalledWith(
      'check_in_reservation_with_guests',
      expect.objectContaining({ p_email: null }),
    )
  })

  it('forwards agencyName and channelCode when present in the profile', async () => {
    rpcMock.mockClear()
    await checkInFromReservation('res-5', {
      ...profile,
      agencyName: 'Agencia Andina',
      channelCode: 'AGENCIA',
    })
    expect(rpcMock).toHaveBeenCalledWith(
      'check_in_reservation_with_guests',
      expect.objectContaining({
        p_agency_name: 'Agencia Andina',
        p_channel_code: 'AGENCIA',
      }),
    )
  })

  it('sends null for agency/channel when omitted from the profile', async () => {
    rpcMock.mockClear()
    await checkInFromReservation('res-6', profile)
    expect(rpcMock).toHaveBeenCalledWith(
      'check_in_reservation_with_guests',
      expect.objectContaining({
        p_agency_name: null,
        p_channel_code: null,
      }),
    )
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

  it('omits the holder params when the stay already has a holder (unchanged payload)', async () => {
    rpcMock.mockClear()
    await checkInFromReservation('res-7', profile)
    const payload = rpcMock.mock.calls[0][1] as Record<string, unknown>
    expect(Object.keys(payload)).not.toContain('p_holder_person_id')
    expect(Object.keys(payload)).not.toContain('p_holder_first_name')
    expect(Object.keys(payload)).not.toContain('p_holder_last_name')
  })

  it('sends p_holder_person_id when an existing preloaded occupant was chosen as holder', async () => {
    rpcMock.mockClear()
    await checkInFromReservation('res-8', { ...profile, holderPersonId: 'p-1' })
    expect(rpcMock).toHaveBeenCalledWith(
      'check_in_reservation_with_guests',
      expect.objectContaining({ p_holder_person_id: 'p-1' }),
    )
  })

  it('sends p_holder_first_name/p_holder_last_name when a new holder name was typed', async () => {
    rpcMock.mockClear()
    await checkInFromReservation('res-9', {
      ...profile,
      holderFirstName: 'Ana',
      holderLastName: 'Pérez',
    })
    expect(rpcMock).toHaveBeenCalledWith(
      'check_in_reservation_with_guests',
      expect.objectContaining({ p_holder_first_name: 'Ana', p_holder_last_name: 'Pérez' }),
    )
  })
})

describe('checkInWithOptionalPayment', () => {
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

  it('no llama a recordAnticipo cuando no se pasa payment (checkout, R2.2)', async () => {
    rpcMock.mockClear()
    recordAnticipoMock.mockClear()
    rpcMock.mockResolvedValueOnce({ data: null, error: null })

    const outcome = await checkInWithOptionalPayment('res-1', profile, [], null)

    expect(rpcMock).toHaveBeenCalledTimes(1)
    expect(recordAnticipoMock).not.toHaveBeenCalled()
    expect(outcome).toEqual({ checkedIn: true, paymentRecorded: false, paymentError: null })
  })

  it('llama check-in PRIMERO y recién después recordAnticipo (R2.1)', async () => {
    rpcMock.mockClear()
    recordAnticipoMock.mockClear()
    const order: string[] = []
    rpcMock.mockImplementationOnce(async () => {
      order.push('checkin')
      return { data: null, error: null }
    })
    recordAnticipoMock.mockImplementationOnce(async () => {
      order.push('anticipo')
      return {}
    })

    await checkInWithOptionalPayment('res-2', profile, [], {
      amountBs: 100,
      paymentMethod: 'EFECTIVO',
      notes: null,
    })

    expect(order).toEqual(['checkin', 'anticipo'])
    expect(recordAnticipoMock).toHaveBeenCalledWith(
      expect.objectContaining({
        reservationId: 'res-2',
        amountBs: 100,
        paymentMethod: 'EFECTIVO',
      }),
    )
  })

  it('si el check-in falla, NUNCA llama a recordAnticipo y propaga el error', async () => {
    rpcMock.mockClear()
    recordAnticipoMock.mockClear()
    rpcMock.mockResolvedValueOnce({ data: null, error: { message: 'Reserva no encontrada' } })

    await expect(
      checkInWithOptionalPayment('res-3', profile, [], {
        amountBs: 100,
        paymentMethod: 'EFECTIVO',
        notes: null,
      }),
    ).rejects.toThrow('Reserva no encontrada')
    expect(recordAnticipoMock).not.toHaveBeenCalled()
  })

  it('si recordAnticipo falla (caja cerrada), el check-in queda firme y el error se reporta sin relanzar (R2.8/R2.10)', async () => {
    rpcMock.mockClear()
    recordAnticipoMock.mockClear()
    rpcMock.mockResolvedValueOnce({ data: null, error: null })
    recordAnticipoMock.mockRejectedValueOnce(new Error('No hay una caja abierta'))

    const outcome = await checkInWithOptionalPayment('res-4', profile, [], {
      amountBs: 100,
      paymentMethod: 'EFECTIVO',
      notes: null,
    })

    expect(outcome).toEqual({
      checkedIn: true,
      paymentRecorded: false,
      paymentError: 'No hay una caja abierta',
    })
  })

  it('cuando el pago se registra con éxito, marca paymentRecorded true y paymentError null', async () => {
    rpcMock.mockClear()
    recordAnticipoMock.mockClear()
    rpcMock.mockResolvedValueOnce({ data: null, error: null })
    recordAnticipoMock.mockResolvedValueOnce({ id: 'ant-1' })

    const outcome = await checkInWithOptionalPayment('res-5', profile, [], {
      amountBs: 100,
      paymentMethod: 'EFECTIVO',
      notes: null,
    })

    expect(outcome).toEqual({ checkedIn: true, paymentRecorded: true, paymentError: null })
  })
})
