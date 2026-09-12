import { describe, expect, it } from 'vitest'
import { holderPrefillFields, holderToPrefill } from './holderPrefill'
import type { PreloadedOccupant } from './holderSelection'

function occupant(overrides: Partial<PreloadedOccupant> = {}): PreloadedOccupant {
  return {
    personId: 'p-1',
    firstName: 'Sebas',
    lastName: 'Davalos',
    document: '5666468',
    email: null,
    role: 'holder',
    confirmedAt: null,
    birthDate: null,
    countryCode: null,
    city: null,
    originCity: null,
    travelPurpose: null,
    occupation: null,
    transportMeans: null,
    ...overrides,
  }
}

describe('holderToPrefill', () => {
  it('returns the preloaded holder row when the stay already has a known holder', () => {
    const holder = occupant({ role: 'holder' })
    const companion = occupant({ personId: 'p-2', role: 'companion' })
    expect(holderToPrefill([companion, holder], false, { kind: 'none' })).toBe(holder)
  })

  it('returns undefined when there is no holder row yet, even if the stay is resolved', () => {
    const companion = occupant({ personId: 'p-2', role: 'companion' })
    expect(holderToPrefill([companion], false, { kind: 'none' })).toBeUndefined()
  })

  it('returns the chosen occupant when reception picked one from the amber list', () => {
    const chosen = occupant({ personId: 'p-9' })
    expect(
      holderToPrefill([chosen], true, { kind: 'existing', personId: 'p-9' }),
    ).toBe(chosen)
  })

  it('returns undefined when a brand-new holder is being typed in', () => {
    const occupants = [occupant()]
    expect(
      holderToPrefill(occupants, true, { kind: 'new', firstName: 'Ana', lastName: 'Paz' }),
    ).toBeUndefined()
    expect(holderToPrefill(occupants, true, { kind: 'none' })).toBeUndefined()
  })
})

describe('holderPrefillFields', () => {
  it('confirms the stored document and travel-profile fields instead of asking again blank', () => {
    const holder = occupant({
      document: '5666468',
      birthDate: '1990-01-01',
      countryCode: 'BOL',
      city: 'La Paz',
      originCity: 'Santa Cruz',
      travelPurpose: 'turismo',
      occupation: 'ingeniero',
      transportMeans: 'auto',
    })
    expect(holderPrefillFields(holder)).toEqual({
      document: '5666468',
      birthDate: '1990-01-01',
      countryCode: 'BOL',
      city: 'La Paz',
      originCity: 'Santa Cruz',
      travelPurpose: 'turismo',
      occupation: 'ingeniero',
      transportMeans: 'auto',
    })
  })

  it('leaves everything blank when there is no holder to confirm yet', () => {
    expect(holderPrefillFields(undefined)).toEqual({
      document: '',
      birthDate: '',
      countryCode: '',
      city: '',
      originCity: '',
      travelPurpose: '',
      occupation: '',
      transportMeans: '',
    })
  })

  it('leaves individual fields blank when not stored, without inventing values', () => {
    const holder = occupant({ document: '123', birthDate: null })
    expect(holderPrefillFields(holder).document).toBe('123')
    expect(holderPrefillFields(holder).birthDate).toBe('')
  })
})
