import { useCallback, useEffect, useState } from 'react'
import { Plus } from 'lucide-react'
import type { Product, ProductCategory } from '../../domain/inventory/product'
import { isBelowMin } from '../../domain/inventory/product'
import {
  fetchProducts,
  fetchCategories,
  createProduct,
  createCategory,
} from '../../services/inventory'
import { Button, Card } from '../../components/ui'

// Etiqueta reutilizable: etiqueta visible, no placeholder-only (así se sabe qué
// es cada campo aunque muestre 0).
function Labeled({
  label,
  className = '',
  children,
}: {
  label: string
  className?: string
  children: React.ReactNode
}) {
  return (
    <label className={`block text-sm ${className}`}>
      <span className="mb-1 block text-xs font-medium text-slate-500">{label}</span>
      {children}
    </label>
  )
}

const INPUT = 'w-full rounded-lg border border-slate-300 p-2'

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

  // Alta de tipo de producto (categoría)
  const [addingCat, setAddingCat] = useState(false)
  const [newCat, setNewCat] = useState('')

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

  async function handleAddCategory() {
    const n = newCat.trim()
    if (!n) return
    setError(null)
    try {
      const cat = await createCategory(n)
      setCategories((cs) => [...cs, cat].sort((a, b) => a.name.localeCompare(b.name)))
      setCategoryId(cat.id) // seleccionar la recién creada
      setNewCat('')
      setAddingCat(false)
    } catch (e) {
      setError((e as Error).message)
    }
  }

  async function handleCreate() {
    if (!name.trim() || !categoryId) {
      setError('Nombre y tipo de producto son obligatorios')
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
      <Card className="mb-6 p-4">
        <h3 className="mb-3 font-semibold text-slate-700">Nuevo producto</h3>
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-6">
          <Labeled label="Nombre" className="col-span-2">
            <input
              placeholder="Ej: Agua mineral 500ml"
              value={name}
              onChange={(e) => setName(e.target.value)}
              className={INPUT}
            />
          </Labeled>

          <Labeled label="Tipo de producto" className="col-span-2">
            <div className="flex gap-1">
              <select
                value={categoryId}
                onChange={(e) => setCategoryId(e.target.value)}
                className={INPUT}
              >
                {categories.map((c) => (
                  <option key={c.id} value={c.id}>{c.name}</option>
                ))}
              </select>
              <button
                type="button"
                onClick={() => setAddingCat((v) => !v)}
                aria-label="Agregar tipo de producto"
                title="Agregar tipo"
                className="shrink-0 rounded-lg border border-slate-300 px-2 text-slate-600 hover:bg-slate-50"
              >
                <Plus size={16} />
              </button>
            </div>
          </Labeled>

          <Labeled label="Unidad">
            <input
              placeholder="unidad, kg, litro…"
              value={unit}
              onChange={(e) => setUnit(e.target.value)}
              className={INPUT}
            />
          </Labeled>

          <Labeled label="Stock mínimo">
            <input
              type="number"
              min={0}
              value={minStock}
              onChange={(e) => setMinStock(Math.max(0, Number(e.target.value)))}
              className={INPUT}
            />
          </Labeled>

          <Labeled label="Precio de venta (Bs)">
            <input
              type="number"
              min={0}
              step="0.01"
              value={salePrice}
              onChange={(e) => setSalePrice(Math.max(0, Number(e.target.value)))}
              className={INPUT}
            />
          </Labeled>
        </div>

        {/* Alta inline de tipo de producto */}
        {addingCat && (
          <div className="mt-3 flex flex-wrap items-center gap-2 rounded-lg bg-slate-50 p-3">
            <input
              autoFocus
              placeholder="Nombre del nuevo tipo (ej: Limpieza)"
              value={newCat}
              onChange={(e) => setNewCat(e.target.value)}
              onKeyDown={(e) => e.key === 'Enter' && handleAddCategory()}
              className="min-w-52 flex-1 rounded-lg border border-slate-300 p-2 text-sm"
            />
            <Button size="sm" onClick={handleAddCategory}>Crear tipo</Button>
            <Button
              size="sm"
              variant="ghost"
              onClick={() => {
                setAddingCat(false)
                setNewCat('')
              }}
            >
              Cancelar
            </Button>
          </div>
        )}

        <p className="mt-2 text-xs text-slate-400">
          El <strong>stock mínimo</strong> dispara el aviso de reposición. El{' '}
          <strong>precio de venta</strong> (&gt; 0) habilita el producto para
          cargarlo al minibar de un huésped.
        </p>

        <Button loading={busy} onClick={handleCreate} className="mt-3">
          Agregar producto
        </Button>
      </Card>

      {/* Catálogo */}
      <Card className="overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead className="bg-slate-50 text-slate-600">
            <tr>
              <th className="p-3">Producto</th>
              <th className="p-3">Tipo</th>
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
                className={`border-t border-slate-100 ${isBelowMin(p) ? 'bg-red-50' : ''}`}
              >
                <td className="p-3 font-medium">{p.name}</td>
                <td className="p-3">{p.categoryName}</td>
                <td className="p-3">{p.unit}</td>
                <td className="p-3 text-right tabular">{p.currentStock}</td>
                <td className="p-3 text-right tabular text-slate-400">{p.minStock}</td>
                <td className="p-3 text-right tabular">
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
      </Card>
    </div>
  )
}
