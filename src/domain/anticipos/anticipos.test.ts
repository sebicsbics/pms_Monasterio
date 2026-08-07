import { describe, expect, it } from 'vitest'
import {
  anticipoLabel,
  isCorrectable,
  userFacingAnticipoError,
  type AnticipoListItem,
} from './anticipos'

function item(patch: Partial<AnticipoListItem> = {}): AnticipoListItem {
  return {
    id: 'a1',
    reservationId: 'r1',
    roomNumber: '15',
    guestName: 'JAIME DUM',
    checkInDate: '2026-08-10',
    checkOutDate: '2026-08-12',
    reservationStatus: 'confirmed',
    amountBs: 900,
    paymentMethod: 'QR',
    status: 'active',
    receiptPath: null,
    paymentReference: null,
    receivedByName: 'Romina',
    receivedAt: '2026-08-07T00:10:02Z',
    notes: null,
    ...patch,
  }
}

describe('anticipoLabel', () => {
  it('identifies the anticipo by room, guest and amount — not by uuid', () => {
    expect(anticipoLabel(item())).toBe('Hab. 15 · JAIME DUM · Bs 900.00 · QR')
  })

  it('always shows two decimals so the amounts line up in the dropdown', () => {
    expect(anticipoLabel(item({ amountBs: 450 }))).toContain('Bs 450.00')
    expect(anticipoLabel(item({ amountBs: 1440.5 }))).toContain('Bs 1440.50')
  })
})

describe('isCorrectable', () => {
  it('allows correcting an active anticipo', () => {
    expect(isCorrectable(item())).toBe(true)
  })

  // modify_anticipo rechaza los 'forfeited', así que ofrecerlos en el
  // selector sería ofrecer una acción que siempre falla.
  it('refuses a forfeited one (its reservation was cancelled)', () => {
    expect(
      isCorrectable(item({ status: 'forfeited', reservationStatus: 'cancelled' })),
    ).toBe(false)
  })
})

describe('userFacingAnticipoError', () => {
  it('turns the raw closed-register error into an actionable message', () => {
    expect(userFacingAnticipoError('No hay una caja abierta')).toMatch(/Abrí la caja/)
  })

  it('leaves any other message untouched', () => {
    expect(userFacingAnticipoError('Reserva no encontrada')).toBe('Reserva no encontrada')
  })
})
