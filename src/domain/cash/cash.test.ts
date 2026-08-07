import { describe, expect, it } from 'vitest'
import {
  CAJA_PAYMENT_METHODS,
  differenceWithOtherMeansBs,
  expectedWithOtherMeansBs,
  isCashMovement,
  type CashMovement,
  type CashSessionSummary,
} from './cash'

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

// El criterio de arqueo cambió al separar efectivo de otros medios. Los
// turnos cerrados antes de ese cambio se cuadraron sumando TODO, así que
// el historial muestra ambos números — evaluar los viejos sólo por
// efectivo haría aparecer descuadres de cientos de bolivianos en turnos
// que cerraron perfectos, señalando a una persona por un cambio de fórmula.
function session(patch: Partial<CashSessionSummary> = {}): CashSessionSummary {
  return {
    id: 's1',
    openedAt: '2026-07-31T19:16:43Z',
    openedByName: 'Romina',
    openingBalanceBs: 1106,
    closedAt: '2026-08-01T11:33:05Z',
    closedByName: 'Romina',
    countedBalanceBs: 1956.8,
    cashIncomeBs: 0,
    cashExpenseBs: 149.2,
    expectedBs: 956.8,
    differenceBs: 1000,
    otherIncomeBs: 1000,
    otherExpenseBs: 0,
    movements: 8,
    status: 'closed',
    notes: 'transferencia de dinero',
    ...patch,
  }
}

describe('expectedWithOtherMeansBs', () => {
  it('adds non-cash income and subtracts non-cash expense', () => {
    expect(expectedWithOtherMeansBs(session())).toBe(1956.8)
  })

  it('equals the cash-only expected when there is no non-cash movement', () => {
    const s = session({ otherIncomeBs: 0, otherExpenseBs: 0 })
    expect(expectedWithOtherMeansBs(s)).toBe(s.expectedBs)
  })
})

describe('differenceWithOtherMeansBs', () => {
  it("reproduces the real shift that closed balanced under the old rule", () => {
    // Turno real de Romina del 31/07: cuadró en 0 con el criterio viejo,
    // pero da +1000 mirando sólo el efectivo.
    expect(differenceWithOtherMeansBs(session())).toBe(0)
    expect(session().differenceBs).toBe(1000)
  })

  it('reports a genuine shortfall under both criteria', () => {
    // Turno real de Rodrigo del 28/07, nota "falto 1 bs".
    const s = session({
      openingBalanceBs: 50, expectedBs: 5006, otherIncomeBs: 300,
      countedBalanceBs: 5305, differenceBs: 299, notes: 'falto 1 bs',
    })
    expect(differenceWithOtherMeansBs(s)).toBe(-1)
  })

  it('is null while the register is still open (nothing counted yet)', () => {
    expect(
      differenceWithOtherMeansBs(session({ countedBalanceBs: null, status: 'open' })),
    ).toBeNull()
  })
})
