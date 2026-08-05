import { describe, expect, it } from 'vitest'
import { CAJA_PAYMENT_METHODS, isCashMovement, type CashMovement } from './cash'

function movement(paymentMethod: string | null): CashMovement {
  return {
    id: 'm1',
    kind: 'income',
    category: 'cobro_habitacion',
    amountBs: 100,
    concept: null,
    receiptPath: null,
    paymentMethod,
    createdAt: '2026-08-05T10:00:00Z',
    voided: false,
    voidReason: null,
  }
}

describe('isCashMovement', () => {
  it('counts EFECTIVO as cash', () => {
    expect(isCashMovement(movement('EFECTIVO'))).toBe(true)
  })

  it('counts legacy movements without payment method as cash', () => {
    expect(isCashMovement(movement(null))).toBe(true)
  })

  it('excludes QR, deposit and card from the drawer', () => {
    expect(isCashMovement(movement('QR'))).toBe(false)
    expect(isCashMovement(movement('DEPOSITO'))).toBe(false)
    expect(isCashMovement(movement('TARJETA'))).toBe(false)
  })
})

describe('CAJA_PAYMENT_METHODS', () => {
  it('is exactly cash, deposit, card and QR', () => {
    expect([...CAJA_PAYMENT_METHODS].sort()).toEqual(
      ['DEPOSITO', 'EFECTIVO', 'QR', 'TARJETA'],
    )
  })
})
