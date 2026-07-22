import { describe, expect, it } from 'vitest'
import { canEditRate } from './rateGates'

describe('canEditRate — money-adjacent gate (REQ-2/REQ-4, not a folio-write RPC)', () => {
  it('allows root', () => {
    expect(canEditRate('root')).toBe(true)
  })

  it('allows reception', () => {
    expect(canEditRate('reception')).toBe(true)
  })

  it('allows reception_admin (write parity with reception)', () => {
    expect(canEditRate('reception_admin')).toBe(true)
  })

  it('denies accountant', () => {
    expect(canEditRate('accountant')).toBe(false)
  })

  it('denies null/undefined role', () => {
    expect(canEditRate(null)).toBe(false)
    expect(canEditRate(undefined)).toBe(false)
  })
})
