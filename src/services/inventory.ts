import { supabase } from './supabase'
import type {
  Product,
  ProductCategory,
  LowStockProduct,
} from '../domain/inventory/product'

export async function fetchCategories(): Promise<ProductCategory[]> {
  const { data, error } = await supabase
    .from('product_categories')
    .select('id, name')
    .order('name')
  if (error) throw new Error(error.message)
  return data as ProductCategory[]
}

interface ProductRow {
  id: string
  name: string
  category_id: string
  unit: string
  current_stock: number
  min_stock: number
  product_categories: { name: string } | null
}

export async function fetchProducts(): Promise<Product[]> {
  const { data, error } = await supabase
    .from('products')
    .select('id, name, category_id, unit, current_stock, min_stock, product_categories ( name )')
    .order('name')
  if (error) throw new Error(error.message)

  return (data as unknown as ProductRow[]).map((r) => ({
    id: r.id,
    name: r.name,
    categoryId: r.category_id,
    categoryName: r.product_categories?.name ?? '—',
    unit: r.unit,
    currentStock: Number(r.current_stock),
    minStock: Number(r.min_stock),
  }))
}

export async function createProduct(input: {
  name: string
  categoryId: string
  unit: string
  minStock: number
}): Promise<void> {
  const { error } = await supabase.from('products').insert({
    name: input.name,
    category_id: input.categoryId,
    unit: input.unit,
    min_stock: input.minStock,
  })
  if (error) throw new Error(error.message)
}

export async function fetchLowStock(): Promise<LowStockProduct[]> {
  const { data, error } = await supabase.from('low_stock').select('*').order('name')
  if (error) throw new Error(error.message)
  return (data as Record<string, unknown>[]).map((r) => ({
    id: r.id as string,
    name: r.name as string,
    category: r.category as string,
    unit: r.unit as string,
    currentStock: Number(r.current_stock),
    minStock: Number(r.min_stock),
  }))
}

export interface StockEntryItemInput {
  productId: string
  quantity: number
  unitPrice: number
}

export async function registerStockEntry(input: {
  entryDate: string
  isInvoiced: boolean
  invoiceNumber: string
  supplier: string
  notes: string
  items: StockEntryItemInput[]
}): Promise<void> {
  const { error } = await supabase.rpc('register_stock_entry', {
    p_entry_date: input.entryDate || null,
    p_is_invoiced: input.isInvoiced,
    p_invoice_number: input.invoiceNumber,
    p_supplier: input.supplier,
    p_notes: input.notes,
    p_items: input.items,
  })
  if (error) throw new Error(error.message)
}
