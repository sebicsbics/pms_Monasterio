import { describe, expect, it } from 'vitest'
import { PAYMENT_METHOD_LABEL, type PaymentMethod } from './event'

// El selector de eventos hardcodea su subconjunto del catálogo, así que es
// el único lugar donde un código retirado sobrevive sin que la base lo
// corrija: el resto del sistema lee `payment_methods` filtrando por
// `is_active`. TRANSFERENCIA se unificó en DEPOSITO
// (20260829000000_unify_deposito_transferencia).
describe('PAYMENT_METHOD_LABEL', () => {
  it('does not offer the retired TRANSFERENCIA code', () => {
    expect(Object.keys(PAYMENT_METHOD_LABEL)).not.toContain('TRANSFERENCIA')
  })

  it('offers the bank deposit under its unified code', () => {
    expect(PAYMENT_METHOD_LABEL.DEPOSITO).toBe('Depósito')
  })

  it('only offers codes that move real money into caja', () => {
    const cajaMethods: PaymentMethod[] = ['EFECTIVO', 'QR', 'TARJETA', 'DEPOSITO']
    expect(Object.keys(PAYMENT_METHOD_LABEL).sort()).toEqual([...cajaMethods].sort())
  })
})
