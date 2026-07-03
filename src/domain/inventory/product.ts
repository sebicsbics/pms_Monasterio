export interface ProductCategory {
  id: string
  name: string
}

export interface Product {
  id: string
  name: string
  categoryId: string
  categoryName: string
  unit: string
  currentStock: number
  minStock: number
  salePriceBs: number // precio de venta al huésped (0 = no vendible)
}

// ¿Es vendible al huésped (minibar)? Tiene precio de venta y stock.
export function isSellable(p: Product): boolean {
  return p.salePriceBs > 0
}

export interface LowStockProduct {
  id: string
  name: string
  category: string
  unit: string
  currentStock: number
  minStock: number
}

// ¿El producto está en o por debajo de su mínimo? (hay que reponer)
export function isBelowMin(p: Product): boolean {
  return p.currentStock <= p.minStock
}
