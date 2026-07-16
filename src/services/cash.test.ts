import { describe, expect, it, vi } from 'vitest'

const rpcMock = vi.fn(async (..._args: unknown[]) => ({ error: null as { message: string } | null }))

vi.mock('./supabase', () => ({
  supabase: {
    rpc: (...args: unknown[]) => rpcMock(...args),
  },
}))

import { addCashMovement, voidMovement } from './cash'

describe('addCashMovement', () => {
  it('sends payment_method in the add_cash_movement RPC payload', async () => {
    rpcMock.mockClear()
    await addCashMovement({
      kind: 'income',
      category: 'cobro_habitacion',
      amount: 100,
      concept: 'test',
      receipt: null,
      paymentMethod: 'qr',
    })
    expect(rpcMock).toHaveBeenCalledWith('add_cash_movement', {
      p_kind: 'income',
      p_category: 'cobro_habitacion',
      p_amount: 100,
      p_concept: 'test',
      p_receipt_path: null,
      p_payment_method: 'qr',
    })
  })

  it('sends payment_method null when not provided', async () => {
    rpcMock.mockClear()
    await addCashMovement({
      kind: 'expense',
      category: 'compras',
      amount: 50,
      concept: '',
      receipt: null,
    })
    expect(rpcMock).toHaveBeenCalledWith('add_cash_movement', expect.objectContaining({
      p_payment_method: null,
    }))
  })

  it('surfaces the RPC error message unchanged', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({ error: { message: 'No hay una caja abierta' } })
    await expect(
      addCashMovement({
        kind: 'income',
        category: 'cobro_habitacion',
        amount: 10,
        concept: '',
        receipt: null,
      }),
    ).rejects.toThrow('No hay una caja abierta')
  })
})

describe('voidMovement', () => {
  it('requests void_cash_movement with the movement id and reason', async () => {
    rpcMock.mockClear()
    await voidMovement('mov-1', 'error de carga')
    expect(rpcMock).toHaveBeenCalledWith('void_cash_movement', {
      p_id: 'mov-1',
      p_reason: 'error de carga',
    })
  })
})
