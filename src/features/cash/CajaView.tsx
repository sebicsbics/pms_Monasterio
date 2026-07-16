import { useCallback, useEffect, useState } from 'react'
import {
  ArrowDownCircle,
  ArrowUpCircle,
  Paperclip,
  Receipt,
} from 'lucide-react'
import {
  addCashMovement,
  closeCashSession,
  fetchMovements,
  fetchOpenSession,
  fetchSessions,
  openCashSession,
  receiptUrl,
  voidMovement,
} from '../../services/cash'
import { fetchPaymentMethods } from '../../services/payments'
import type { PaymentMethod } from '../../domain/payments/paymentMethod'
import {
  categoryLabel,
  EXPENSE_CATEGORIES,
  INCOME_CATEGORIES,
  type CashMovement,
  type CashSession,
  type MovementKind,
} from '../../domain/cash/cash'
import { Badge, Button, Card, PageHeader } from '../../components/ui'
import type { UserRole } from '../../domain/auth/profile'

const fmtBs = (n: number) => `${n.toLocaleString('es-BO', { minimumFractionDigits: 2, maximumFractionDigits: 2 })} Bs`
const fmtDateTime = (iso: string) =>
  new Date(iso).toLocaleString('es-BO', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' })

const INPUT = 'w-full rounded-lg border border-slate-300 p-2'

export function CajaView({ role }: { role?: UserRole | null }) {
  const [session, setSession] = useState<CashSession | null>(null)
  const [movements, setMovements] = useState<CashMovement[]>([])
  const [history, setHistory] = useState<CashSession[]>([])
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const isMgmt = role === 'root' || role === 'accountant'

  // Apertura
  const [opening, setOpening] = useState('')
  // Movimiento
  const [kind, setKind] = useState<MovementKind>('expense')
  const [category, setCategory] = useState('compras')
  const [amount, setAmount] = useState('')
  const [concept, setConcept] = useState('')
  const [receipt, setReceipt] = useState<File | null>(null)
  const [paymentMethods, setPaymentMethods] = useState<PaymentMethod[]>([])
  const [paymentMethod, setPaymentMethod] = useState('')
  // Cierre
  const [closing, setClosing] = useState(false)
  const [counted, setCounted] = useState('')
  const [closeNotes, setCloseNotes] = useState('')

  const reload = useCallback(async () => {
    const s = await fetchOpenSession()
    setSession(s)
    setMovements(s ? await fetchMovements(s.id) : [])
    if (isMgmt) setHistory(await fetchSessions())
  }, [isMgmt])

  useEffect(() => {
    reload()
      .catch((e: Error) => setError(e.message))
      .finally(() => setLoading(false))
  }, [reload])

  useEffect(() => {
    fetchPaymentMethods()
      .then((methods) => {
        setPaymentMethods(methods)
        setPaymentMethod((current) => current || (methods[0]?.code ?? ''))
      })
      .catch((e: Error) => setError(e.message))
  }, [])

  async function run(action: () => Promise<void>) {
    setBusy(true)
    setError(null)
    try {
      await action()
      await reload()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  function switchKind(k: MovementKind) {
    setKind(k)
    setCategory(k === 'income' ? 'cobro_habitacion' : 'compras')
  }

  const live = movements.filter((m) => !m.voided)
  const totalIncome = live.filter((m) => m.kind === 'income').reduce((s, m) => s + m.amountBs, 0)
  const totalExpense = live.filter((m) => m.kind === 'expense').reduce((s, m) => s + m.amountBs, 0)
  const expected = (session?.openingBalanceBs ?? 0) + totalIncome - totalExpense

  function handleAdd() {
    const amt = Number(amount)
    if (!(amt > 0)) {
      setError('El monto debe ser mayor a 0')
      return
    }
    run(async () => {
      await addCashMovement({
        kind,
        category,
        amount: amt,
        concept: concept.trim(),
        receipt,
        paymentMethod: paymentMethod || null,
      })
      setAmount('')
      setConcept('')
      setReceipt(null)
    })
  }

  function handleClose() {
    const c = Number(counted)
    if (!(c >= 0)) {
      setError('Ingresá el efectivo contado')
      return
    }
    run(async () => {
      await closeCashSession(c, closeNotes.trim())
      setClosing(false)
      setCounted('')
      setCloseNotes('')
    })
  }

  async function openReceipt(path: string) {
    const url = await receiptUrl(path)
    if (url) window.open(url, '_blank', 'noopener')
  }

  async function handleVoid(m: CashMovement) {
    const reason = window.prompt('Motivo de la anulación:')
    if (!reason) return
    await run(() => voidMovement(m.id, reason))
  }

  if (loading) return <p className="p-8 text-slate-500">Cargando caja…</p>

  const categories = kind === 'income' ? INCOME_CATEGORIES : EXPENSE_CATEGORIES
  const countedDiff = Number(counted) - expected

  return (
    <div className="mx-auto max-w-5xl p-6">
      <PageHeader
        title="Caja chica"
        subtitle="Ingresos, egresos y cierre de caja"
      />

      {error && <p className="mb-4 rounded bg-red-50 p-2 text-sm text-red-700">{error}</p>}

      {!session ? (
        /* ---------- Caja cerrada: abrir ---------- */
        <Card className="max-w-md p-6">
          <h3 className="mb-1 font-semibold text-slate-800">No hay caja abierta</h3>
          <p className="mb-4 text-sm text-slate-500">
            Abrí la caja con el fondo inicial en efectivo para empezar el turno.
          </p>
          <label className="mb-3 block text-sm">
            <span className="mb-1 block text-xs font-medium text-slate-500">Fondo inicial (Bs)</span>
            <input
              type="number" min={0} step="0.01" value={opening}
              onChange={(e) => setOpening(e.target.value)}
              className={INPUT} placeholder="0.00"
            />
          </label>
          <Button
            loading={busy}
            onClick={() => run(() => openCashSession(Number(opening) || 0))}
          >
            Abrir caja
          </Button>
        </Card>
      ) : (
        <>
          {/* ---------- Resumen ---------- */}
          <div className="mb-6 grid grid-cols-2 gap-3 md:grid-cols-4">
            <Card className="p-4">
              <p className="text-xs uppercase tracking-wide text-slate-500">Fondo inicial</p>
              <p className="tabular mt-1 text-lg font-bold text-slate-800">{fmtBs(session.openingBalanceBs)}</p>
            </Card>
            <Card className="p-4">
              <p className="text-xs uppercase tracking-wide text-slate-500">Ingresos</p>
              <p className="tabular mt-1 text-lg font-bold text-green-700">+{fmtBs(totalIncome)}</p>
            </Card>
            <Card className="p-4">
              <p className="text-xs uppercase tracking-wide text-slate-500">Egresos</p>
              <p className="tabular mt-1 text-lg font-bold text-red-600">−{fmtBs(totalExpense)}</p>
            </Card>
            <Card className="p-4">
              <p className="text-xs uppercase tracking-wide text-slate-500">Saldo esperado</p>
              <p className="tabular mt-1 text-lg font-bold text-brand-700">{fmtBs(expected)}</p>
            </Card>
          </div>

          <div className="mb-2 flex items-center justify-between">
            <p className="text-sm text-slate-500">
              Caja abierta {fmtDateTime(session.openedAt)}
            </p>
            <Button variant="secondary" onClick={() => setClosing((v) => !v)}>
              {closing ? 'Cancelar cierre' : 'Cerrar caja'}
            </Button>
          </div>

          {/* ---------- Cierre ---------- */}
          {closing && (
            <Card className="mb-6 p-4">
              <h3 className="mb-3 font-semibold text-slate-800">Cierre de caja</h3>
              <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
                <label className="block text-sm">
                  <span className="mb-1 block text-xs font-medium text-slate-500">Efectivo contado (Bs)</span>
                  <input type="number" min={0} step="0.01" value={counted}
                    onChange={(e) => setCounted(e.target.value)} className={INPUT} placeholder="0.00" />
                </label>
                <div className="text-sm">
                  <span className="mb-1 block text-xs font-medium text-slate-500">Diferencia</span>
                  <p className={`tabular rounded-lg p-2 font-semibold ${
                    counted === '' ? 'bg-slate-50 text-slate-400'
                      : Math.abs(countedDiff) < 0.01 ? 'bg-green-50 text-green-700'
                      : 'bg-amber-50 text-amber-700'
                  }`}>
                    {counted === '' ? '—'
                      : Math.abs(countedDiff) < 0.01 ? 'Cuadra ✓'
                      : `${countedDiff > 0 ? 'Sobrante' : 'Faltante'} ${fmtBs(Math.abs(countedDiff))}`}
                  </p>
                </div>
                <textarea placeholder="Notas del cierre (opcional)" value={closeNotes}
                  onChange={(e) => setCloseNotes(e.target.value)} rows={2}
                  className={`${INPUT} sm:col-span-2`} />
              </div>
              <Button loading={busy} onClick={handleClose} className="mt-3">
                Confirmar cierre
              </Button>
            </Card>
          )}

          {/* ---------- Registrar movimiento ---------- */}
          <Card className="mb-6 p-4">
            <div className="mb-3 flex gap-2">
              <button type="button" onClick={() => switchKind('expense')}
                className={`flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-sm font-medium ${
                  kind === 'expense' ? 'bg-red-600 text-white' : 'bg-slate-100 text-slate-600'}`}>
                <ArrowUpCircle size={16} /> Egreso
              </button>
              <button type="button" onClick={() => switchKind('income')}
                className={`flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-sm font-medium ${
                  kind === 'income' ? 'bg-green-600 text-white' : 'bg-slate-100 text-slate-600'}`}>
                <ArrowDownCircle size={16} /> Ingreso
              </button>
            </div>
            <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
              <label className="block text-sm">
                <span className="mb-1 block text-xs font-medium text-slate-500">Categoría</span>
                <select value={category} onChange={(e) => setCategory(e.target.value)} className={INPUT}>
                  {Object.entries(categories).map(([code, label]) => (
                    <option key={code} value={code}>{label}</option>
                  ))}
                </select>
              </label>
              <label className="block text-sm">
                <span className="mb-1 block text-xs font-medium text-slate-500">Monto (Bs)</span>
                <input type="number" min={0} step="0.01" value={amount}
                  onChange={(e) => setAmount(e.target.value)} className={INPUT} placeholder="0.00" />
              </label>
              <label className="col-span-2 block text-sm">
                <span className="mb-1 block text-xs font-medium text-slate-500">Concepto</span>
                <input value={concept} onChange={(e) => setConcept(e.target.value)}
                  className={INPUT} placeholder="Detalle del movimiento" />
              </label>
              <label className="block text-sm">
                <span className="mb-1 block text-xs font-medium text-slate-500">Forma de pago</span>
                <select value={paymentMethod} onChange={(e) => setPaymentMethod(e.target.value)} className={INPUT}>
                  {paymentMethods.map((m) => (
                    <option key={m.code} value={m.code}>{m.label}</option>
                  ))}
                </select>
              </label>
            </div>
            <div className="mt-3 flex flex-wrap items-center gap-3">
              <label className="flex cursor-pointer items-center gap-2 text-sm text-slate-600">
                <Paperclip size={16} />
                {receipt ? receipt.name : 'Adjuntar recibo/factura (opcional)'}
                <input type="file" accept="image/*" className="hidden"
                  onChange={(e) => setReceipt(e.target.files?.[0] ?? null)} />
              </label>
              <Button loading={busy} onClick={handleAdd} className="ml-auto">
                Registrar {kind === 'income' ? 'ingreso' : 'egreso'}
              </Button>
            </div>
          </Card>

          {/* ---------- Movimientos ---------- */}
          <h3 className="mb-2 font-semibold text-slate-700">Movimientos del turno</h3>
          <div className="space-y-2">
            {live.length === 0 && movements.length === 0 && (
              <p className="text-sm text-slate-400">Sin movimientos todavía.</p>
            )}
            {movements.map((m) => (
              <Card key={m.id} className={`flex items-center gap-3 p-3 ${m.voided ? 'opacity-50' : ''}`}>
                {m.kind === 'income'
                  ? <ArrowDownCircle className="shrink-0 text-green-600" size={20} />
                  : <ArrowUpCircle className="shrink-0 text-red-600" size={20} />}
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-medium text-slate-800">
                    {categoryLabel(m.kind, m.category)}
                    {m.concept && <span className="font-normal text-slate-500"> · {m.concept}</span>}
                  </p>
                  <p className="text-xs text-slate-400">
                    {fmtDateTime(m.createdAt)}
                    {m.paymentMethod && ` · ${paymentMethods.find((p) => p.code === m.paymentMethod)?.label ?? m.paymentMethod}`}
                    {m.voided && ` · anulado: ${m.voidReason ?? ''}`}
                  </p>
                </div>
                {m.receiptPath && (
                  <button type="button" onClick={() => openReceipt(m.receiptPath!)}
                    aria-label="Ver recibo"
                    className="rounded-lg p-1.5 text-slate-400 hover:bg-slate-100 hover:text-slate-700">
                    <Receipt size={18} />
                  </button>
                )}
                <span className={`tabular shrink-0 font-semibold ${
                  m.voided ? 'text-slate-400 line-through'
                    : m.kind === 'income' ? 'text-green-700' : 'text-red-600'}`}>
                  {m.kind === 'income' ? '+' : '−'}{fmtBs(m.amountBs)}
                </span>
                {role === 'root' && !m.voided && (
                  <button type="button" onClick={() => handleVoid(m)}
                    className="text-xs text-slate-400 hover:text-red-600">anular</button>
                )}
              </Card>
            ))}
          </div>
        </>
      )}

      {/* ---------- Historial de cierres (gerencia) ---------- */}
      {isMgmt && history.filter((s) => s.status === 'closed').length > 0 && (
        <div className="mt-8">
          <h3 className="mb-2 font-semibold text-slate-700">Cierres anteriores</h3>
          <Card className="overflow-x-auto">
            <table className="w-full text-left text-sm">
              <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="p-3">Cerrada</th>
                  <th className="p-3 text-right">Fondo</th>
                  <th className="p-3 text-right">Contado</th>
                  <th className="p-3">Estado</th>
                </tr>
              </thead>
              <tbody>
                {history.filter((s) => s.status === 'closed').map((s) => (
                  <tr key={s.id} className="border-t border-slate-100">
                    <td className="p-3 text-slate-600">{s.closedAt ? fmtDateTime(s.closedAt) : '—'}</td>
                    <td className="tabular p-3 text-right">{fmtBs(s.openingBalanceBs)}</td>
                    <td className="tabular p-3 text-right">
                      {s.countedBalanceBs == null ? '—' : fmtBs(s.countedBalanceBs)}
                    </td>
                    <td className="p-3"><Badge tone="neutral">Cerrada</Badge></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </Card>
        </div>
      )}
    </div>
  )
}
