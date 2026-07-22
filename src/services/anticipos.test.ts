import { describe, expect, it, vi } from 'vitest'

const rpcMock = vi.fn(async (..._args: unknown[]) => ({ data: null as unknown, error: null as { message: string } | null }))

vi.mock('./supabase', () => ({
  supabase: {
    rpc: (...args: unknown[]) => rpcMock(...args),
  },
}))

import { modifyAnticipo, recordAnticipo, refundAnticipo } from './anticipos'

describe('recordAnticipo', () => {
  it('sends the record_anticipo RPC payload with the given reservation/amount/method', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({
      data: {
        id: 'a1',
        reservation_id: 'r1',
        amount_bs: 100,
        refunded_amount_bs: 0,
        payment_method: 'QR',
        status: 'active',
        cash_movement_id: 'm1',
        received_by: 'u1',
        received_at: '2026-01-01T00:00:00Z',
        notes: null,
      },
      error: null,
    })
    const result = await recordAnticipo({
      reservationId: 'r1',
      amountBs: 100,
      paymentMethod: 'QR',
      notes: null,
    })
    expect(rpcMock).toHaveBeenCalledWith('record_anticipo', {
      p_reservation_id: 'r1',
      p_amount_bs: 100,
      p_payment_method: 'QR',
      p_notes: null,
    })
    expect(result.status).toBe('active')
    expect(result.amountBs).toBe(100)
  })

  it('surfaces the RPC error message unchanged (e.g. closed register)', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({ data: null, error: { message: 'No hay una caja abierta' } })
    await expect(
      recordAnticipo({ reservationId: 'r1', amountBs: 50, paymentMethod: 'EFECTIVO', notes: null }),
    ).rejects.toThrow('No hay una caja abierta')
  })
})

describe('refundAnticipo', () => {
  it('sends the refund_anticipo RPC payload with id/amount/reason', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({
      data: {
        id: 'a1',
        reservation_id: 'r1',
        amount_bs: 100,
        refunded_amount_bs: 40,
        payment_method: 'QR',
        status: 'partially_refunded',
        cash_movement_id: 'm1',
        received_by: 'u1',
        received_at: '2026-01-01T00:00:00Z',
        notes: null,
      },
      error: null,
    })
    const result = await refundAnticipo('a1', 40, 'no-show penalty')
    expect(rpcMock).toHaveBeenCalledWith('refund_anticipo', {
      p_anticipo_id: 'a1',
      p_refund_bs: 40,
      p_reason: 'no-show penalty',
    })
    expect(result.status).toBe('partially_refunded')
    expect(result.refundedAmountBs).toBe(40)
  })

  it('surfaces the over-refund rejection message unchanged', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({
      data: null,
      error: { message: 'El reembolso (41) excede el saldo disponible (40)' },
    })
    await expect(refundAnticipo('a1', 41, 'x')).rejects.toThrow('excede el saldo disponible')
  })
})

describe('modifyAnticipo', () => {
  it('sends the modify_anticipo RPC payload with id/amount/method/reason', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({
      data: {
        id: 'a1',
        reservation_id: 'r1',
        amount_bs: 120,
        refunded_amount_bs: 0,
        payment_method: 'TARJETA',
        status: 'active',
        cash_movement_id: 'm1',
        received_by: 'u1',
        received_at: '2026-01-01T00:00:00Z',
        notes: null,
      },
      error: null,
    })
    const result = await modifyAnticipo('a1', 120, 'TARJETA', 'corrección de monto')
    expect(rpcMock).toHaveBeenCalledWith('modify_anticipo', {
      p_anticipo_id: 'a1',
      p_new_amount_bs: 120,
      p_new_payment_method: 'TARJETA',
      p_reason: 'corrección de monto',
    })
    expect(result.paymentMethod).toBe('TARJETA')
  })

  it('surfaces the frozen-after-refund rejection unchanged', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({
      data: null,
      error: { message: 'No se puede modificar un anticipo ya reembolsado (total o parcialmente)' },
    })
    await expect(modifyAnticipo('a1', 90, 'QR', 'x')).rejects.toThrow('ya reembolsado')
  })
})
