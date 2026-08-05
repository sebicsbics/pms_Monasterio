import { describe, expect, it } from 'vitest'
import {
  needsPaymentReference,
  needsReceiptPhoto,
  paymentProofError,
  proofForMethod,
  type PaymentProof,
} from './paymentProof'

const file = new File(['x'], 'qr.jpg', { type: 'image/jpeg' })
const filled: PaymentProof = { receipt: file, paymentReference: 'AB12345' }

describe('needsReceiptPhoto / needsPaymentReference', () => {
  it('asks for a photo only on QR', () => {
    expect(needsReceiptPhoto('QR')).toBe(true)
    expect(needsReceiptPhoto('TARJETA')).toBe(false)
    expect(needsReceiptPhoto('EFECTIVO')).toBe(false)
    expect(needsReceiptPhoto(null)).toBe(false)
  })

  it('asks for a transaction number only on card', () => {
    expect(needsPaymentReference('TARJETA')).toBe(true)
    expect(needsPaymentReference('QR')).toBe(false)
    expect(needsPaymentReference('DEPOSITO')).toBe(false)
  })
})

describe('paymentProofError', () => {
  it('rejects a card payment without a reference code', () => {
    expect(
      paymentProofError('TARJETA', { receipt: null, paymentReference: '   ' }),
    ).toMatch(/código de referencia/i)
  })

  it('accepts a card payment with a reference code', () => {
    expect(paymentProofError('TARJETA', filled)).toBeNull()
  })

  it('rejects a QR payment without the receipt photo', () => {
    expect(
      paymentProofError('QR', { receipt: null, paymentReference: 'AB1' }),
    ).toMatch(/foto del comprobante/i)
  })

  it('accepts a QR payment with the receipt photo', () => {
    expect(paymentProofError('QR', { receipt: file, paymentReference: '' })).toBeNull()
  })

  it('never blocks other payment methods', () => {
    expect(
      paymentProofError('EFECTIVO', { receipt: null, paymentReference: '' }),
    ).toBeNull()
  })
})

describe('proofForMethod', () => {
  it('sends only the photo on QR', () => {
    expect(proofForMethod('QR', filled)).toEqual({
      receipt: file,
      paymentReference: null,
    })
  })

  it('sends only the reference on card, trimmed', () => {
    expect(
      proofForMethod('TARJETA', { receipt: file, paymentReference: '  AB1  ' }),
    ).toEqual({ receipt: null, paymentReference: 'AB1' })
  })

  it('drops leftover proof when the method does not need any', () => {
    expect(proofForMethod('EFECTIVO', filled)).toEqual({
      receipt: null,
      paymentReference: null,
    })
  })
})
