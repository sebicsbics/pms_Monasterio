import { describe, expect, it, vi } from 'vitest'

const rpcMock = vi.fn(async (..._args: unknown[]) => ({
  data: null as unknown,
  error: null as { message: string; code?: string } | null,
}))

interface FolioMaybeSingleResult {
  data: unknown
  error: { message: string } | null
}
const maybeSingleMock = vi.fn(
  async (): Promise<FolioMaybeSingleResult> => ({ data: null, error: null }),
)

vi.mock('./supabase', () => ({
  supabase: {
    rpc: (...args: unknown[]) => rpcMock(...args),
    from: () => ({
      select: () => ({
        eq: () => ({
          eq: () => ({
            maybeSingle: () => maybeSingleMock(),
          }),
        }),
      }),
    }),
  },
}))

import { addFolioCharge, addFolioProductCharge, fetchFolio } from './folio'

// feat/booking-17-checkout-enforcement: fetchFolio lee bookings.payer_mode
// vía el embed de reservations, porque el check-out de una habitación
// institucional cobra solo extras (decisión #391) -- si el preview
// siguiera sumando total_amount_bs, mostraría un monto que el RPC nunca
// va a cobrar.
describe('fetchFolio', () => {
  it('client: el total/saldo del preview son solo los extras, no el precio de la habitación', async () => {
    maybeSingleMock.mockResolvedValueOnce({
      data: {
        reservations: {
          id: 'res-1',
          total_amount_bs: 500,
          room_types: { name: 'Doble' },
          anticipos: [],
          bookings: { payer_mode: 'client' },
        },
        folio_charges: [{ id: 'c1', description: 'Minibar', amount_bs: 80 }],
      },
      error: null,
    })

    const folio = await fetchFolio('room-1')

    expect(folio?.totalBs).toBe(80)
    expect(folio?.balanceDueBs).toBe(80)
  })

  it('each_stay: sigue sumando habitación + extras menos anticipos (regresión)', async () => {
    maybeSingleMock.mockResolvedValueOnce({
      data: {
        reservations: {
          id: 'res-2',
          total_amount_bs: 500,
          room_types: { name: 'Doble' },
          anticipos: [{ amount_bs: 100, status: 'active' }],
          bookings: { payer_mode: 'each_stay' },
        },
        folio_charges: [{ id: 'c2', description: 'Minibar', amount_bs: 50 }],
      },
      error: null,
    })

    const folio = await fetchFolio('room-2')

    expect(folio?.totalBs).toBe(550)
    expect(folio?.balanceDueBs).toBe(450)
  })

  it('sin booking embebido: se asume each_stay por defecto (regresión, no revienta)', async () => {
    maybeSingleMock.mockResolvedValueOnce({
      data: {
        reservations: {
          id: 'res-3',
          total_amount_bs: 500,
          room_types: { name: 'Doble' },
          anticipos: [],
          bookings: null,
        },
        folio_charges: [],
      },
      error: null,
    })

    const folio = await fetchFolio('room-3')

    expect(folio?.totalBs).toBe(500)
  })
})

// Ambas RPC exigen el consumidor (change: reservation-booker-vs-guest,
// PR5) -- el cargo debe quedar atribuido a quién realmente lo consumió,
// no solo a quién lo cargó (created_by, que la RPC completa sola con
// auth.uid()).
describe('addFolioCharge', () => {
  it('sends the consumer person id to the RPC', async () => {
    rpcMock.mockClear()
    await addFolioCharge('room-1', 'Restaurante', 80, 'person-1')
    expect(rpcMock).toHaveBeenCalledWith('add_folio_charge', {
      p_room_id: 'room-1',
      p_description: 'Restaurante',
      p_amount: 80,
      p_consumer_person_id: 'person-1',
    })
  })

  it('translates the RPC error via dbErrors', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({
      data: null,
      error: { message: 'El huésped indicado no está alojado en esta habitación' },
    })
    await expect(addFolioCharge('room-1', 'Spa', 50, 'outsider')).rejects.toThrow(
      'El huésped indicado no está alojado en esta habitación',
    )
  })
})

describe('addFolioProductCharge', () => {
  it('sends the consumer person id to the RPC', async () => {
    rpcMock.mockClear()
    await addFolioProductCharge('room-1', 'product-1', 2, 'person-1')
    expect(rpcMock).toHaveBeenCalledWith('add_folio_product_charge', {
      p_room_id: 'room-1',
      p_product_id: 'product-1',
      p_quantity: 2,
      p_consumer_person_id: 'person-1',
    })
  })
})

// Regresión: lo pagado AL CONSUMIR (ej. spa que se cobra en el momento)
// se registra en la sesión de caja abierta (add_cash_movement, ver
// src/services/cash.ts), NUNCA como un debito de folio_charges -- si no,
// el check-out lo cobraría dos veces. folio.ts y cash.ts no se importan
// entre sí: ninguna llamada de folio.ts termina en un movimiento de caja.
describe('pay-at-consumption stays cash-session income only (regression)', () => {
  it('addFolioCharge only ever calls the folio RPC, never a cash-session RPC', async () => {
    rpcMock.mockClear()
    await addFolioCharge('room-1', 'Spa (pagado al consumir)', 30, 'person-1')
    expect(rpcMock).toHaveBeenCalledTimes(1)
    expect(rpcMock.mock.calls[0][0]).toBe('add_folio_charge')
    expect(rpcMock.mock.calls[0][0]).not.toBe('add_cash_movement')
  })
})
