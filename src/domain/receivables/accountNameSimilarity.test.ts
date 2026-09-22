import { describe, expect, it } from 'vitest'
import { normalize, findSimilarAccountName } from './accountNameSimilarity'

describe('accountNameSimilarity', () => {
  it('normaliza mayúsculas, acentos y puntuación', () => {
    expect(normalize('Hotel ABC.')).toBe('hotel abc')
    expect(normalize('HOTÉL ábc')).toBe('hotel abc')
  })

  it('encuentra coincidencia exacta tras normalizar', () => {
    expect(findSimilarAccountName('Hotel ABC', ['hotel abc.'])).toBe('hotel abc.')
  })

  it('encuentra coincidencia cuando un nombre contiene al otro', () => {
    expect(findSimilarAccountName('Hotel ABC Sucursal Sur', ['Hotel ABC'])).toBe('Hotel ABC')
  })

  it('no marca falso positivo entre nombres distintos', () => {
    expect(findSimilarAccountName('Agencia Delta', ['Hotel ABC', 'Turismo Beta'])).toBeNull()
  })

  it('devuelve null si el nombre está vacío', () => {
    expect(findSimilarAccountName('   ', ['Hotel ABC'])).toBeNull()
  })
})
