import { describe, expect, it, vi } from 'vitest'

const rpcMock = vi.fn(async (..._args: unknown[]) => ({
  data: 100 as number | null,
  error: null as { message: string } | null,
}))
const uploadMock = vi.fn(async (..._args: unknown[]) => ({
  error: null as { message: string } | null,
}))

vi.mock('./supabase', () => ({
  supabase: {
    rpc: (...args: unknown[]) => rpcMock(...args),
    storage: {
      from: () => ({
        upload: (...args: unknown[]) => uploadMock(...args),
      }),
    },
  },
}))

import { checkOutRoom } from './checkin'

describe('checkOutRoom', () => {
  it('sends payment_reference (no receipt) in the check_out_room RPC payload', async () => {
    rpcMock.mockClear()
    uploadMock.mockClear()
    await checkOutRoom('room-1', 'tarjeta', {
      receipt: null,
      paymentReference: 'AB12345',
    })
    expect(uploadMock).not.toHaveBeenCalled()
    expect(rpcMock).toHaveBeenCalledWith('check_out_room', {
      p_room_id: 'room-1',
      p_payment_method: 'tarjeta',
      p_receipt_path: null,
      p_payment_reference: 'AB12345',
    })
  })

  it('uploads the receipt to the receipts bucket and sends the resulting path', async () => {
    rpcMock.mockClear()
    uploadMock.mockClear()
    const file = new File(['x'], 'comprobante.jpg', { type: 'image/jpeg' })
    await checkOutRoom('room-2', 'qr', { receipt: file, paymentReference: null })
    expect(uploadMock).toHaveBeenCalledTimes(1)
    const [path] = uploadMock.mock.calls[0] as [string, File, unknown]
    expect(path).toMatch(/^\d{4}\/[0-9a-f-]+\.jpg$/)
    expect(rpcMock).toHaveBeenCalledWith('check_out_room', expect.objectContaining({
      p_room_id: 'room-2',
      p_payment_method: 'qr',
      p_payment_reference: null,
    }))
    const rpcArgs = rpcMock.mock.calls[0][1] as { p_receipt_path: string }
    expect(rpcArgs.p_receipt_path).toBe(path)
  })

  it('surfaces the RPC error message unchanged', async () => {
    rpcMock.mockClear()
    uploadMock.mockClear()
    rpcMock.mockResolvedValueOnce({ data: null, error: { message: 'Caja no abierta' } })
    await expect(
      checkOutRoom('room-3', 'efectivo', { receipt: null, paymentReference: null }),
    ).rejects.toThrow('Caja no abierta')
  })
})
