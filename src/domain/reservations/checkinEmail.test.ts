import { describe, expect, it } from 'vitest'
import { checkinEmailError, checkinEmailRequired, isValidEmail } from './checkinEmail'

describe('isValidEmail', () => {
  it('acepta un correo con formato válido', () => {
    expect(isValidEmail('ana@example.com')).toBe(true)
  })

  it('rechaza sin @', () => {
    expect(isValidEmail('ana.example.com')).toBe(false)
  })

  it('rechaza sin dominio', () => {
    expect(isValidEmail('ana@')).toBe(false)
  })

  it('rechaza vacío', () => {
    expect(isValidEmail('')).toBe(false)
  })
})

describe('checkinEmailRequired', () => {
  it('no es obligatorio si no quiere ofertas', () => {
    expect(checkinEmailRequired(false, null)).toBe(false)
  })

  it('es obligatorio si quiere ofertas y no tiene correo cargado', () => {
    expect(checkinEmailRequired(true, null)).toBe(true)
  })

  it('no es obligatorio si quiere ofertas pero ya tiene correo cargado', () => {
    expect(checkinEmailRequired(true, 'ana@example.com')).toBe(false)
  })
})

describe('checkinEmailError', () => {
  it('sin error cuando no quiere ofertas y deja el campo vacío', () => {
    expect(checkinEmailError(false, null, '')).toBeNull()
  })

  it('error cuando es obligatorio y está vacío', () => {
    expect(checkinEmailError(true, null, '')).toBe(
      'Ingresá un correo para poder aceptar recibir promociones',
    )
  })

  it('sin error cuando ya tiene correo y deja el campo tal cual', () => {
    expect(checkinEmailError(true, 'ana@example.com', 'ana@example.com')).toBeNull()
  })

  it('error cuando el valor ingresado no es un correo válido', () => {
    expect(checkinEmailError(true, null, 'no-es-correo')).toBe('El correo no es válido')
  })

  it('sin error con un correo nuevo válido', () => {
    expect(checkinEmailError(true, null, 'nueva@example.com')).toBeNull()
  })
})
