import { describe, expect, it, vi } from 'vitest'
import type { CompanionGuest } from './arrivals'

const rpcMock = vi.fn(async (..._args: unknown[]) => ({
  data: 2 as unknown,
  error: null as { message: string } | null,
}))
const eqMock = vi.fn(async () => ({ data: [] as unknown[], error: null }))

vi.mock('./supabase', () => ({
  supabase: {
    rpc: (...args: unknown[]) => rpcMock(...args),
    from: () => ({ select: () => ({ eq: (...args: unknown[]) => eqMock(...(args as [])) }) }),
  },
}))

import { addGuestsToStay, fetchStayGuests } from './stayGuests'

function guest(patch: Partial<CompanionGuest> = {}): CompanionGuest {
  return {
    firstName: 'María',
    lastName: 'Pérez',
    isMinor: false,
    document: 'X123',
    birthDate: '1990-01-01',
    countryCode: 'BOL',
    city: 'La Paz',
    originCity: 'Oruro',
    travelPurpose: 'Turismo',
    occupation: 'Docente',
    transportMeans: 'Bus',
    ...patch,
  }
}

describe('fetchStayGuests', () => {
  it('puts the holder first regardless of row order', async () => {
    eqMock.mockResolvedValueOnce({
      data: [
        { person_id: 'p2', first_name: 'María', last_name: 'Pérez', is_holder: false, is_minor: false, document: 'X2' },
        { person_id: 'p1', first_name: 'Juan', last_name: 'Pérez', is_holder: true, is_minor: false, document: 'X1' },
      ],
      error: null,
    })
    const guests = await fetchStayGuests('room-1')
    expect(guests.map((g) => g.personId)).toEqual(['p1', 'p2'])
    expect(guests[0].isHolder).toBe(true)
  })
})

describe('addGuestsToStay', () => {
  it('sends the companions payload and the folio charge to the RPC', async () => {
    rpcMock.mockClear()
    const total = await addGuestsToStay('room-1', [guest()], 200, ' Huésped adicional ')
    expect(rpcMock).toHaveBeenCalledWith('add_guests_to_stay', {
      p_room_id: 'room-1',
      p_companions: [expect.objectContaining({ first_name: 'María', last_name: 'Pérez' })],
      p_extra_charge_bs: 200,
      p_charge_description: 'Huésped adicional',
    })
    expect(total).toBe(2)
  })

  it('sends a null description when left blank (the RPC builds a default)', async () => {
    rpcMock.mockClear()
    await addGuestsToStay('room-1', [guest()], 0, '   ')
    expect(rpcMock.mock.calls[0][1]).toMatchObject({ p_charge_description: null })
  })

  it('rejects guests without a full name before hitting the network', async () => {
    rpcMock.mockClear()
    await expect(
      addGuestsToStay('room-1', [guest({ firstName: '  ', lastName: '' })], 0, ''),
    ).rejects.toThrow('nombre y apellido')
    expect(rpcMock).not.toHaveBeenCalled()
  })
})
