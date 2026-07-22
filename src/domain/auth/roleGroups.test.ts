import { describe, expect, it } from 'vitest'
import { ANTICIPOS_ADMIN, DISCOUNT_APPROVAL, HOUSEKEEPING, OPERATIONS, SHARED } from './roleGroups'

describe('role group parity — reception_admin must mirror reception (REQ-4)', () => {
  it('OPERATIONS includes reception_admin whenever it includes reception', () => {
    expect(OPERATIONS).toContain('reception')
    expect(OPERATIONS).toContain('reception_admin')
  })

  it('SHARED includes reception_admin whenever it includes reception', () => {
    expect(SHARED).toContain('reception')
    expect(SHARED).toContain('reception_admin')
  })

  it('HOUSEKEEPING includes reception_admin whenever it includes reception', () => {
    expect(HOUSEKEEPING).toContain('reception')
    expect(HOUSEKEEPING).toContain('reception_admin')
  })
})

describe('DISCOUNT_APPROVAL — reception_admin-only, NOT plain reception', () => {
  it('includes root and reception_admin', () => {
    expect(DISCOUNT_APPROVAL).toContain('root')
    expect(DISCOUNT_APPROVAL).toContain('reception_admin')
  })

  it('excludes reception and accountant (queue visibility, not table read access)', () => {
    expect(DISCOUNT_APPROVAL).not.toContain('reception')
    expect(DISCOUNT_APPROVAL).not.toContain('accountant')
  })
})

describe('ANTICIPOS_ADMIN — reception_admin-only refund/modify surface, NOT plain reception', () => {
  it('includes root and reception_admin', () => {
    expect(ANTICIPOS_ADMIN).toContain('root')
    expect(ANTICIPOS_ADMIN).toContain('reception_admin')
  })

  it('excludes reception and accountant (record surface uses OPERATIONS, not this group)', () => {
    expect(ANTICIPOS_ADMIN).not.toContain('reception')
    expect(ANTICIPOS_ADMIN).not.toContain('accountant')
  })
})
