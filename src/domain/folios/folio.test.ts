import { describe, expect, it } from 'vitest'
import { balanceDue, netAnticipos } from './folio'

describe('netAnticipos', () => {
  it('suma los anticipos de la reserva', () => {
    expect(
      netAnticipos([
        { amountBs: 200, refundedAmountBs: 0 },
        { amountBs: 150, refundedAmountBs: 0 },
      ]),
    ).toBe(350)
  })

  it('descuenta lo que ya se reembolsó', () => {
    expect(netAnticipos([{ amountBs: 300, refundedAmountBs: 100 }])).toBe(200)
  })

  it('un anticipo totalmente reembolsado no cuenta', () => {
    expect(netAnticipos([{ amountBs: 300, refundedAmountBs: 300 }])).toBe(0)
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
