import { describe, expect, it } from 'vitest'
import { userFacingAnticipoError } from './anticipos'

describe('userFacingAnticipoError — translates raw RPC errors to actionable messages', () => {
  it('translates the closed-register error into an "open the register" message', () => {
    expect(userFacingAnticipoError('No hay una caja abierta')).toBe(
      'No hay una caja abierta. Abrí la caja antes de registrar un anticipo.',
    )
  })

  it('passes through unrelated error messages unchanged', () => {
    expect(userFacingAnticipoError('Anticipo no encontrado')).toBe('Anticipo no encontrado')
  })
})
