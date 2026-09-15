import { describe, expect, it, vi } from 'vitest'

const rpcMock = vi.fn(async (..._args: unknown[]) => ({ data: null as unknown, error: null as { message: string } | null }))

vi.mock('./supabase', () => ({
  supabase: {
    rpc: (...args: unknown[]) => rpcMock(...args),
  },
}))

import { recordBookingAdvance } from './bookings'

describe('recordBookingAdvance', () => {
  it('sends the record_booking_advance RPC payload with the given booking/amount/method', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({ data: 'mov-1', error: null })
    const result = await recordBookingAdvance({
      bookingId: 'b1',
      amountBs: 500,
      paymentMethod: 'EFECTIVO',
      notes: null,
    })
    expect(rpcMock).toHaveBeenCalledWith('record_booking_advance', {
      p_booking_id: 'b1',
      p_amount_bs: 500,
      p_payment_method: 'EFECTIVO',
      p_receipt_path: null,
      p_payment_reference: null,
      p_cash_bs: null,
      p_non_cash_bs: null,
      p_non_cash_method: null,
      p_notes: null,
    })
    expect(result).toBe('mov-1')
  })

  it('sends the mixed-payment breakdown (cash + non-cash leg) when mixed is given', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({ data: 'mov-2', error: null })
    const result = await recordBookingAdvance({
      bookingId: 'b2',
      amountBs: 500,
      paymentMethod: 'MIXTO',
      notes: 'Adelanto mixto',
      mixed: { cashBs: 300, nonCashBs: 200, nonCashMethod: 'DEPOSITO' },
    })
    expect(rpcMock).toHaveBeenCalledWith('record_booking_advance', {
      p_booking_id: 'b2',
      p_amount_bs: 500,
      p_payment_method: 'MIXTO',
      p_receipt_path: null,
      p_payment_reference: null,
      p_cash_bs: 300,
      p_non_cash_bs: 200,
      p_non_cash_method: 'DEPOSITO',
      p_notes: 'Adelanto mixto',
    })
    expect(result).toBe('mov-2')
  })

  it('surfaces the RPC error message unchanged (e.g. closed group booking)', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({ data: null, error: { message: 'Esta reserva de grupo ya está cerrada' } })
    await expect(
      recordBookingAdvance({ bookingId: 'b3', amountBs: 100, paymentMethod: 'EFECTIVO', notes: null }),
    ).rejects.toThrow('Esta reserva de grupo ya está cerrada')
  })

  it('surfaces the no-open-cash-session rejection unchanged', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({ data: null, error: { message: 'No hay una caja abierta' } })
    await expect(
      recordBookingAdvance({ bookingId: 'b4', amountBs: 100, paymentMethod: 'EFECTIVO', notes: null }),
    ).rejects.toThrow('No hay una caja abierta')
  })
})
