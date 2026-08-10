import { describe, expect, it } from 'vitest'
import {
  ANTICIPOS_ADMIN,
  DISCOUNT_APPROVAL,
  FINANCE,
  FINANCE_STAFF,
  HOUSEKEEPING,
  OPERATIONS,
  SHARED,
  STAFF,
} from './roleGroups'

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

// El dueño ve la operación del hotel entera, pero no las pantallas que no
// le aportan nada: colas de aprobación que nunca va a resolver, el legajo
// del personal, la bitácora de accesos y su propio perfil (no es un
// empleado). Se fija acá para que un cambio de grupos no se lo devuelva
// ni se lo quite sin querer.
describe('owner — qué ve y qué no', () => {
  it('ve la operación y la analítica', () => {
    for (const group of [SHARED, OPERATIONS, HOUSEKEEPING, FINANCE]) {
      expect(group).toContain('owner')
    }
  })

  it('NO ve las colas de aprobación: no resuelve descuentos ni corrige anticipos', () => {
    expect(DISCOUNT_APPROVAL).not.toContain('owner')
    expect(ANTICIPOS_ADMIN).not.toContain('owner')
  })

  it('NO ve empleados, accesos ni su propio perfil', () => {
    expect(FINANCE_STAFF).not.toContain('owner')
    expect(STAFF).not.toContain('owner')
  })

  it('los grupos sin owner conservan al resto del personal', () => {
    for (const role of ['root', 'accountant'] as const) {
      expect(FINANCE_STAFF).toContain(role)
    }
    for (const role of ['root', 'accountant', 'reception', 'reception_admin'] as const) {
      expect(STAFF).toContain(role)
    }
  })
})
