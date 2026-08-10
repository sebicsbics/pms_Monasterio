import { describe, expect, it } from 'vitest'
import type { UserRole } from './profile'
import { canWrite, READ_ONLY_ROLES, ROLE_LABEL } from './profile'

describe('ROLE_LABEL', () => {
  it('has an entry for every UserRole member (exhaustiveness)', () => {
    const roles: UserRole[] = [
      'root', 'accountant', 'reception', 'reception_admin', 'owner',
    ]
    for (const role of roles) {
      expect(ROLE_LABEL[role]).toBeTruthy()
    }
    expect(Object.keys(ROLE_LABEL)).toHaveLength(5)
  })

  it('gives reception_admin a distinct, non-empty Spanish label from reception', () => {
    expect(ROLE_LABEL.reception_admin).not.toBe('')
    expect(ROLE_LABEL.reception_admin).not.toBe(ROLE_LABEL.reception)
  })
})

describe('canWrite', () => {
  it('lets every operational role write', () => {
    for (const role of ['root', 'accountant', 'reception', 'reception_admin'] as UserRole[]) {
      expect(canWrite(role)).toBe(true)
    }
  })

  // El dueño del hotel ve todo pero pide a root cualquier cambio. La
  // barrera real está en la base; esto sólo evita que choque con errores.
  it('blocks owner', () => {
    expect(canWrite('owner')).toBe(false)
    expect(READ_ONLY_ROLES).toContain('owner')
  })

  it('blocks an unknown or absent role instead of assuming write access', () => {
    expect(canWrite(null)).toBe(false)
    expect(canWrite(undefined)).toBe(false)
  })
})
