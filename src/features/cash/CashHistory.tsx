import { useCallback, useEffect, useState } from 'react'
import {
  differenceWithOtherMeansBs,
  expectedWithOtherMeansBs,
  type CashSessionSummary,
} from '../../domain/cash/cash'
import { fetchCashSessionHistory } from '../../services/cash'
import { Badge, Card, PrintButton } from '../../components/ui'
import { useRef } from 'react'

const fmtBs = (n: number) =>
  n.toLocaleString('es-BO', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
const fmtDateTime = (iso: string) =>
  new Date(iso).toLocaleString('es-BO', {
    day: '2-digit', month: '2-digit', year: '2-digit',
    hour: '2-digit', minute: '2-digit',
  })

// Primer y último día del mes actual: el arqueo mensual es el caso de uso
// principal, así que es el rango por defecto.
function monthRange(): { from: string; to: string } {
  const now = new Date()
  const first = new Date(now.getFullYear(), now.getMonth(), 1)
  const last = new Date(now.getFullYear(), now.getMonth() + 1, 0)
  const iso = (d: Date) =>
    `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
  return { from: iso(first), to: iso(last) }
}

function DiffCell({ value }: { value: number | null }) {
  if (value === null) return <span className="text-slate-400">—</span>
  const balanced = Math.abs(value) < 0.01
  return (
    <span
      className={`tabular font-semibold ${
        balanced ? 'text-green-700' : value > 0 ? 'text-amber-700' : 'text-red-600'
      }`}
    >
      {balanced ? '0.00' : `${value > 0 ? '+' : ''}${fmtBs(value)}`}
    </span>
  )
}

// Historial de turnos de caja para el arqueo mensual (root, admin de
// recepción y contadora).
//
// Se muestran DOS esperados a propósito. El criterio cambió cuando se
// separó el efectivo de QR/depósito/tarjeta: los turnos cerrados antes de
// ese cambio se arquearon sumando todo, y evaluarlos sólo por efectivo
// haría aparecer descuadres de cientos de bolivianos en turnos que
// cerraron cuadrados — señalando a una persona por un cambio de fórmula.
export function CashHistory() {
  const [{ from, to }, setRange] = useState(monthRange)
  const [rows, setRows] = useState<CashSessionSummary[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const tableRef = useRef<HTMLDivElement>(null)

  const load = useCallback(() => {
    setLoading(true)
    return fetchCashSessionHistory(from || null, to || null)
      .then(setRows)
      .catch((e: Error) => setError(e.message))
      .finally(() => setLoading(false))
  }, [from, to])

  useEffect(() => {
    void load()
  }, [load])

  const closed = rows.filter((r) => r.status === 'closed')
  const totalCashIn = closed.reduce((s, r) => s + r.cashIncomeBs, 0)
  const totalCashOut = closed.reduce((s, r) => s + r.cashExpenseBs, 0)
  const totalOtherIn = closed.reduce((s, r) => s + r.otherIncomeBs, 0)
  const offCount = closed.filter(
    (r) => r.differenceBs !== null && Math.abs(r.differenceBs) >= 0.01,
  ).length

  return (
    <div className="mt-8">
      <div className="mb-3 flex flex-wrap items-end justify-between gap-3">
        <h3 className="font-semibold text-slate-700">Historial de caja · arqueo</h3>
        <div className="flex flex-wrap items-end gap-2">
          <label className="text-xs font-medium text-slate-500">
            Desde
            <input
              type="date" value={from} max={to}
              onChange={(e) => setRange((r) => ({ ...r, from: e.target.value }))}
              className="mt-1 block rounded border border-slate-300 p-2 text-sm text-slate-700"
            />
          </label>
          <label className="text-xs font-medium text-slate-500">
            Hasta
            <input
              type="date" value={to} min={from}
              onChange={(e) => setRange((r) => ({ ...r, to: e.target.value }))}
              className="mt-1 block rounded border border-slate-300 p-2 text-sm text-slate-700"
            />
          </label>
          <button
            type="button"
            onClick={() => setRange(monthRange())}
            className="rounded border border-slate-300 px-3 py-2 text-xs font-medium text-slate-600 hover:bg-slate-50"
          >
            Este mes
          </button>
          {rows.length > 0 && (
            <PrintButton
              targetRef={tableRef}
              title={`Arqueo de caja ${from} a ${to}`}
              label="Imprimir"
              className="!px-3 !py-2 text-xs"
            />
          )}
        </div>
      </div>

      {error && <p className="mb-3 rounded bg-red-50 p-2 text-sm text-red-700">{error}</p>}

      {loading ? (
        <p className="text-sm text-slate-400">Cargando historial…</p>
      ) : rows.length === 0 ? (
        <p className="text-sm text-slate-400">No hay turnos de caja en ese rango.</p>
      ) : (
        <div ref={tableRef}>
          <p className="mb-2 text-sm text-slate-500">
            {closed.length} turno(s) cerrado(s) · Ingresos en efectivo{' '}
            <span className="tabular font-medium">{fmtBs(totalCashIn)} Bs</span> · Egresos{' '}
            <span className="tabular font-medium">{fmtBs(totalCashOut)} Bs</span> · Otros medios{' '}
            <span className="tabular font-medium">{fmtBs(totalOtherIn)} Bs</span>
            {offCount > 0 && (
              <span className="text-amber-700"> · {offCount} con diferencia</span>
            )}
          </p>

          <Card className="overflow-x-auto">
            <table className="w-full text-left text-sm">
              <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="p-3">Abrió</th>
                  <th className="p-3">Cerró</th>
                  <th className="p-3 text-right">Fondo</th>
                  <th className="p-3 text-right">Esperado efectivo</th>
                  <th className="p-3 text-right">Esperado + otros</th>
                  <th className="p-3 text-right">Contado</th>
                  <th className="p-3 text-right">Dif. efectivo</th>
                  <th className="p-3 text-right">Dif. total</th>
                  <th className="p-3">Justificación</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.id} className="border-t border-slate-100 align-top">
                    <td className="p-3">
                      <span className="font-medium text-slate-800">{r.openedByName}</span>
                      <span className="block text-xs text-slate-400">
                        {fmtDateTime(r.openedAt)}
                      </span>
                    </td>
                    <td className="p-3">
                      {r.status === 'open' ? (
                        <Badge tone="success">Abierta</Badge>
                      ) : (
                        <>
                          <span className="font-medium text-slate-800">
                            {r.closedByName ?? '—'}
                          </span>
                          <span className="block text-xs text-slate-400">
                            {r.closedAt ? fmtDateTime(r.closedAt) : '—'}
                          </span>
                        </>
                      )}
                    </td>
                    <td className="tabular p-3 text-right">{fmtBs(r.openingBalanceBs)}</td>
                    <td className="tabular p-3 text-right">{fmtBs(r.expectedBs)}</td>
                    <td className="tabular p-3 text-right text-slate-500">
                      {fmtBs(expectedWithOtherMeansBs(r))}
                    </td>
                    <td className="tabular p-3 text-right">
                      {r.countedBalanceBs == null ? '—' : fmtBs(r.countedBalanceBs)}
                    </td>
                    <td className="p-3 text-right"><DiffCell value={r.differenceBs} /></td>
                    <td className="p-3 text-right">
                      <DiffCell value={differenceWithOtherMeansBs(r)} />
                    </td>
                    <td className="max-w-[16rem] p-3 text-xs text-slate-500">
                      {r.notes || <span className="text-slate-300">—</span>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </Card>

          <p className="mt-2 text-xs text-slate-500">
            <span className="font-medium">Dif. efectivo</span> compara lo contado contra el
            efectivo del cajón. <span className="font-medium">Dif. total</span> incluye
            además QR, depósito y tarjeta: es el criterio con el que se cerraron los turnos
            anteriores al 6/8/2026, cuando esos cobros todavía se cargaban a mano en la caja.
          </p>
        </div>
      )}
    </div>
  )
}
