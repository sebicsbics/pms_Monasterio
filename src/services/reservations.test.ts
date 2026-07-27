import { describe, expect, it, vi } from 'vitest'

const rpcMock = vi.fn(async (..._args: unknown[]) => ({
  data: {} as unknown,
  error: null as { message: string } | null,
}))

vi.mock('./supabase', () => ({
  supabase: {
    rpc: (...args: unknown[]) => rpcMock(...args),
  },
}))

import { cancelReservation, rescheduleReservation } from './reservations'

describe('cancelReservation', () => {
  it('rejects a missing justification before calling the RPC', async () => {
    rpcMock.mockClear()
    await expect(cancelReservation('res-1', '   ')).rejects.toThrow(
      'La justificación es obligatoria',
    )
    expect(rpcMock).not.toHaveBeenCalled()
  })

  it('sends the trimmed reason in the RPC payload', async () => {
    rpcMock.mockClear()
    await cancelReservation('res-2', '  no vino  ')
    expect(rpcMock).toHaveBeenCalledWith('cancel_reservation', {
      p_reservation_id: 'res-2',
      p_reason: 'no vino',
    })
  })

  it('surfaces the RPC error message unchanged', async () => {
    rpcMock.mockResolvedValueOnce({
      data: null,
      error: { message: 'Solo se pueden cancelar reservas confirmadas (estado: checked_in)' },
    })
    await expect(cancelReservation('res-3', 'motivo')).rejects.toThrow(
      'Solo se pueden cancelar reservas confirmadas',
    )
  })
})

describe('rescheduleReservation', () => {
  it('rejects a missing justification before calling the RPC', async () => {
    rpcMock.mockClear()
    await expect(
      rescheduleReservation('res-1', '2026-08-01', '2026-08-03', ''),
    ).rejects.toThrow('La justificación es obligatoria')
    expect(rpcMock).not.toHaveBeenCalled()
  })

  it('rejects an out-of-order date range before calling the RPC', async () => {
    rpcMock.mockClear()
    await expect(
      rescheduleReservation('res-1', '2026-08-03', '2026-08-01', 'motivo'),
    ).rejects.toThrow('La fecha de salida debe ser posterior a la de entrada')
    expect(rpcMock).not.toHaveBeenCalled()
  })

  it('sends the new dates and trimmed reason in the RPC payload', async () => {
    rpcMock.mockClear()
    await rescheduleReservation('res-2', '2026-08-01', '2026-08-03', '  cambio de planes  ')
    expect(rpcMock).toHaveBeenCalledWith('reschedule_reservation', {
      p_reservation_id: 'res-2',
      p_check_in: '2026-08-01',
      p_check_out: '2026-08-03',
      p_reason: 'cambio de planes',
    })
  })

  it('surfaces the RPC error message unchanged', async () => {
    rpcMock.mockResolvedValueOnce({
      data: null,
      error: { message: 'La habitación no está disponible para esas fechas' },
    })
    await expect(
      rescheduleReservation('res-3', '2026-08-01', '2026-08-03', 'motivo'),
    ).rejects.toThrow('La habitación no está disponible para esas fechas')
  })
})
