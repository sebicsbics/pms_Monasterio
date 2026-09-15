import { describe, expect, it } from 'vitest'
import { balanceDue, netAnticipos, roomAndExtrasTotal, roomChargeLabel } from './folio'

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

// R2.11 (checkin-payment-and-agency): un pago cobrado AL CHECK-IN es un
// anticipo más, sin marca de "cuándo se cobró". netAnticipos/balanceDue no
// necesitan tocarse para este cambio — esta prueba es la evidencia de
// que un anticipo registrado en el momento del check-in (en vez de en
// otro momento de la estadía) suma igual que cualquier otro anticipo.
describe('netAnticipos — regresión pago al check-in', () => {
  it('un anticipo cobrado al check-in cuenta igual que uno cobrado después', () => {
    const anticipoAlCheckIn = active(300)
    const anticipoPosterior = active(100)
    expect(netAnticipos([anticipoAlCheckIn, anticipoPosterior])).toBe(400)
  })

  it('check-out cobra solo el saldo cuando ya se pagó parte al check-in', () => {
    const totalFolio = 700
    const pagadoAlCheckIn = netAnticipos([active(500)])
    expect(balanceDue(totalFolio, pagadoAlCheckIn)).toBe(200)
  })

  it('check-out no cobra nada si el pago al check-in cubrió todo el folio', () => {
    const totalFolio = 700
    const pagadoAlCheckIn = netAnticipos([active(700)])
    expect(balanceDue(totalFolio, pagadoAlCheckIn)).toBe(0)
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

// feat/booking-17-checkout-enforcement: check_out_room ya no cobra el
// total de la habitación en una reserva institucional (payer_mode=
// 'client'), solo sus extras -- el contrato del grupo se salda al
// cerrarse el grupo o al saldar la cuenta por cobrar, nunca en el
// check-out individual (decisión #391). El preview del folio en pantalla
// tiene que reflejar EXACTAMENTE lo mismo que va a cobrar el RPC, o
// muestra un monto que después no coincide con lo realmente cobrado.
describe('roomAndExtrasTotal', () => {
  it('each_stay: suma habitación + extras (sin cambios)', () => {
    expect(roomAndExtrasTotal(500, 80, 'each_stay')).toBe(580)
  })

  it('client: ignora el cargo de habitación, solo cuentan los extras', () => {
    expect(roomAndExtrasTotal(500, 80, 'client')).toBe(80)
  })

  it('client sin extras: el total es 0, no el precio de la habitación', () => {
    expect(roomAndExtrasTotal(500, 0, 'client')).toBe(0)
  })
})

// review de feat/booking-17-checkout-enforcement: el panel mostraba
// "Habitación (Doble) 500 Bs" seguido de "Total 80 Bs" para una
// habitación institucional -- el precio de la habitación parecía sumar
// al total aunque el fix anterior ya lo excluye del cálculo. La etiqueta
// tiene que decir explícitamente que esa línea no es parte de lo que se
// cobra en este check-out.
describe('roomChargeLabel', () => {
  it('each_stay: muestra el tipo de habitación (sin cambios)', () => {
    expect(roomChargeLabel('Doble', 'each_stay')).toBe('Habitación (Doble)')
  })

  it('client: aclara que está cubierta por el contrato del grupo, no por el tipo de habitación', () => {
    expect(roomChargeLabel('Doble', 'client')).toBe(
      'Habitación (cubierta por el contrato del grupo)',
    )
  })
})
