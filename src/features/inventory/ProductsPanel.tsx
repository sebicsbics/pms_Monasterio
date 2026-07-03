import { useCallback, useEffect, useState } from 'react'
import type { Product, ProductCategory } from '../../domain/inventory/product'
import { isBelowMin } from '../../domain/inventory/product'
import {
  fetchProducts,
  fetchCategories,
  createProduct,
} from '../../services/inventory'

export function ProductsPanel() {
  const [products, setProducts] = useState<Product[]>([])
  const [categories, setCategories] = useState<ProductCategory[]>([])
  const [error, setError] = useState<string | null>(null)

  // Alta de producto
  const [name, setName] = useState('')
  const [categoryId, setCategoryId] = useState('')
  const [unit, setUnit] = useState('unidad')
  const [minStock, setMinStock] = useState(0)
  const [salePrice, setSalePrice] = useState(0)
  const [busy, setBusy] = useState(false)

  const reload = useCallback(() => {
    return fetchProducts()
      .then(setProducts)
      .catch((e: Error) => setError(e.message))
  }, [])

  useEffect(() => {
    fetchCategories()
      .then((cats) => {
        setCategories(cats)
        setCategoryId((prev) => prev || cats[0]?.id || '')
      })
      .catch((e: Error) => setError(e.message))
    void reload()
  }, [reload])

  async function handleCreate() {
    if (!name.trim() || !categoryId) {
      setError('Nombre y categoría son obligatorios')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await createProduct({ name: name.trim(), categoryId, unit, minStock, salePrice })
      setName('')
      setMinStock(0)
      setSalePrice(0)
      await reload()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div>
      {error && (
        <p className="mb-3 rounded bg-red-50 p-2 text-sm text-red-700">{error}</p>
      )}

      {/* Alta de producto */}
      <div className="mb-6 rounded border border-slate-200 p-4">
        <h3 className="mb-3 font-semibold text-slate-700">Nuevo producto</h3>
        <div className="grid grid-cols-2 gap-2 sm:grid-cols-6">
          <input
            placeholder="Nombre"
            value={name}
            onChange={(e) => setName(e.target.value)}
            className="col-span-2 rounded border border-slate-300 p-2"
          />
          <select
            value={categoryId}
            onChange={(e) => setCategoryId(e.target.value)}
            className="rounded border border-slate-300 p-2"
          >
            {categories.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </select>
          <input
            placeholder="Unidad"
            value={unit}
            onChange={(e) => setUnit(e.target.value)}
            className="rounded border border-slate-300 p-2"
          />
          <input
            type="number"
            min={0}
            placeholder="Stock mín."
            value={minStock}
            onChange={(e) => setMinStock(Math.max(0, Number(e.target.value)))}
            className="rounded border border-slate-300 p-2"
          />
          <input
            type="number"
            min={0}
            step="0.01"
            placeholder="Precio venta"
            value={salePrice}
            onChange={(e) => setSalePrice(Math.max(0, Number(e.target.value)))}
            className="rounded border border-slate-300 p-2"
          />
        </div>
        <p className="mt-1 text-xs text-slate-400">
          El precio de venta (&gt; 0) habilita el producto para cargarlo al
          minibar de un huésped.
        </p>
        <button
          type="button"
          disabled={busy}
          onClick={handleCreate}
          className="mt-3 rounded bg-slate-700 px-4 py-2 text-sm font-medium text-white hover:bg-slate-800 disabled:opacity-50"
        >
          Agregar producto
        </button>
      </div>

      {/* Catálogo */}
      <div className="overflow-x-auto rounded border border-slate-200">
        <table className="w-full text-left text-sm">
          <thead className="bg-slate-100 text-slate-600">
            <tr>
              <th className="p-3">Producto</th>
              <th className="p-3">Categoría</th>
              <th className="p-3">Unidad</th>
              <th className="p-3 text-right">Stock</th>
              <th className="p-3 text-right">Mínimo</th>
              <th className="p-3 text-right">Venta (Bs)</th>
            </tr>
          </thead>
          <tbody>
            {products.map((p) => (
              <tr
                key={p.id}
                className={`border-t border-slate-100 ${
                  isBelowMin(p) ? 'bg-red-50' : ''
                }`}
              >
                <td className="p-3 font-medium">{p.name}</td>
                <td className="p-3">{p.categoryName}</td>
                <td className="p-3">{p.unit}</td>
                <td className="p-3 text-right">{p.currentStock}</td>
                <td className="p-3 text-right text-slate-400">{p.minStock}</td>
                <td className="p-3 text-right">
                  {p.salePriceBs > 0 ? p.salePriceBs.toFixed(2) : '—'}
                </td>
              </tr>
            ))}
            {products.length === 0 && (
              <tr>
                <td colSpan={6} className="p-4 text-center text-slate-400">
                  Sin productos aún.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  )
}
