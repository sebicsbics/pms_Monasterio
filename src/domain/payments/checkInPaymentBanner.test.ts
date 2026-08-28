import { describe, expect, it } from 'vitest'
import { checkInPaymentBanner } from './checkInPaymentBanner'

describe('checkInPaymentBanner', () => {
  it('siempre afirma que el check-in quedó registrado', () => {
    // La invariante del feature: el cobro es un segundo llamado y su
    // fallo NUNCA revierte el check-in. El mensaje no debe dar a
    // entender lo contrario, sea cual sea el error del servidor.
    expect(checkInPaymentBanner('cualquier cosa')).toContain('Check-in registrado')
  })

  it('ante caja cerrada, dice qué hacer en vez de repetir el error crudo', () => {
    const msg = checkInPaymentBanner('No hay una caja abierta')
    expect(msg).toContain('Abrí la caja')
    expect(msg).toContain('Anticipos')
  })

  it('para cualquier otro error, muestra el mensaje del servidor y manda a Anticipos', () => {
    const msg = checkInPaymentBanner('El monto supera el saldo')
    expect(msg).toContain('El monto supera el saldo')
    expect(msg).toContain('Reintentalo desde Anticipos')
  })
})
