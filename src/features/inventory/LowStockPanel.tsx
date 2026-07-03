import { useEffect, useState } from 'react'
import type { LowStockProduct } from '../../domain/inventory/product'
import { fetchLowStock } from '../../services/inventory'

export function LowStockPanel() {
  const [items, setItems] = useState<LowStockProduct[]>([])
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    fetchLowStock()
      .then(setItems)
      .catch((e: Error) => setError(e.message))
  }, [])

  if (error) return <p className="text-red-600">Error: {error}</p>

  return (
    <div>
      <p className="mb-3 text-sm text-slate-500">
        Productos en o por debajo del mínimo — hay que reponer.
      </p>
      {items.length === 0 ? (
        <p className="text-slate-400">Todo el stock está por encima del mínimo. 👍</p>
      ) : (
        <div className="overflow-x-auto rounded border border-slate-200">
          <table className="w-full text-left text-sm">
            <thead className="bg-slate-100 text-slate-600">
              <tr>
                <th className="p-3">Producto</th>
                <th className="p-3">Categoría</th>
                <th className="p-3 text-right">Stock</th>
                <th className="p-3 text-right">Mínimo</th>
              </tr>
            </thead>
            <tbody>
              {items.map((p) => (
                <tr key={p.id} className="border-t border-slate-100 bg-red-50">
                  <td className="p-3 font-medium">{p.name}</td>
                  <td className="p-3">{p.category}</td>
                  <td className="p-3 text-right font-semibold text-red-700">
                    {p.currentStock} {p.unit}
                  </td>
                  <td className="p-3 text-right text-slate-500">{p.minStock}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}
