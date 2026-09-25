import { describe, expect, it } from 'vitest'
import { mapOccupancyRow } from './analytics'

describe('mapOccupancyRow', () => {
  it('maps datos_suficientes=false through', () => {
    const row = mapOccupancyRow({
      year: 2022, ocupacion_pct: 8.3, es_parcial: true,
      desde: '2022-01-01', hasta: '2022-01-02', datos_suficientes: false,
    })
    expect(row.datosSuficientes).toBe(false)
  })

  it('maps datos_suficientes=true through', () => {
    const row = mapOccupancyRow({
      year: 2016, ocupacion_pct: 22.4, es_parcial: false,
      desde: '2016-01-01', hasta: '2016-12-31', datos_suficientes: true,
    })
    expect(row.datosSuficientes).toBe(true)
  })

  it('treats a missing column (old DB, pre-migration) as sufficient', () => {
    const row = mapOccupancyRow({
      year: 2016, ocupacion_pct: 22.4, es_parcial: false,
      desde: '2016-01-01', hasta: '2016-12-31',
    })
    expect(row.datosSuficientes).toBe(true)
  })
})
