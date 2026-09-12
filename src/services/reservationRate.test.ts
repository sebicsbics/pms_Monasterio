import { describe, expect, it, vi } from 'vitest'

const singleMock = vi.fn(async () => ({
  data: null as {
    total_amount_bs: number | string | null
    check_in_date: string
    check_out_date: string
    room_types: { base_price_bs: number | string | null } | null
  } | null,
  error: null as { message: string } | null,
}))

vi.mock('./supabase', () => ({
  supabase: {
    from: () => ({
      select: () => ({
        eq: () => ({
          single: () => singleMock(),
        }),
      }),
    }),
  },
}))

import { fetchReservationRate } from './reservationRate'

describe('fetchReservationRate', () => {
  it('computes the per-night current rate from total_amount_bs / nights, and the base rate from room_types', async () => {
    singleMock.mockResolvedValueOnce({
      data: {
        total_amount_bs: 600,
        check_in_date: '2026-01-01',
        check_out_date: '2026-01-04',
        room_types: { base_price_bs: 250 },
      },
      error: null,
    })
    const result = await fetchReservationRate('r-1')
    expect(result).toEqual({ currentRateBs: 200, baseRateBs: 250 })
  })

  it('treats less than one night as one night (avoids divide by zero on same-day edge cases)', async () => {
    singleMock.mockResolvedValueOnce({
      data: {
        total_amount_bs: 150,
        check_in_date: '2026-01-01',
        check_out_date: '2026-01-01',
        room_types: { base_price_bs: 150 },
      },
      error: null,
    })
    const result = await fetchReservationRate('r-2')
    expect(result.currentRateBs).toBe(150)
  })

  it('returns null currentRateBs when total_amount_bs is null (no rate set yet)', async () => {
    singleMock.mockResolvedValueOnce({
      data: {
        total_amount_bs: null,
        check_in_date: '2026-01-01',
        check_out_date: '2026-01-02',
        room_types: { base_price_bs: 100 },
      },
      error: null,
    })
    const result = await fetchReservationRate('r-3')
    expect(result.currentRateBs).toBeNull()
    expect(result.baseRateBs).toBe(100)
  })

  it('throws the Postgres error message when the query fails', async () => {
    singleMock.mockResolvedValueOnce({ data: null, error: { message: 'boom' } })
    await expect(fetchReservationRate('r-4')).rejects.toThrow('boom')
  })
})
