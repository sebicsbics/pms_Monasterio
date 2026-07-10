import { useState } from 'react'
import { ProductsPanel } from './ProductsPanel'
import { StockEntryForm } from './StockEntryForm'
import { LowStockPanel } from './LowStockPanel'
import { PageHeader } from '../../components/ui'

type Sub = 'products' | 'entry' | 'low'

export function InventoryView() {
  const [sub, setSub] = useState<Sub>('products')
  // clave para forzar recarga de sub-paneles tras registrar un ingreso
  const [refreshKey, setRefreshKey] = useState(0)

  const tabs: { id: Sub; label: string }[] = [
    { id: 'products', label: 'Productos' },
    { id: 'entry', label: 'Registrar ingreso' },
    { id: 'low', label: 'Reposición' },
  ]

  return (
    <div className="mx-auto max-w-5xl p-6">
      <PageHeader title="Inventario" />

      <div className="mb-6 flex gap-2 border-b border-slate-200">
        {tabs.map((t) => (
          <button
            key={t.id}
            type="button"
            onClick={() => setSub(t.id)}
            className={`-mb-px px-3 py-2 text-sm font-medium ${
              sub === t.id
                ? 'border-b-2 border-brand-600 text-brand-700'
                : 'text-slate-500 hover:text-slate-700'
            }`}
          >
            {t.label}
          </button>
        ))}
      </div>

      {sub === 'products' && <ProductsPanel key={`p-${refreshKey}`} />}
      {sub === 'entry' && (
        <StockEntryForm onSaved={() => setRefreshKey((k) => k + 1)} />
      )}
      {sub === 'low' && <LowStockPanel key={`l-${refreshKey}`} />}
    </div>
  )
}
