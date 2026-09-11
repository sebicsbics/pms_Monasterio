import { describe, expect, it, vi } from 'vitest'

const fromMock = vi.fn()
const rpcMock = vi.fn()

vi.mock('./supabase', () => ({
  supabase: {
    from: (...args: unknown[]) => fromMock(...args),
    rpc: (...args: unknown[]) => rpcMock(...args),
  },
}))

import { changeRoom, fetchStaySegments, modifyStayDates } from './staySegments'

// Cubre la traducción de errores crudos de Postgres a mensajes de usuario
// (toUserMessage, dbErrors.ts) -- el mismo patrón que arrivals.ts/checkin.ts.
// Antes, estas tres funciones tiraban error.message directo, así que un
// solapamiento (EXCLUDE 23P01) llegaba a la UI en inglés/crudo.
describe('staySegments error translation', () => {
  it('fetchStaySegments translates overlap errors via toUserMessage', async () => {
    const chain = {
      select: () => chain,
      eq: () => chain,
      order: () =>
        Promise.resolve({
          data: null,
          error: {
            code: '23P01',
            message: 'conflicting key value violates exclusion constraint "reservation_guests_no_overlap"',
          },
        }),
    }
    fromMock.mockReturnValue(chain)

    await expect(fetchStaySegments('res-1')).rejects.toThrow(
      'Esta persona ya está alojada en otra habitación en esas fechas.',
    )
  })

  it('modifyStayDates translates overlap errors via toUserMessage', async () => {
    rpcMock.mockResolvedValue({
      data: null,
      error: {
        code: '23P01',
        message: 'conflicting key value violates exclusion constraint "reservation_guests_no_overlap"',
      },
    })

    await expect(modifyStayDates('room-1', '2026-09-20', null, 'motivo')).rejects.toThrow(
      'Esta persona ya está alojada en otra habitación en esas fechas.',
    )
  })

  it('changeRoom translates overlap errors via toUserMessage', async () => {
    rpcMock.mockResolvedValue({
      data: null,
      error: {
        code: '23P01',
        message: 'conflicting key value violates exclusion constraint "reservation_guests_no_overlap"',
      },
    })

    await expect(
      changeRoom({
        roomId: 'room-1',
        newRoomId: 'room-2',
        newRoomTypeId: 'type-1',
        rateBs: 100,
        fromDate: null,
        reason: 'motivo',
      }),
    ).rejects.toThrow('Esta persona ya está alojada en otra habitación en esas fechas.')
  })

  it('non-overlap errors still pass their original message through', async () => {
    rpcMock.mockResolvedValue({
      data: null,
      error: { message: 'La fecha de salida debe ser posterior a la de entrada' },
    })

    await expect(modifyStayDates('room-1', '2026-09-20', null, 'motivo')).rejects.toThrow(
      'La fecha de salida debe ser posterior a la de entrada',
    )
  })
})
