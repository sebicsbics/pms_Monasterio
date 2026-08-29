import { describe, expect, it } from 'vitest'
import {
  ANTICIPO_PAYMENT_METHODS,
  CAJA_PAYMENT_METHODS,
  isAnticipoMethod,
  differenceWithOtherMeansBs,
  expectedWithOtherMeansBs,
  isCashMovement,
  usesOtherMeansCriterion,
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

describe('isAnticipoMethod', () => {
  it('accepts the four cash-register methods plus MIXTO', () => {
    for (const code of ANTICIPO_PAYMENT_METHODS) {
      expect(isAnticipoMethod(code)).toBe(true)
    }
    expect(ANTICIPO_PAYMENT_METHODS).toHaveLength(5)
  })

  // Un anticipo es plata que YA entró; "por cobrar" es exactamente lo
  // contrario, y una cortesía o un canje no generan adelanto.
  it('rejects CTAS_POR_COBRAR — an advance cannot be money not yet received', () => {
    expect(isAnticipoMethod('CTAS_POR_COBRAR')).toBe(false)
  })

  it('rejects methods with no cash flow', () => {
    expect(isAnticipoMethod('CORTESIA')).toBe(false)
    expect(isAnticipoMethod('INTERCAMBIO')).toBe(false)
    expect(isAnticipoMethod('OTRO')).toBe(false)
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

describe('usesOtherMeansCriterion', () => {
  it('applies to a shift opened before the split (Romina, 31/07)', () => {
    expect(usesOtherMeansCriterion(session())).toBe(true)
  })

  it('applies to the last shift opened under the old rule (05/08 19:04Z)', () => {
    expect(
      usesOtherMeansCriterion(session({ openedAt: '2026-08-05T19:04:16.060888Z' })),
    ).toBe(true)
  })

  it('does not apply to the first shift opened after the split (06/08 04:36Z)', () => {
    expect(
      usesOtherMeansCriterion(session({ openedAt: '2026-08-06T04:36:41.425198Z' })),
    ).toBe(false)
  })
})

describe('the other-means criterion on shifts after the split', () => {
  // Turno real del 22/08: cuadró EXACTO en efectivo, pero el criterio viejo
  // le restaba los 10.957 Bs cobrados por QR/depósito/tarjeta —  plata que
  // nunca pasó por el cajón. El arqueo mostraba un faltante de cinco cifras
  // en un turno perfecto.
  const afterSplit = session({
    openedAt: '2026-08-22T12:00:00Z',
    closedAt: '2026-08-22T23:00:00Z',
    openingBalanceBs: 0,
    cashIncomeBs: 11497,
    cashExpenseBs: 11447,
    expectedBs: 50,
    countedBalanceBs: 50,
    differenceBs: 0,
    otherIncomeBs: 10957,
    otherExpenseBs: 0,
  })

  it('reports no expected total: the criterion does not apply', () => {
    expect(expectedWithOtherMeansBs(afterSplit)).toBeNull()
  })

  it('reports no difference instead of a phantom shortfall', () => {
    expect(differenceWithOtherMeansBs(afterSplit)).toBeNull()
    expect(afterSplit.differenceBs).toBe(0)
  })
})
