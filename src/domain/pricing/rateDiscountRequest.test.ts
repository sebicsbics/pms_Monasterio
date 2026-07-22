import { describe, expect, it } from 'vitest'
import { canApproveDiscountRequests } from './rateDiscountRequest'

describe('canApproveDiscountRequests — approval queue visibility gate', () => {
  it('allows root', () => {
    expect(canApproveDiscountRequests('root')).toBe(true)
  })

  it('allows reception_admin', () => {
    expect(canApproveDiscountRequests('reception_admin')).toBe(true)
  })

  it('denies reception (can read the table but not approve/reject)', () => {
    expect(canApproveDiscountRequests('reception')).toBe(false)
  })

  it('denies accountant', () => {
    expect(canApproveDiscountRequests('accountant')).toBe(false)
  })

  it('denies null/undefined role', () => {
    expect(canApproveDiscountRequests(null)).toBe(false)
    expect(canApproveDiscountRequests(undefined)).toBe(false)
  })
})
