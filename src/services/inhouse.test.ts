import { describe, expect, it, vi } from 'vitest'

const selectMock = vi.fn(async (..._args: unknown[]) => ({
  data: [] as unknown[] | null,
  error: null as { message: string } | null,
}))
const fromMock = vi.fn((_table: string) => ({
  select: (...args: unknown[]) => selectMock(...args),
}))

vi.mock('./supabase', () => ({
  supabase: { from: (table: string) => fromMock(table) },
}))

import { fetchBreakfastGuests, fetchInHouse } from './inhouse'

const row = {
  reservation_id: 'res-1',
  room_id: 'room-1',
  room_number: '101',
  floor: 1,
  zone: null,
  room_type: 'Matrimonial',
  first_name: 'Ana',
  last_name: 'Pérez',
  email: null,
  country_code: 'BOL',
  city: null,
  check_in_date: '2026-08-12',
  check_out_date: '2026-08-15',
  room_total_bs: '350.00',
  guest_count: 2,
}

describe('fetchInHouse', () => {
  it('maps the view row, including the guest count', async () => {
    selectMock.mockResolvedValueOnce({ data: [row], error: null })
    const [stay] = await fetchInHouse()
    expect(stay).toMatchObject({ roomNumber: '101', roomTotalBs: 350, guestCount: 2 })
  })

  // La vista vieja no traía guest_count: sin fallback la pantalla mostraría
  // NaN huéspedes hasta que corra la migración.
  it('falls back to 1 guest when the column is missing', async () => {
    selectMock.mockResolvedValueOnce({
      data: [{ ...row, guest_count: undefined }],
      error: null,
    })
    const [stay] = await fetchInHouse()
    expect(stay.guestCount).toBe(1)
  })

  it('sorts rooms numerically', async () => {
    selectMock.mockResolvedValueOnce({
      data: [
        { ...row, room_number: '10' },
        { ...row, room_number: '2' },
      ],
      error: null,
    })
    expect((await fetchInHouse()).map((s) => s.roomNumber)).toEqual(['2', '10'])
  })

  it('surfaces the database error message', async () => {
    selectMock.mockResolvedValueOnce({ data: null, error: { message: 'permission denied' } })
    await expect(fetchInHouse()).rejects.toThrow('permission denied')
  })
})

describe('fetchBreakfastGuests', () => {
  it('reads every in-house guest from stay_guests with their country', async () => {
    selectMock.mockResolvedValueOnce({
      data: [
        {
          reservation_id: 'res-1',
          person_id: 'p1',
          first_name: 'Ana',
          last_name: 'Pérez',
          is_holder: true,
          country_code: 'BOL',
        },
      ],
      error: null,
    })

    const guests = await fetchBreakfastGuests()

    expect(fromMock).toHaveBeenCalledWith('stay_guests')
    expect(guests).toEqual([
      {
        reservationId: 'res-1',
        personId: 'p1',
        firstName: 'Ana',
        lastName: 'Pérez',
        isHolder: true,
        countryCode: 'BOL',
      },
    ])
  })

  it('surfaces the database error message', async () => {
    selectMock.mockResolvedValueOnce({ data: null, error: { message: 'permission denied' } })
    await expect(fetchBreakfastGuests()).rejects.toThrow('permission denied')
  })
})
