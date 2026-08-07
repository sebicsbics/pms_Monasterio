import { useCallback, useEffect, useState } from 'react'
import type { AnticipoListItem } from '../../domain/anticipos/anticipos'
import { userFacingAnticipoError } from '../../domain/anticipos/anticipos'
import { listAnticipos } from '../../services/anticipos'
import { receiptUrl } from '../../services/receipts'
import { Badge, Card } from '../../components/ui'
import { formatDateTime } from '../../lib/date'

const fmtBs = (n: number) => `Bs ${n.toFixed(2)}`

// Estado de la RESERVA, no del anticipo: es lo que le dice a recepción si
// ese adelanto todavía se va a usar o quedó atrás.
const RESERVATION_TONE: Record<string, { label: string; tone: 'success' | 'warning' | 'neutral' }> = {
  confirmed: { label: 'Por llegar', tone: 'success' },
  checked_in: { label: 'En casa', tone: 'success' },
  checked_out: { label: 'Salió', tone: 'neutral' },
  cancelled: { label: 'Cancelada', tone: 'warning' },
}

// Lista de todos los anticipos registrados, con habitación, huésped y
// quién lo cobró. Se refresca desde afuera con `refreshKey` para que, al
// registrar uno nuevo, aparezca sin recargar la página.
export function AnticipoList({ refreshKey = 0 }: { refreshKey?: number }) {
  const [items, setItems] = useState<AnticipoListItem[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [onlyActive, setOnlyActive] = useState(false)

  const load = useCallback(() => {
    setLoading(true)
    return listAnticipos(onlyActive)
      .then(setItems)
      .catch((e: Error) => setError(userFacingAnticipoError(e.message)))
      .finally(() => setLoading(false))
  }, [onlyActive])

  useEffect(() => {
    void load()
  }, [load, refreshKey])

  async function openReceipt(path: string) {
    const url = await receiptUrl(path)
    if (url) window.open(url, '_blank', 'noopener')
  }

  const totalActive = items
    .filter((a) => a.status === 'active')
    .reduce((s, a) => s + a.amountBs, 0)

  return (
    <div className="mt-8">
      <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
        <h3 className="font-semibold text-slate-700">Anticipos registrados</h3>
        <label className="flex items-center gap-2 text-xs text-slate-600">
          <input
            type="checkbox"
            checked={onlyActive}
            onChange={(e) => setOnlyActive(e.target.checked)}
          />
          Sólo vigentes
        </label>
      </div>

      {error && <p className="mb-3 rounded bg-red-50 p-2 text-sm text-red-700">{error}</p>}

      {loading ? (
        <p className="text-sm text-slate-400">Cargando anticipos…</p>
      ) : items.length === 0 ? (
        <p className="text-sm text-slate-400">No hay anticipos registrados.</p>
      ) : (
        <>
          <p className="mb-2 text-sm text-slate-500">
            {items.length} anticipo(s) · vigentes:{' '}
            <span className="tabular font-medium text-slate-700">{fmtBs(totalActive)}</span>
          </p>
          <Card className="overflow-x-auto">
            <table className="w-full text-left text-sm">
              <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="p-3">Hab.</th>
                  <th className="p-3">Huésped</th>
                  <th className="p-3">Estadía</th>
                  <th className="p-3 text-right">Monto</th>
                  <th className="p-3">Forma de pago</th>
                  <th className="p-3">Cobró</th>
                  <th className="p-3">Reserva</th>
                </tr>
              </thead>
              <tbody>
                {items.map((a) => {
                  const res = RESERVATION_TONE[a.reservationStatus] ?? {
                    label: a.reservationStatus,
                    tone: 'neutral' as const,
                  }
                  return (
                    <tr
                      key={a.id}
                      className={`border-t border-slate-100 align-top ${
                        a.status === 'forfeited' ? 'opacity-60' : ''
                      }`}
                    >
                      <td className="p-3 font-semibold text-slate-800">{a.roomNumber}</td>
                      <td className="p-3">
                        {a.guestName}
                        {a.notes && (
                          <span className="block text-xs text-slate-400">{a.notes}</span>
                        )}
                      </td>
                      <td className="p-3 text-xs text-slate-500">
                        {a.checkInDate} → {a.checkOutDate}
                      </td>
                      <td className="tabular p-3 text-right font-medium">
                        {fmtBs(a.amountBs)}
                        {a.status === 'forfeited' && (
                          <span className="block text-xs font-normal text-amber-700">
                            perdido
                          </span>
                        )}
                      </td>
                      <td className="p-3">
                        {a.paymentMethod}
                        {a.receiptPath && (
                          <button
                            type="button"
                            onClick={() => openReceipt(a.receiptPath!)}
                            className="ml-2 text-xs text-brand-700 hover:underline"
                          >
                            ver comprobante
                          </button>
                        )}
                        {a.paymentReference && (
                          <span className="block text-xs text-slate-400">
                            ref. {a.paymentReference}
                          </span>
                        )}
                      </td>
                      <td className="p-3 text-xs text-slate-500">
                        {a.receivedByName}
                        <span className="block text-slate-400">
                          {formatDateTime(a.receivedAt)}
                        </span>
                      </td>
                      <td className="p-3">
                        <Badge tone={res.tone}>{res.label}</Badge>
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </Card>
        </>
      )}
    </div>
  )
}
