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
