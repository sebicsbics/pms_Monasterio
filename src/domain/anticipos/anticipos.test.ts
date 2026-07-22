import { describe, expect, it } from 'vitest'
import { canRefund, nextStatus, remainingBalance, userFacingAnticipoError } from './anticipos'

describe('remainingBalance', () => {
  it('computes amount minus refunded amount', () => {
    expect(remainingBalance({ amountBs: 100, refundedAmountBs: 60 })).toBe(40)
  })

  it('returns the full amount when nothing has been refunded', () => {
    expect(remainingBalance({ amountBs: 250, refundedAmountBs: 0 })).toBe(250)
  })
})

describe('canRefund — over-refund guard (pure, no DB call)', () => {
  it('rejects a refund that exceeds the remaining balance', () => {
    expect(canRefund({ amountBs: 100, refundedAmountBs: 60 }, 41)).toBe(false)
  })

  it('accepts a refund that equals exactly the remaining balance (full refund)', () => {
    expect(canRefund({ amountBs: 100, refundedAmountBs: 60 }, 40)).toBe(true)
  })

  it('accepts a partial refund below the remaining balance', () => {
    expect(canRefund({ amountBs: 100, refundedAmountBs: 0 }, 40)).toBe(true)
  })

  it('rejects a zero or negative refund amount', () => {
    expect(canRefund({ amountBs: 100, refundedAmountBs: 0 }, 0)).toBe(false)
    expect(canRefund({ amountBs: 100, refundedAmountBs: 0 }, -5)).toBe(false)
  })
})

describe('nextStatus — status transition (active -> partially_refunded -> refunded)', () => {
  it('returns partially_refunded when the refund does not cover the remaining balance', () => {
    expect(nextStatus({ amountBs: 100, refundedAmountBs: 0 }, 40)).toBe('partially_refunded')
  })

  it('returns refunded when the refund covers exactly the remaining balance', () => {
    expect(nextStatus({ amountBs: 100, refundedAmountBs: 60 }, 40)).toBe('refunded')
  })

  it('returns refunded on a full refund from active status', () => {
    expect(nextStatus({ amountBs: 100, refundedAmountBs: 0 }, 100)).toBe('refunded')
  })
})

describe('userFacingAnticipoError — translates raw RPC errors to actionable messages', () => {
  it('translates the closed-register error into an "open the register" message', () => {
    expect(userFacingAnticipoError('No hay una caja abierta')).toBe(
      'No hay una caja abierta. Abrí la caja antes de registrar o reembolsar un anticipo.',
    )
  })

  it('passes through unrelated error messages unchanged', () => {
    expect(userFacingAnticipoError('Anticipo no encontrado')).toBe('Anticipo no encontrado')
  })
})
