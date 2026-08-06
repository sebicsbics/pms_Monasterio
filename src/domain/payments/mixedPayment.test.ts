import { describe, expect, it } from 'vitest'
import {
  completeSplit,
  EMPTY_MIXED_PAYMENT,
  isMixed,
  mixedPaymentError,
  type MixedPayment,
} from './mixedPayment'
import { EMPTY_PAYMENT_PROOF, type PaymentProof } from './paymentProof'

const photo = new File(['x'], 'qr.jpg', { type: 'image/jpeg' })
const withPhoto: PaymentProof = { receipt: photo, paymentReference: '' }
const withRef: PaymentProof = { receipt: null, paymentReference: 'AB12345' }

function split(patch: Partial<MixedPayment> = {}): MixedPayment {
  return { ...EMPTY_MIXED_PAYMENT, cashBs: '300', nonCashBs: '150', ...patch }
}

describe('isMixed', () => {
  it('only matches MIXTO', () => {
    expect(isMixed('MIXTO')).toBe(true)
    expect(isMixed('EFECTIVO')).toBe(false)
    expect(isMixed(null)).toBe(false)
  })
})

describe('completeSplit', () => {
  it('fills the electronic half from the cash amount', () => {
    expect(completeSplit(450, 'cash', '300')).toEqual({ cashBs: '300', nonCashBs: '150' })
  })

  it('fills the cash half from the electronic amount', () => {
    expect(completeSplit(450, 'nonCash', '150')).toEqual({ nonCashBs: '150', cashBs: '300' })
  })

  it('does not go negative when the amount exceeds the total', () => {
    expect(completeSplit(450, 'cash', '600')).toEqual({ cashBs: '600', nonCashBs: '0' })
  })

  it('avoids float drift on cents', () => {
    expect(completeSplit(450.3, 'cash', '300.1')).toEqual({
      cashBs: '300.1',
      nonCashBs: '150.2',
    })
  })

  it('leaves the other half alone while the field is being cleared', () => {
    expect(completeSplit(450, 'cash', '')).toEqual({ cashBs: '' })
  })
})

describe('mixedPaymentError', () => {
  it('accepts a split that adds up, with the QR photo attached', () => {
    expect(mixedPaymentError(450, split(), withPhoto)).toBeNull()
  })

  it('reports how much the split overshoots', () => {
    expect(mixedPaymentError(450, split({ nonCashBs: '200' }), withPhoto)).toMatch(
      /se pasa por 50\.00 Bs/,
    )
  })

  it('reports how much is missing', () => {
    expect(mixedPaymentError(450, split({ nonCashBs: '100' }), withPhoto)).toMatch(
      /Faltan 50\.00 Bs/,
    )
  })

  it('rejects a zero half: that is a simple payment, not a mixed one', () => {
    expect(mixedPaymentError(300, split({ cashBs: '300', nonCashBs: '0' }), withPhoto))
      .toMatch(/ambos medios/)
  })

  it('rejects empty amounts', () => {
    expect(mixedPaymentError(450, split({ cashBs: '', nonCashBs: '' }), withPhoto))
      .toMatch(/Ingresá cuánto/)
  })

  it('still requires the QR photo for the electronic half', () => {
    expect(mixedPaymentError(450, split(), EMPTY_PAYMENT_PROOF)).toMatch(
      /foto del comprobante/i,
    )
  })

  it('requires the card reference when the electronic half is a card', () => {
    expect(
      mixedPaymentError(450, split({ nonCashMethod: 'TARJETA' }), EMPTY_PAYMENT_PROOF),
    ).toMatch(/código de referencia/i)
    expect(
      mixedPaymentError(450, split({ nonCashMethod: 'TARJETA' }), withRef),
    ).toBeNull()
  })

  it('tolerates a one-cent rounding difference', () => {
    expect(
      mixedPaymentError(450, split({ cashBs: '300', nonCashBs: '150.01' }), withPhoto),
    ).toBeNull()
  })
})
