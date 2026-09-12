import { describe, expect, it } from 'vitest'
import {
  companionsFromOccupants,
  holderRpcParams,
  isHolderSelectionComplete,
  type PreloadedOccupant,
} from './holderSelection'

describe('holderRpcParams', () => {
  it('returns empty params when the stay already has a holder (nothing to resolve)', () => {
    expect(holderRpcParams(false, { kind: 'none' })).toEqual({})
  })

  it('returns holderPersonId when an existing preloaded occupant was chosen', () => {
    expect(holderRpcParams(true, { kind: 'existing', personId: 'p-1' })).toEqual({
      holderPersonId: 'p-1',
    })
  })

  it('returns trimmed holderFirstName/holderLastName when a new name was typed', () => {
    expect(
      holderRpcParams(true, { kind: 'new', firstName: ' Ana ', lastName: ' Pérez ' }),
    ).toEqual({ holderFirstName: 'Ana', holderLastName: 'Pérez' })
  })

  it('returns empty params when a new name was started but left incomplete', () => {
    expect(holderRpcParams(true, { kind: 'new', firstName: 'Ana', lastName: '' })).toEqual({})
  })

  it('returns empty params when nothing was chosen yet', () => {
    expect(holderRpcParams(true, { kind: 'none' })).toEqual({})
  })
})

describe('isHolderSelectionComplete', () => {
  it('is always complete when the stay already has a holder', () => {
    expect(isHolderSelectionComplete(false, { kind: 'none' })).toBe(true)
  })

  it('is complete once an existing occupant is picked', () => {
    expect(isHolderSelectionComplete(true, { kind: 'existing', personId: 'p-1' })).toBe(true)
  })

  it('is complete once both first and last name are typed', () => {
    expect(
      isHolderSelectionComplete(true, { kind: 'new', firstName: 'Ana', lastName: 'Pérez' }),
    ).toBe(true)
  })

  it('is incomplete when the name is only partially typed', () => {
    expect(isHolderSelectionComplete(true, { kind: 'new', firstName: 'Ana', lastName: '' })).toBe(
      false,
    )
  })

  it('is incomplete when nothing was chosen yet', () => {
    expect(isHolderSelectionComplete(true, { kind: 'none' })).toBe(false)
  })
})

describe('companionsFromOccupants', () => {
  const occupants: PreloadedOccupant[] = [
    {
      personId: 'p-1',
      firstName: 'Ana',
      lastName: 'Pérez',
      document: '123',
      role: 'holder',
      confirmedAt: null,
    },
    {
      personId: 'p-2',
      firstName: 'Luis',
      lastName: 'Gómez',
      document: null,
      role: 'companion',
      confirmedAt: null,
    },
  ]

  it('prefills a companion draft for every occupant not chosen as holder, carrying the stored document (confirming preloaded data at check-in)', () => {
    const result = companionsFromOccupants(occupants, 'p-1')
    expect(result).toHaveLength(1)
    expect(result[0]).toMatchObject({ firstName: 'Luis', lastName: 'Gómez', document: '' })
  })

  it('carries the stored document through when the preloaded occupant has one', () => {
    const withDoc: PreloadedOccupant[] = [
      { personId: 'p-3', firstName: 'Rosa', lastName: 'Díaz', document: '999', role: 'companion', confirmedAt: null },
    ]
    const result = companionsFromOccupants(withDoc, null)
    expect(result[0]).toMatchObject({ firstName: 'Rosa', lastName: 'Díaz', document: '999' })
  })

  it('prefills everyone when no holder has been chosen yet', () => {
    const result = companionsFromOccupants(occupants, null)
    expect(result).toHaveLength(2)
  })
})
