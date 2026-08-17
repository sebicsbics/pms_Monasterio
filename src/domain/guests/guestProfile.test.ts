import { describe, expect, it } from 'vitest'
import { guestPrefill, type GuestProfileMatch } from './guestProfile'

const MATCH: GuestProfileMatch = {
  personId: 'p1',
  firstName: 'Juan',
  lastName: 'Pérez',
  email: 'juan@example.com',
  birthDate: '1990-05-02',
  countryCode: 'BOL',
  city: 'La Paz',
  occupation: 'Ingeniero',
  wantsOffers: true,
}

describe('guestPrefill', () => {
  it('mapea la ficha encontrada a valores de formulario', () => {
    expect(guestPrefill(MATCH)).toEqual({
      firstName: 'Juan',
      lastName: 'Pérez',
      email: 'juan@example.com',
      birthDate: '1990-05-02',
      countryCode: 'BOL',
      city: 'La Paz',
      occupation: 'Ingeniero',
      wantsOffers: true,
    })
  })

  it('deja vacío lo que falta en la ficha en vez de inventarlo', () => {
    const prefill = guestPrefill({
      ...MATCH,
      email: null,
      birthDate: null,
      countryCode: null,
      city: null,
      occupation: null,
      wantsOffers: false,
    })
    expect(prefill).toEqual({
      firstName: 'Juan',
      lastName: 'Pérez',
      email: '',
      birthDate: '',
      countryCode: '',
      city: '',
      occupation: '',
      wantsOffers: false,
    })
  })

  it('recorta la fecha a yyyy-mm-dd para el input date', () => {
    expect(guestPrefill({ ...MATCH, birthDate: '1990-05-02T00:00:00Z' }).birthDate).toBe(
      '1990-05-02',
    )
  })
})
