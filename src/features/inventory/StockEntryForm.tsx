import { useEffect, useState } from 'react'
import { X } from 'lucide-react'
import type { Product } from '../../domain/inventory/product'
import { fetchProducts, registerStockEntry } from '../../services/inventory'

interface Line {
  productId: string
  quantity: string
  unitPrice: string
}

const TODAY = new Date().toISOString().slice(0, 10)

export function StockEntryForm({ onSaved }: { onSaved: () => void }) {
  const [products, setProducts] = useState<Product[]>([])
  const [entryDate, setEntryDate] = useState(TODAY)
  const [isInvoiced, setIsInvoiced] = useState(false)
  const [invoiceNumber, setInvoiceNumber] = useState('')
  const [supplier, setSupplier] = useState('')
  const [notes, setNotes] = useState('')
  const [lines, setLines] = useState<Line[]>([
    { productId: '', quantity: '', unitPrice: '' },
  ])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [success, setSuccess] = useState<string | null>(null)

  useEffect(() => {
    fetchProducts()
      .then(setProducts)
      .catch((e: Error) => setError(e.message))
  }, [])

  function updateLine(i: number, patch: Partial<Line>) {
    setLines((prev) => prev.map((l, idx) => (idx === i ? { ...l, ...patch } : l)))
  }
  function addLine() {
    setLines((prev) => [...prev, { productId: '', quantity: '', unitPrice: '' }])
  }
  function removeLine(i: number) {
    setLines((prev) => prev.filter((_, idx) => idx !== i))
  }

  const total = lines.reduce(
    (sum, l) => sum + (Number(l.quantity) || 0) * (Number(l.unitPrice) || 0),
    0,
  )

  async function handleSave() {
    setError(null)
    setSuccess(null)
    const items = lines
      .filter((l) => l.productId && Number(l.quantity) > 0)
      .map((l) => ({
        productId: l.productId,
        quantity: Number(l.quantity),
        unitPrice: Number(l.unitPrice) || 0,
      }))
    if (items.length === 0) {
      setError('Agregá al menos un producto con cantidad')
      return
    }
    setBusy(true)
    try {
      await registerStockEntry({
        entryDate,
        isInvoiced,
        invoiceNumber,
        supplier,
        notes,
        items,
      })
      setSuccess('Ingreso registrado y stock actualizado.')
      setLines([{ productId: '', quantity: '', unitPrice: '' }])
      setInvoiceNumber('')
      setSupplier('')
      setNotes('')
      setIsInvoiced(false)
      onSaved()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="rounded border border-slate-200 p-4">
      {error && (
        <p className="mb-3 rounded bg-red-50 p-2 text-sm text-red-700">{error}</p>
      )}
      {success && (
        <p className="mb-3 rounded bg-green-50 p-2 text-sm text-green-700">
          {success}
        </p>
      )}

      <div className="mb-4 grid grid-cols-1 gap-3 sm:grid-cols-3">
        <label className="text-sm">
          <span className="text-slate-600">Fecha</span>
          <input
            type="date"
            value={entryDate}
            onChange={(e) => setEntryDate(e.target.value)}
            className="mt-1 w-full rounded border border-slate-300 p-2"
          />
        </label>
        <input
          placeholder="Proveedor (opcional)"
          value={supplier}
          onChange={(e) => setSupplier(e.target.value)}
          className="self-end rounded border border-slate-300 p-2"
        />
        <div className="flex items-end gap-2">
          <label className="flex items-center gap-2 text-sm text-slate-600">
            <input
              type="checkbox"
              checked={isInvoiced}
              onChange={(e) => setIsInvoiced(e.target.checked)}
            />
            Facturado
          </label>
          {isInvoiced && (
            <input
              placeholder="N° factura"
              value={invoiceNumber}
              onChange={(e) => setInvoiceNumber(e.target.value)}
              className="w-full rounded border border-slate-300 p-2"
            />
          )}
        </div>
      </div>

      <h3 className="mb-2 font-semibold text-slate-700">Detalle</h3>
      <div className="space-y-2">
        {lines.map((line, i) => (
          <div key={i} className="flex gap-2">
            <select
              value={line.productId}
              onChange={(e) => updateLine(i, { productId: e.target.value })}
              className="w-1/2 rounded border border-slate-300 p-2 text-sm"
            >
              <option value="">Producto…</option>
              {products.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.name} ({p.unit})
                </option>
              ))}
            </select>
            <input
              type="number"
              min={0}
              step="0.01"
              placeholder="Cant."
              value={line.quantity}
              onChange={(e) => updateLine(i, { quantity: e.target.value })}
              className="w-1/6 rounded border border-slate-300 p-2 text-sm"
            />
            <input
              type="number"
              min={0}
              step="0.01"
              placeholder="Precio unit."
              value={line.unitPrice}
              onChange={(e) => updateLine(i, { unitPrice: e.target.value })}
              className="w-1/4 rounded border border-slate-300 p-2 text-sm"
            />
            <button
              type="button"
              onClick={() => removeLine(i)}
              aria-label="Quitar renglón"
              className="px-2 text-slate-400 hover:text-red-600"
            >
              <X size={16} />
            </button>
          </div>
        ))}
      </div>

      <button
        type="button"
        onClick={addLine}
        className="mt-2 text-sm text-blue-600 hover:underline"
      >
        + Agregar renglón
      </button>

      <div className="mt-4 flex items-center justify-between">
        <span className="font-bold text-slate-800">
          Total: {total.toFixed(2)} Bs
        </span>
        <button
          type="button"
          disabled={busy}
          onClick={handleSave}
          className="rounded bg-green-600 px-4 py-2 font-medium text-white hover:bg-green-700 disabled:opacity-50"
        >
          {busy ? 'Guardando…' : 'Registrar ingreso'}
        </button>
      </div>

      <textarea
        placeholder="Notas (opcional)"
        value={notes}
        onChange={(e) => setNotes(e.target.value)}
        className="mt-3 w-full rounded border border-slate-300 p-2 text-sm"
        rows={2}
      />
    </div>
  )
}
