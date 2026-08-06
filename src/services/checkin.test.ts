import { describe, expect, it, vi } from 'vitest'

const rpcMock = vi.fn(async (..._args: unknown[]) => ({
  data: 100 as number | null,
  error: null as { message: string } | null,
}))
const uploadMock = vi.fn(async (..._args: unknown[]) => ({
  error: null as { message: string } | null,
}))
// rate_discount_requests siempre "sin pendiente" por defecto — los tests
// de este archivo no ejercitan el flujo de aprobación, solo verifican el
// payload enviado a cada RPC (ver rateDiscountRequestsService.test.ts).
const maybeSingleMock = vi.fn(async () => ({ data: null, error: null }))

vi.mock('./supabase', () => ({
  supabase: {
    rpc: (...args: unknown[]) => rpcMock(...args),
    storage: {
      from: () => ({
        upload: (...args: unknown[]) => uploadMock(...args),
      }),
    },
    from: () => ({
      select: () => ({
        eq: () => ({
          eq: () => ({
            order: () => ({
              limit: () => ({
                maybeSingle: () => maybeSingleMock(),
              }),
            }),
          }),
        }),
      }),
    }),
  },
}))

import { checkOutRoom, overrideReservationRate, walkInCheckIn } from './checkin'

describe('checkOutRoom', () => {
  it('sends payment_reference (no receipt) in the check_out_room RPC payload', async () => {
    rpcMock.mockClear()
    uploadMock.mockClear()
    await checkOutRoom('room-1', 'TARJETA', {
      receipt: null,
      paymentReference: 'AB12345',
    })
    expect(uploadMock).not.toHaveBeenCalled()
    expect(rpcMock).toHaveBeenCalledWith('check_out_room', {
      p_room_id: 'room-1',
      p_payment_method: 'TARJETA',
      p_receipt_path: null,
      p_payment_reference: 'AB12345',
      p_receivable_account_id: null,
      p_cash_bs: null,
      p_non_cash_bs: null,
      p_non_cash_method: null,
    })
  })

  it('uploads the receipt to the receipts bucket and sends the resulting path', async () => {
    rpcMock.mockClear()
    uploadMock.mockClear()
    const file = new File(['x'], 'comprobante.jpg', { type: 'image/jpeg' })
    await checkOutRoom('room-2', 'QR', { receipt: file, paymentReference: null })
    expect(uploadMock).toHaveBeenCalledTimes(1)
    const [path] = uploadMock.mock.calls[0] as [string, File, unknown]
    expect(path).toMatch(/^\d{4}\/[0-9a-f-]+\.jpg$/)
    expect(rpcMock).toHaveBeenCalledWith('check_out_room', expect.objectContaining({
      p_room_id: 'room-2',
      p_payment_method: 'QR',
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
      checkOutRoom('room-3', 'EFECTIVO', { receipt: null, paymentReference: null }),
    ).rejects.toThrow('Caja no abierta')
  })
})

describe('walkInCheckIn', () => {
  const baseData = {
    roomId: 'room-1',
    roomTypeId: 'type-1',
    firstName: 'Ana',
    lastName: 'Pérez',
    document: '12345',
    email: '',
    birthDate: '',
    countryCode: 'BOL',
    city: 'La Paz',
    wantsOffers: false,
    nights: 2,
  }

  it('sends null p_rate_bs and p_rate_reason when no custom rate is given', async () => {
    rpcMock.mockClear()
    await walkInCheckIn(baseData)
    expect(rpcMock).toHaveBeenCalledWith('walk_in_check_in_with_guests', expect.objectContaining({
      p_room_id: 'room-1',
      p_room_type_id: 'type-1',
      p_rate_bs: null,
      p_rate_reason: null,
      p_companions: [],
    }))
  })

  it('sends the custom rate and reason when the receptionist overrides the price', async () => {
    rpcMock.mockClear()
    await walkInCheckIn({
      ...baseData,
      rateBs: 90,
      rateReason: 'Última habitación disponible, se vende con descuento',
    })
    expect(rpcMock).toHaveBeenCalledWith('walk_in_check_in_with_guests', expect.objectContaining({
      p_rate_bs: 90,
      p_rate_reason: 'Última habitación disponible, se vende con descuento',
    }))
  })

  it('maps and sends companions with the walk-in payload', async () => {
    rpcMock.mockClear()
    await walkInCheckIn({
      ...baseData,
      companions: [
        { firstName: 'Luis', lastName: 'Gómez', isMinor: false, document: 'Z1', birthDate: '', countryCode: 'bol', city: 'Oruro', originCity: 'Potosí', travelPurpose: 'Negocios', occupation: 'Comerciante', transportMeans: 'Avión' },
        { firstName: '', lastName: '', isMinor: false, document: '', birthDate: '', countryCode: '', city: '', originCity: '', travelPurpose: '', occupation: '', transportMeans: '' },
      ],
    })
    const payload = rpcMock.mock.calls[0][1] as { p_companions: unknown[] }
    expect(payload.p_companions).toEqual([
      { first_name: 'Luis', last_name: 'Gómez', is_minor: false, document: 'Z1', birth_date: '', country_code: 'BOL', city: 'Oruro', origin_city: 'Potosí', travel_purpose: 'Negocios', occupation: 'Comerciante', transport_means: 'Avión' },
    ])
  })

  it('surfaces the RPC error message unchanged', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({ data: null, error: { message: 'La justificación es obligatoria para cambiar la tarifa' } })
    await expect(
      walkInCheckIn({ ...baseData, rateBs: 90, rateReason: '' }),
    ).rejects.toThrow('La justificación es obligatoria para cambiar la tarifa')
  })
})

describe('overrideReservationRate', () => {
  it('rejects a missing justification before calling the RPC', async () => {
    rpcMock.mockClear()
    await expect(
      overrideReservationRate('res-1', 150, '   '),
    ).rejects.toThrow('La justificación es obligatoria')
    expect(rpcMock).not.toHaveBeenCalled()
  })

  it('rejects a non-positive rate before calling the RPC', async () => {
    rpcMock.mockClear()
    await expect(
      overrideReservationRate('res-1', 0, 'Descuento autorizado'),
    ).rejects.toThrow('La tarifa debe ser un monto positivo')
    expect(rpcMock).not.toHaveBeenCalled()
  })

  it('sends the trimmed reason and new rate in the RPC payload', async () => {
    rpcMock.mockClear()
    await overrideReservationRate('res-2', 150, '  Última habitación disponible  ')
    expect(rpcMock).toHaveBeenCalledWith('override_reservation_rate', {
      p_reservation_id: 'res-2',
      p_new_rate: 150,
      p_reason: 'Última habitación disponible',
    })
  })

  it('surfaces the RPC error message unchanged', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({ data: null, error: { message: 'No autorizado para cambiar la tarifa' } })
    await expect(
      overrideReservationRate('res-3', 150, 'Motivo válido'),
    ).rejects.toThrow('No autorizado para cambiar la tarifa')
  })
})
