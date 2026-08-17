import { describe, expect, it } from 'vitest'
import { balanceDue, netAnticipos } from './folio'

const active = (amountBs: number) => ({ amountBs, status: 'active' as const })

describe('netAnticipos', () => {
  it('suma los anticipos de la reserva', () => {
    expect(netAnticipos([active(200), active(150)])).toBe(350)
  })

  // El no-show que pierde el adelanto al cancelar: esa plata ya es del
  // hotel, no es un pago a cuenta del folio de nadie. El hotel NO
  // reembolsa, así que 'forfeited' es el único destino distinto de
  // 'active' que existe.
  it('ignora los anticipos perdidos (forfeited)', () => {
    expect(
      netAnticipos([active(200), { amountBs: 500, status: 'forfeited' as const }]),
    ).toBe(200)
  })

  it('sin anticipos es cero', () => {
    expect(netAnticipos([])).toBe(0)
  })
})

describe('balanceDue', () => {
  it('cobra el folio completo cuando no hubo anticipo', () => {
    expect(balanceDue(700, 0)).toBe(700)
  })

  it('descuenta el anticipo del total del folio', () => {
    expect(balanceDue(700, 200)).toBe(500)
  })

  it('no cobra nada si el anticipo cubre el folio', () => {
    expect(balanceDue(700, 700)).toBe(0)
  })

  // El hotel no devuelve la diferencia: cobra 0 y ahí termina.
  it('nunca devuelve negativo cuando el anticipo excede el folio', () => {
    expect(balanceDue(500, 800)).toBe(0)
  })
})
