import { describe, expect, it } from 'vitest'
import { balanceDue, netAnticipos } from './folio'

const active = (amountBs: number, refundedBs = 0) => ({
  amountBs,
  refundedBs,
  status: 'active',
})

describe('netAnticipos', () => {
  it('suma los anticipos de la reserva', () => {
    expect(netAnticipos([active(200), active(150)])).toBe(350)
  })

  it('descuenta lo que ya se reembolsó', () => {
    expect(netAnticipos([active(300, 100)])).toBe(200)
  })

  it('un anticipo totalmente reembolsado no cuenta', () => {
    expect(netAnticipos([active(300, 300)])).toBe(0)
  })

  // El no-show que pierde el adelanto: esa plata ya es del hotel, no es
  // un pago a cuenta del folio de nadie.
  it('ignora los anticipos perdidos (forfeited)', () => {
    expect(
      netAnticipos([active(200), { amountBs: 500, refundedBs: 0, status: 'forfeited' }]),
    ).toBe(200)
  })

  // Un reembolso mayor al anticipo es un dato corrupto; jamás puede
  // volverse un cargo extra contra el huésped.
  it('un reembolso mayor al anticipo no genera crédito negativo', () => {
    expect(netAnticipos([active(200), active(100, 400)])).toBe(200)
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

  it('nunca devuelve negativo: el excedente se reembolsa aparte', () => {
    expect(balanceDue(500, 800)).toBe(0)
  })
})
