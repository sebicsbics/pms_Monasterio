import { describe, expect, it } from 'vitest'
import { fittingRoomTypes, selectDefaultRoomType } from './roomTypeSelection'

// Habitación 7 real (DEFECT 2): dos fichas de precio distintas sobre la
// misma habitación física.
const SIMPLE = { id: 'simple', name: 'Simple Estándar', basePriceBs: 350, maxOccupancy: 1 }
const MATRIMONIAL = { id: 'matrimonial', name: 'Matrimonial', basePriceBs: 480, maxOccupancy: 2 }
// Orden como lo devuelve available_rooms: precio ascendente.
const ALIASED_POOL = [SIMPLE, MATRIMONIAL]

describe('fittingRoomTypes', () => {
  it('devuelve sólo los tipos cuya capacidad alcanza', () => {
    expect(fittingRoomTypes(ALIASED_POOL, 1)).toEqual([SIMPLE, MATRIMONIAL])
    expect(fittingRoomTypes(ALIASED_POOL, 2)).toEqual([MATRIMONIAL])
  })

  it('devuelve vacío si ninguno alcanza', () => {
    expect(fittingRoomTypes(ALIASED_POOL, 3)).toEqual([])
  })
})

describe('selectDefaultRoomType', () => {
  it('elige el más barato que alcanza para 1 persona (Simple, no Matrimonial)', () => {
    expect(selectDefaultRoomType(ALIASED_POOL, 1)).toEqual(SIMPLE)
  })

  it('elige Matrimonial para 2 personas — Simple no alcanza', () => {
    expect(selectDefaultRoomType(ALIASED_POOL, 2)).toEqual(MATRIMONIAL)
  })

  it('si ninguno alcanza, usa el de mayor capacidad (sobre-ocupación real)', () => {
    expect(selectDefaultRoomType(ALIASED_POOL, 3)).toEqual(MATRIMONIAL)
  })

  it('devuelve null si no hay tipos', () => {
    expect(selectDefaultRoomType([], 1)).toBeNull()
  })

  it('con un solo tipo, siempre lo elige aunque no alcance', () => {
    expect(selectDefaultRoomType([SIMPLE], 5)).toEqual(SIMPLE)
  })
})
