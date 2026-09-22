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

import {
  cancelReservation,
  createBulkReservation,
  createReservation,
  rescheduleReservation,
} from './reservations'

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
  it('sends every parameter the create_reservation RPC declares, defaulting p_contact_stays to true', async () => {
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
      p_contact_stays: true,
      p_payer_mode: 'each_stay',
      p_rate_mode: 'room',
      p_agreed_unit_price_bs: null,
      p_receivable_account_id: null,
      p_new_account_name: null,
      p_new_account_kind: null,
      p_new_account_contact: null,
      p_new_account_notes: null,
      p_is_courtesy: false,
      p_courtesy_reason: null,
    })
  })

  it('forwards payer_mode=client with rate_mode=person and the new-account fields', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({ data: 'res-3', error: null })
    await createReservation({
      roomId: 'room-1',
      roomTypeId: 'type-1',
      firstName: 'Hotel',
      lastName: 'ABC',
      phone: '555',
      email: 'contacto@hotelabc.example',
      checkIn: '2026-08-06',
      checkOut: '2026-08-07',
      numGuests: 3,
      method: 'phone',
      payerMode: 'client',
      rateMode: 'person',
      agreedUnitPriceBs: 300,
      newAccountName: 'Hotel ABC',
      newAccountKind: 'empresa',
      newAccountContact: 'contacto@hotelabc.example',
      isCourtesy: true,
      courtesyReason: 'Cortesía de gerencia',
    })
    expect(rpcMock).toHaveBeenCalledWith('create_reservation', {
      p_room_id: 'room-1',
      p_room_type_id: 'type-1',
      p_first_name: 'Hotel',
      p_last_name: 'ABC',
      p_phone: '555',
      p_email: 'contacto@hotelabc.example',
      p_check_in: '2026-08-06',
      p_check_out: '2026-08-07',
      p_num_guests: 3,
      p_method: 'phone',
      p_rate_bs: null,
      p_reason: null,
      p_contact_stays: true,
      p_payer_mode: 'client',
      p_rate_mode: 'person',
      p_agreed_unit_price_bs: 300,
      p_receivable_account_id: null,
      p_new_account_name: 'Hotel ABC',
      p_new_account_kind: 'empresa',
      p_new_account_contact: 'contacto@hotelabc.example',
      p_new_account_notes: null,
      p_is_courtesy: true,
      p_courtesy_reason: 'Cortesía de gerencia',
    })
  })

  it('forwards contactStays: false when the caller says the contact will not stay', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({ data: 'res-2', error: null })
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
      contactStays: false,
    })
    expect(rpcMock).toHaveBeenCalledWith(
      'create_reservation',
      expect.objectContaining({ p_contact_stays: false }),
    )
  })
})

