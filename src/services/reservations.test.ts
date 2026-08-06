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

import { cancelReservation, createReservation, rescheduleReservation } from './reservations'

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

// Regresión: create_reservation dejó de recibir p_num_guests al sacarlo de
// create_bulk_reservation con un reemplazo de texto sin límite de
// ocurrencias. TypeScript no lo vio —el payload de una RPC es un objeto
// sin tipar— y PostgREST falló recién en runtime con "Could not find the
// function ... in the schema cache". El payload se afirma completo: si
// alguien vuelve a quitar una clave, el test cae acá y no en producción.
describe('createReservation', () => {
  it('sends every parameter the create_reservation RPC declares', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({ data: 'res-1', error: null })
    await createReservation({
      roomId: 'room-1',
      roomTypeId: 'type-1',
      firstName: 'Ana',
      lastName: 'Pérez',
      phone: '555',
      email: 'ana@example.com',
      checkIn: '2026-08-06',
      checkOut: '2026-08-07',
      numGuests: 2,
      method: 'phone',
    })
    expect(rpcMock).toHaveBeenCalledWith('create_reservation', {
      p_room_id: 'room-1',
      p_room_type_id: 'type-1',
      p_first_name: 'Ana',
      p_last_name: 'Pérez',
      p_phone: '555',
      p_email: 'ana@example.com',
      p_check_in: '2026-08-06',
      p_check_out: '2026-08-07',
      p_num_guests: 2,
      p_method: 'phone',
      p_rate_bs: null,
      p_reason: null,
    })
  })
})
