import { useEffect, useState } from 'react'
import { Trash2 } from 'lucide-react'
import {
  addTicketPart,
  deleteTicketPart,
  fetchTicketParts,
} from '../../services/maintenance'
import type { TicketPart } from '../../domain/maintenance/ticket'

const fmtBs = (n: number) => `${Math.round(n).toLocaleString('es-BO')} Bs`

// Panel de repuestos/gasto de un ticket. onChange avisa al padre para refrescar
// el total mostrado en la tarjeta.
export function TicketParts({
  ticketId,
  onChange,
}: {
  ticketId: string
  onChange: () => void
}) {
  const [parts, setParts] = useState<TicketPart[]>([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [desc, setDesc] = useState('')
  const [qty, setQty] = useState('1')
  const [cost, setCost] = useState('')

  function reload() {
    return fetchTicketParts(ticketId)
      .then(setParts)
      .catch((e: Error) => setError(e.message))
  }

  useEffect(() => {
    reload()
  }, [ticketId]) // eslint-disable-line react-hooks/exhaustive-deps

  async function run(action: () => Promise<void>) {
    setBusy(true)
    setError(null)
    try {
      await action()
      await reload()
      onChange()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  function handleAdd() {
    const q = Number(qty)
    const c = Number(cost)
    if (!desc.trim() || !(q > 0) || !(c >= 0)) {
      setError('Descripción, cantidad > 0 y costo válido son obligatorios')
      return
    }
    run(async () => {
      await addTicketPart(ticketId, { description: desc.trim(), quantity: q, unitCostBs: c })
      setDesc('')
      setQty('1')
      setCost('')
    })
  }

  const total = parts.reduce((s, p) => s + p.lineTotalBs, 0)

  return (
    <div className="mt-3 rounded border border-slate-200 bg-slate-50 p-3">
      <h4 className="mb-2 text-xs font-semibold uppercase tracking-wide text-slate-500">
        Repuestos y gasto
      </h4>
      {error && <p className="mb-2 text-xs text-red-600">{error}</p>}

      {parts.length > 0 && (
        <div className="mb-2 space-y-1">
          {parts.map((p) => (
            <div key={p.id} className="flex items-center justify-between text-sm text-slate-600">
              <span>
                {p.description} · {p.quantity} × {fmtBs(p.unitCostBs)}
              </span>
              <span className="flex items-center gap-2">
                <span className="font-medium">{fmtBs(p.lineTotalBs)}</span>
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => run(() => deleteTicketPart(p.id))}
                  className="text-slate-400 hover:text-red-600"
                  aria-label="Quitar repuesto"
                >
                  <Trash2 size={14} />
                </button>
              </span>
            </div>
          ))}
          <div className="flex justify-between border-t border-slate-200 pt-1 text-sm font-bold text-slate-800">
            <span>Total</span>
            <span>{fmtBs(total)}</span>
          </div>
        </div>
      )}

      <div className="flex flex-wrap gap-2">
        <input
          placeholder="Repuesto (ej: capacitor, filtro)"
          value={desc}
          onChange={(e) => setDesc(e.target.value)}
          className="min-w-40 flex-1 rounded border border-slate-300 p-1.5 text-sm"
        />
        <input
          type="number" min={0} step="0.01" placeholder="Cant."
          value={qty}
          onChange={(e) => setQty(e.target.value)}
          className="w-16 rounded border border-slate-300 p-1.5 text-sm"
        />
        <input
          type="number" min={0} step="0.01" placeholder="Costo unit. Bs"
          value={cost}
          onChange={(e) => setCost(e.target.value)}
          className="w-28 rounded border border-slate-300 p-1.5 text-sm"
        />
        <button
          type="button"
          disabled={busy}
          onClick={handleAdd}
          className="rounded bg-slate-700 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 disabled:opacity-50"
        >
          Agregar
        </button>
      </div>
    </div>
  )
}