describe('createBulkReservation', () => {
  it('omits occupants for rooms that have none preloaded', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({ data: { created: [], failed: [] }, error: null })
    await createBulkReservation({
      rooms: [{ roomId: 'room-1', roomTypeId: 'type-1', numGuests: 2 }],
      firstName: 'Org',
      lastName: 'Anizador',
      phone: '555',
      email: '',
      checkIn: '2026-08-06',
      checkOut: '2026-08-07',
      method: 'phone',
    })
    const payload = rpcMock.mock.calls[0][1] as { p_rooms: Record<string, unknown>[] }
    expect(payload.p_rooms).toEqual([
      {
        room_id: 'room-1',
        room_type_id: 'type-1',
        num_guests: 2,
        occupants: [],
        is_courtesy: false,
        courtesy_reason: null,
        rate_bs: null,
      },
    ])
  })

  it('sends preloaded occupants per room, holder first then companions', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({ data: { created: [], failed: [] }, error: null })
    await createBulkReservation({
      rooms: [
        {
          roomId: 'room-1',
          roomTypeId: 'type-1',
          numGuests: 2,
          occupants: [
            { firstName: 'Juan', lastName: 'Titular', document: '123' },
            { firstName: 'Mari', lastName: 'Acompañante' },
          ],
        },
      ],
      firstName: 'Org',
      lastName: 'Anizador',
      phone: '555',
      email: '',
      checkIn: '2026-08-06',
      checkOut: '2026-08-07',
      method: 'phone',
    })
    const payload = rpcMock.mock.calls[0][1] as { p_rooms: Record<string, unknown>[] }
    expect(payload.p_rooms).toEqual([
      {
        room_id: 'room-1',
        room_type_id: 'type-1',
        num_guests: 2,
        occupants: [
          { first_name: 'Juan', last_name: 'Titular', document: '123' },
          { first_name: 'Mari', last_name: 'Acompañante', document: null },
        ],
        is_courtesy: false,
        courtesy_reason: null,
        rate_bs: null,
      },
    ])
  })

  it('sends every booking-level payer/rate/account parameter the RPC declares, defaulting to each_stay', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({ data: { created: [], failed: [] }, error: null })
    await createBulkReservation({
      rooms: [{ roomId: 'room-1', roomTypeId: 'type-1', numGuests: 2 }],
      firstName: 'Org',
      lastName: 'Anizador',
      phone: '555',
      email: '',
      checkIn: '2026-08-06',
      checkOut: '2026-08-07',
      method: 'phone',
    })
    expect(rpcMock).toHaveBeenCalledWith('create_bulk_reservation', {
      p_rooms: [
        {
          room_id: 'room-1',
          room_type_id: 'type-1',
          num_guests: 2,
          occupants: [],
          is_courtesy: false,
          courtesy_reason: null,
          rate_bs: null,
        },
      ],
      p_first_name: 'Org',
      p_last_name: 'Anizador',
      p_phone: '555',
      p_email: '',
      p_check_in: '2026-08-06',
      p_check_out: '2026-08-07',
      p_method: 'phone',
      p_rate_bs: null,
      p_reason: null,
      p_payer_mode: 'each_stay',
      p_rate_mode: 'room',
      p_agreed_unit_price_bs: null,
      p_receivable_account_id: null,
      p_new_account_name: null,
      p_new_account_kind: null,
      p_new_account_contact: null,
      p_new_account_notes: null,
    })
  })

  // sdd/per-room-rate-in-bulk: el precio pactado es una propiedad de CADA
  // habitación, no de la reserva completa. p_rate_bs booking-level ya NO
  // se envía desde este servicio (siempre null) -- cada habitación trae
  // el suyo (o ninguno) en p_rooms[].rate_bs.
  it('forwards a different rate_bs per room and never sends a booking-level p_rate_bs', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({ data: { created: [], failed: [] }, error: null })
    await createBulkReservation({
      rooms: [
        { roomId: 'room-1', roomTypeId: 'type-1', numGuests: 2, rateBs: 400 },
        { roomId: 'room-2', roomTypeId: 'type-2', numGuests: 1, rateBs: 300 },
        { roomId: 'room-3', roomTypeId: 'type-3', numGuests: 1 },
      ],
      firstName: 'Precio',
      lastName: 'PorHabitacion',
      phone: '555',
      email: '',
      checkIn: '2026-08-06',
      checkOut: '2026-08-08',
      method: 'phone',
      reason: 'Convenio institucional negociado',
    })
    const payload = rpcMock.mock.calls[0][1] as {
      p_rooms: Record<string, unknown>[]
      p_rate_bs: unknown
      p_reason: unknown
    }
    expect(payload.p_rooms.map((r) => r.rate_bs)).toEqual([400, 300, null])
    expect(payload.p_rate_bs).toBeNull()
    expect(payload.p_reason).toBe('Convenio institucional negociado')
  })

  it('forwards payer_mode=client with rate_mode=person, a new account and per-room courtesy', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({ data: { created: [], failed: [] }, error: null })
    await createBulkReservation({
      rooms: [
        { roomId: 'room-1', roomTypeId: 'type-1', numGuests: 4 },
        {
          roomId: 'room-2',
          roomTypeId: 'type-2',
          numGuests: 1,
          isCourtesy: true,
          courtesyReason: 'Cortesía de gerencia',
        },
      ],
      firstName: 'Hotel',
      lastName: 'ABC',
      phone: '555',
      email: 'contacto@hotelabc.example',
      checkIn: '2026-08-06',
      checkOut: '2026-08-08',
      method: 'phone',
      payerMode: 'client',
      rateMode: 'person',
      agreedUnitPriceBs: 300,
      newAccountName: 'Hotel ABC',
      newAccountKind: 'empresa',
      newAccountContact: 'contacto@hotelabc.example',
    })
    expect(rpcMock).toHaveBeenCalledWith('create_bulk_reservation', {
      p_rooms: [
        {
          room_id: 'room-1',
          room_type_id: 'type-1',
          num_guests: 4,
          occupants: [],
          is_courtesy: false,
          courtesy_reason: null,
          rate_bs: null,
        },
        {
          room_id: 'room-2',
          room_type_id: 'type-2',
          num_guests: 1,
          occupants: [],
          is_courtesy: true,
          courtesy_reason: 'Cortesía de gerencia',
          rate_bs: null,
        },
      ],
      p_first_name: 'Hotel',
      p_last_name: 'ABC',
      p_phone: '555',
      p_email: 'contacto@hotelabc.example',
      p_check_in: '2026-08-06',
      p_check_out: '2026-08-08',
      p_method: 'phone',
      p_rate_bs: null,
      p_reason: null,
      p_payer_mode: 'client',
      p_rate_mode: 'person',
      p_agreed_unit_price_bs: 300,
      p_receivable_account_id: null,
      p_new_account_name: 'Hotel ABC',
      p_new_account_kind: 'empresa',
      p_new_account_contact: 'contacto@hotelabc.example',
      p_new_account_notes: null,
    })
  })

  // Regresión (feat/booking-12-contract-bulk-atomicity): antes de este
  // slice, un `payer_mode='client'` con una habitación fallida SIEMPRE
  // devolvía `{ data, error: null }` (best-effort, la falla quedaba en
  // `failed[]`). Desde este slice la RPC puede RELANZAR en vez de eso
  // (all-or-nothing) -- Supabase entonces resuelve con `{ data: null,
  // error }`. createBulkReservation ya maneja esta forma genéricamente
  // (mismo `if (error) throw new Error(toUserMessage(error))` que usan
  // cancelReservation/rescheduleReservation, ver líneas 39-47/78-86 de
  // este archivo) -- no hizo falta tocar el servicio, este test sólo
  // deja la regresión bajo cobertura explícita para bulk también.
  it('surfaces the RPC error message unchanged when a client booking room fails atomically', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({
      data: null,
      error: { message: 'La habitación ya no está disponible para esas fechas' },
    })
    await expect(
      createBulkReservation({
        rooms: [{ roomId: 'room-1', roomTypeId: 'type-1', numGuests: 2 }],
        firstName: 'Hotel',
        lastName: 'ABC',
        phone: '555',
        email: 'contacto@hotelabc.example',
        checkIn: '2026-08-06',
        checkOut: '2026-08-08',
        method: 'phone',
        payerMode: 'client',
        receivableAccountId: 'account-1',
      }),
    ).rejects.toThrow('La habitación ya no está disponible para esas fechas')
  })
})
