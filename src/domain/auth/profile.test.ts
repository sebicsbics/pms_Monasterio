import { describe, expect, it } from 'vitest'
import type { UserRole } from './profile'
import { ROLE_LABEL } from './profile'

describe('ROLE_LABEL', () => {
  it('has an entry for every UserRole member (exhaustiveness)', () => {
    const roles: UserRole[] = ['root', 'accountant', 'reception', 'reception_admin']
    for (const role of roles) {
      expect(ROLE_LABEL[role]).toBeTruthy()
    }
    expect(Object.keys(ROLE_LABEL)).toHaveLength(4)
  })

  it('gives reception_admin a distinct, non-empty Spanish label from reception', () => {
    expect(ROLE_LABEL.reception_admin).not.toBe('')
    expect(ROLE_LABEL.reception_admin).not.toBe(ROLE_LABEL.reception)
  })
})
