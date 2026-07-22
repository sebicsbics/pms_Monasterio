import { describe, expect, it } from 'vitest'
import { DISCOUNT_CEILING_PCT, discountPct, exceedsCeiling } from './discount'

describe('discountPct — pure discount math (mirrors SQL discount_pct)', () => {
  it('computes a standard discount', () => {
    expect(discountPct(1000, 850)).toBe(15)
  })

  it('computes 0% when price equals base', () => {
    expect(discountPct(1000, 1000)).toBe(0)
  })

  it('computes exactly 20% at the boundary', () => {
    expect(discountPct(1000, 800)).toBe(20)
  })

  it('computes just above 20% at the boundary', () => {
    // 799.99 / 1000 => 20.001% rounded to 2 decimals => 20.00... watch rounding
    expect(discountPct(1000, 799.99)).toBeCloseTo(20.001, 2)
  })

  it('computes 100% when price is 0', () => {
    expect(discountPct(1000, 0)).toBe(100)
  })

  it('guards against base <= 0 by returning 0', () => {
    expect(discountPct(0, 500)).toBe(0)
    expect(discountPct(-100, 500)).toBe(0)
  })

  it('guards against a negative price by clamping discount to 100', () => {
    expect(discountPct(1000, -50)).toBe(100)
  })

  it('rounds to 2 decimal places', () => {
    expect(discountPct(3, 1)).toBeCloseTo(66.67, 2)
  })
})

describe('exceedsCeiling — 20% boundary rule', () => {
  it('does not require approval at exactly the ceiling (20.00%)', () => {
    expect(exceedsCeiling(20)).toBe(false)
    expect(exceedsCeiling(DISCOUNT_CEILING_PCT)).toBe(false)
  })

  it('requires approval just above the ceiling (20.01%)', () => {
    expect(exceedsCeiling(20.01)).toBe(true)
  })

  it('does not require approval below the ceiling', () => {
    expect(exceedsCeiling(15)).toBe(false)
    expect(exceedsCeiling(0)).toBe(false)
  })

  it('requires approval well above the ceiling', () => {
    expect(exceedsCeiling(40)).toBe(true)
    expect(exceedsCeiling(100)).toBe(true)
  })
})
