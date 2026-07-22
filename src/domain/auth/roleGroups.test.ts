import { describe, expect, it } from 'vitest'
import { HOUSEKEEPING, OPERATIONS, SHARED } from './roleGroups'

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
