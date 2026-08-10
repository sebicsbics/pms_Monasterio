import { describe, expect, it } from 'vitest'
import type { UserRole } from './profile'
import { canWrite, hasAccess, READ_ONLY_ROLES, ROLE_LABEL } from './profile'

describe('ROLE_LABEL', () => {
  it('has an entry for every UserRole member (exhaustiveness)', () => {
    const roles: UserRole[] = [
      'root', 'accountant', 'reception', 'reception_admin', 'owner', 'pending',
    ]
    for (const role of roles) {
      expect(ROLE_LABEL[role]).toBeTruthy()
    }
    expect(Object.keys(ROLE_LABEL)).toHaveLength(6)
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

  // Cuenta recién registrada desde internet: no escribe ni ve nada.
  it('blocks a pending account', () => {
    expect(canWrite('pending')).toBe(false)
  })

  it('blocks an unknown or absent role instead of assuming write access', () => {
    expect(canWrite(null)).toBe(false)
    expect(canWrite(undefined)).toBe(false)
  })
})

describe('hasAccess', () => {
  it('lets every assigned role in', () => {
    for (const role of ['root', 'accountant', 'reception', 'reception_admin', 'owner'] as UserRole[]) {
      expect(hasAccess(role)).toBe(true)
    }
  })

  it('keeps a pending account out of the whole system', () => {
    expect(hasAccess('pending')).toBe(false)
  })

  it('keeps out a session with no role rather than assuming access', () => {
    expect(hasAccess(null)).toBe(false)
    expect(hasAccess(undefined)).toBe(false)
  })
})
