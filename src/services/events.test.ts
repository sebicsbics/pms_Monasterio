import { describe, expect, it, vi } from 'vitest'

const rpcMock = vi.fn(async (..._args: unknown[]) => ({ error: null as { message: string } | null }))

vi.mock('./supabase', () => ({
  supabase: {
    rpc: (...args: unknown[]) => rpcMock(...args),
  },
}))

import { addEventPayment } from './events'

describe('addEventPayment', () => {
  it('sends the uppercase canonical payment method in the add_event_payment RPC payload', async () => {
    rpcMock.mockClear()
    await addEventPayment('event-1', 100, 'EFECTIVO', true)
    expect(rpcMock).toHaveBeenCalledWith('add_event_payment', {
      p_event_id: 'event-1',
      p_amount: 100,
      p_method: 'EFECTIVO',
      p_is_deposit: true,
    })
  })

  it('surfaces the RPC error message unchanged', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({ error: { message: 'Forma de pago inválida' } })
    await expect(
      addEventPayment('event-1', 100, 'efectivo' as never, false),
    ).rejects.toThrow('Forma de pago inválida')
  })
})
