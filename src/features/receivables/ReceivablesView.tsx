import { useCallback, useEffect, useState } from 'react'
import {
  ACCOUNT_KIND_LABEL,
  RECEIVABLE_STATUS_LABEL,
  type Receivable,
  type ReceivableAccount,
  type ReceivableAccountKind,
  type ReceivableStatus,
} from '../../domain/receivables/receivable'
import {
  listReceivableAccounts,
  createReceivableAccount,
  listReceivables,
  settleReceivable,
  cancelReceivable,
} from '../../services/receivables'
import type { PaymentMethod } from '../../domain/payments/paymentMethod'
import { fetchPaymentMethods } from '../../services/payments'
import { PageHeader } from '../../components/ui'
import { formatDateTime } from '../../lib/date'
import type { PaymentProof } from '../../domain/payments/paymentProof'
import {
  EMPTY_PAYMENT_PROOF,
  paymentProofError,
} from '../../domain/payments/paymentProof'
import { PaymentProofFields } from '../payments/PaymentProofFields'
import type { MixedPayment } from '../../domain/payments/mixedPayment'
import {
  EMPTY_MIXED_PAYMENT,
  isMixed,
  mixedPaymentError,
} from '../../domain/payments/mixedPayment'
import { MixedPaymentFields } from '../payments/MixedPaymentFields'

const KINDS: ReceivableAccountKind[] = ['empresa', 'agencia', 'persona']
const STATUS_FILTERS: (ReceivableStatus | '')[] = ['', 'pending', 'paid', 'cancelled']

const STATUS_STYLE: Record<ReceivableStatus, string> = {
  pending: 'bg-amber-100 text-amber-800',
  paid: 'bg-green-100 text-green-800',
  cancelled: 'bg-slate-100 text-slate-500',
}

function fmtBs(n: number) {
  return `Bs ${n.toFixed(2)}`
}

export function ReceivablesView() {
  const [accounts, setAccounts] = useState<ReceivableAccount[]>([])
  const [receivables, setReceivables] = useState<Receivable[]>([])
  const [paymentMethods, setPaymentMethods] = useState<PaymentMethod[]>([])
  const [error, setError] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  // Alta de cuenta
  const [name, setName] = useState('')
  const [kind, setKind] = useState<ReceivableAccountKind>('empresa')
  const [contact, setContact] = useState('')
  const [notes, setNotes] = useState('')

  // Filtros de deudas
  const [filterAccount, setFilterAccount] = useState('')
  const [filterStatus, setFilterStatus] = useState<ReceivableStatus | ''>('pending')

  // Cobro
  const [settling, setSettling] = useState<Receivable | null>(null)
  const [settleMethod, setSettleMethod] = useState('')
  const [settleProof, setSettleProof] = useState<PaymentProof>(EMPTY_PAYMENT_PROOF)
  const [settleMixed, setSettleMixed] = useState<MixedPayment>(EMPTY_MIXED_PAYMENT)
  const settleError = !settling
    ? null
    : isMixed(settleMethod)
      ? mixedPaymentError(settling.amountBs, settleMixed, settleProof)
      : paymentProofError(settleMethod, settleProof)

  const loadAccounts = useCallback(() => {
    return listReceivableAccounts()
      .then(setAccounts)
      .catch((e: Error) => setError(e.message))
  }, [])

  const loadReceivables = useCallback(() => {
    return listReceivables({
      accountId: filterAccount || null,
      status: filterStatus || null,
    })
      .then(setReceivables)
      .catch((e: Error) => setError(e.message))
  }, [filterAccount, filterStatus])

  useEffect(() => {
    void loadAccounts()
    fetchPaymentMethods()
      .then((ms) => setPaymentMethods(ms.filter((m) => m.code !== 'CTAS_POR_COBRAR')))
      .catch((e: Error) => setError(e.message))
  }, [loadAccounts])

  useEffect(() => {
    void loadReceivables()
  }, [loadReceivables])

  async function handleCreateAccount() {
    if (!name.trim()) {
      setError('El nombre de la cuenta es obligatorio')
      return
    }
    setBusy(true)
    setError(null)
    setMessage(null)
    try {
      await createReceivableAccount({ name, kind, contact: contact || null, notes: notes || null })
      setName('')
      setContact('')
      setNotes('')
      setMessage('Cuenta creada.')
      await loadAccounts()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  function openSettle(r: Receivable) {
    setSettling(r)
    setSettleMethod(paymentMethods[0]?.code ?? '')
    setError(null)
    setMessage(null)
  }

  async function confirmSettle() {
    if (!settling || !settleMethod) return
    if (settleError) {
      setError(settleError)
      return
    }
    setBusy(true)
    setError(null)
    try {
      await settleReceivable(
        settling.id,
        settleMethod,
        settleProof,
        isMixed(settleMethod)
          ? {
              cashBs: Number(settleMixed.cashBs),
              nonCashBs: Number(settleMixed.nonCashBs),
              nonCashMethod: settleMixed.nonCashMethod,
            }
          : null,
      )
      setMessage(`Deuda cobrada (${fmtBs(settling.amountBs)}).`)
      setSettling(null)
      setSettleProof(EMPTY_PAYMENT_PROOF)
      setSettleMixed(EMPTY_MIXED_PAYMENT)
      await loadReceivables()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  async function handleCancel(r: Receivable) {
    const reason = window.prompt('Motivo de la anulación:', '')
    if (reason === null) return
    try {
      await cancelReceivable(r.id, reason)
      setMessage('Deuda anulada.')
      await loadReceivables()
    } catch (e) {
      setError((e as Error).message)
    }
  }

  const totalPending = receivables
    .filter((r) => r.status === 'pending')
    .reduce((sum, r) => sum + r.amountBs, 0)

  return (
    <div className="mx-auto max-w-5xl p-6">
      <PageHeader
        title="Cuentas por cobrar"
        subtitle="Cuentas de clientes/convenios y deudas pendientes de cobro"
      />

      {error && <p className="mb-4 rounded bg-red-50 p-2 text-sm text-red-700">{error}</p>}
      {message && <p className="mb-4 rounded bg-green-50 p-2 text-sm text-green-700">{message}</p>}

      {/* Alta de cuenta */}
      <div className="mb-6 rounded border border-slate-200 p-4">
        <h3 className="mb-3 font-semibold text-slate-700">Nueva cuenta</h3>
        <div className="grid grid-cols-1 gap-2 sm:grid-cols-4">
          <input
            placeholder="Nombre (ej. Banco de Crédito)"
            value={name}
            onChange={(e) => setName(e.target.value)}
            className="rounded border border-slate-300 p-2 text-sm sm:col-span-2"
          />
          <select
            value={kind}
            onChange={(e) => setKind(e.target.value as ReceivableAccountKind)}
            className="rounded border border-slate-300 p-2 text-sm"
          >
            {KINDS.map((k) => (
              <option key={k} value={k}>{ACCOUNT_KIND_LABEL[k]}</option>
            ))}
          </select>
          <input
            placeholder="Contacto (opcional)"
            value={contact}
            onChange={(e) => setContact(e.target.value)}
            className="rounded border border-slate-300 p-2 text-sm"
          />
          <input
            placeholder="Notas (opcional)"
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
            className="rounded border border-slate-300 p-2 text-sm sm:col-span-3"
          />
          <button
            type="button"
            disabled={busy}
            onClick={handleCreateAccount}
            className="rounded bg-brand-700 px-4 py-2 text-sm font-medium text-white hover:bg-brand-800 disabled:opacity-50"
          >
            Crear cuenta
          </button>
        </div>
        {accounts.length > 0 && (
          <p className="mt-3 text-xs text-slate-500">
            {accounts.length} cuenta(s): {accounts.map((a) => a.name).join(', ')}
          </p>
        )}
      </div>

      {/* Filtros + total */}
      <div className="mb-3 flex flex-wrap items-end gap-3">
        <label className="text-xs font-medium text-slate-500">
          Cuenta
          <select
            value={filterAccount}
            onChange={(e) => setFilterAccount(e.target.value)}
            className="mt-1 block rounded border border-slate-300 p-2 text-sm"
          >
            <option value="">Todas</option>
            {accounts.map((a) => (
              <option key={a.id} value={a.id}>{a.name}</option>
            ))}
          </select>
        </label>
        <label className="text-xs font-medium text-slate-500">
          Estado
          <select
            value={filterStatus}
            onChange={(e) => setFilterStatus(e.target.value as ReceivableStatus | '')}
            className="mt-1 block rounded border border-slate-300 p-2 text-sm"
          >
            {STATUS_FILTERS.map((s) => (
              <option key={s || 'all'} value={s}>
                {s ? RECEIVABLE_STATUS_LABEL[s] : 'Todos'}
              </option>
            ))}
          </select>
        </label>
        <span className="pb-2 text-sm text-slate-600">
          Pendiente (filtro actual): <b>{fmtBs(totalPending)}</b>
        </span>
      </div>

      {/* Lista de deudas */}
      <div className="overflow-x-auto rounded border border-slate-200">
        <table className="w-full text-left text-sm">
          <thead className="bg-slate-100 text-slate-600">
            <tr>
              <th className="p-3">Cuenta</th>
              <th className="p-3">Detalle</th>
              <th className="p-3">Monto</th>
              <th className="p-3">Estado</th>
              <th className="p-3">Registrada</th>
              <th className="p-3"></th>
            </tr>
          </thead>
          <tbody>
            {receivables.map((r) => (
              <tr key={r.id} className="border-t border-slate-100">
                <td className="p-3 font-medium text-slate-700">{r.accountName}</td>
                <td className="p-3 text-slate-500">
                  {r.concept ?? '—'}
                  {r.guestName ? ` · ${r.guestName}` : ''}
                  {r.roomNumber ? ` · Hab. ${r.roomNumber}` : ''}
                </td>
                <td className="p-3">{fmtBs(r.amountBs)}</td>
                <td className="p-3">
                  <span className={`rounded px-2 py-1 text-xs font-medium ${STATUS_STYLE[r.status]}`}>
                    {RECEIVABLE_STATUS_LABEL[r.status]}
                  </span>
                  {r.status === 'paid' && r.settleMethod && (
                    <span className="ml-1 text-xs text-slate-400">({r.settleMethod})</span>
                  )}
                  {r.status === 'cancelled' && r.cancelReason && (
                    <span className="ml-1 text-xs text-slate-400">— {r.cancelReason}</span>
                  )}
                </td>
                <td className="p-3 whitespace-nowrap text-slate-500">{formatDateTime(r.createdAt)}</td>
                <td className="p-3">
                  {r.status === 'pending' && (
                    <div className="flex gap-1">
                      <button
                        type="button"
                        onClick={() => openSettle(r)}
                        className="rounded bg-green-600 px-2 py-1 text-xs font-medium text-white hover:bg-green-700"
                      >
                        Cobrar
                      </button>
                      <button
                        type="button"
                        onClick={() => handleCancel(r)}
                        className="rounded border border-red-300 px-2 py-1 text-xs font-medium text-red-600 hover:bg-red-50"
                      >
                        Anular
                      </button>
                    </div>
                  )}
                </td>
              </tr>
            ))}
            {receivables.length === 0 && (
              <tr>
                <td colSpan={6} className="p-4 text-center text-slate-400">
                  Sin deudas para este filtro.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      {/* Modal de cobro */}
      {settling && (
        <div className="fixed inset-0 z-10 flex items-center justify-center bg-black/30 p-4">
          <div className="w-full max-w-sm rounded-lg bg-white p-6 shadow-xl">
            <h3 className="mb-1 text-lg font-bold text-slate-800">Cobrar deuda</h3>
            <p className="mb-4 text-sm text-slate-500">
              {settling.accountName} · {fmtBs(settling.amountBs)}
            </p>
            <label className="block text-sm">
              <span className="mb-1 block text-xs font-medium text-slate-500">Forma de cobro</span>
              <select
                value={settleMethod}
                onChange={(e) => setSettleMethod(e.target.value)}
                className="w-full rounded border border-slate-300 p-2"
              >
                {paymentMethods.map((m) => (
                  <option key={m.code} value={m.code}>{m.label}</option>
                ))}
              </select>
            </label>
            {isMixed(settleMethod) ? (
              <MixedPaymentFields
                className="mt-3"
                total={settling.amountBs}
                split={settleMixed}
                proof={settleProof}
                onSplitChange={(patch) => setSettleMixed((m) => ({ ...m, ...patch }))}
                onProofChange={(patch) => setSettleProof((p) => ({ ...p, ...patch }))}
              />
            ) : (
              <PaymentProofFields
                className="mt-3"
                method={settleMethod}
                proof={settleProof}
                onChange={(patch) => setSettleProof((p) => ({ ...p, ...patch }))}
              />
            )}
            <p className="mt-2 text-xs text-slate-400">
              En efectivo se registra en la caja (requiere caja abierta).
            </p>
            <div className="mt-4 flex gap-2">
              <button
                type="button"
                disabled={busy || !settleMethod || settleError !== null}
                onClick={confirmSettle}
                className="w-1/2 rounded bg-green-600 py-2 text-sm font-medium text-white hover:bg-green-700 disabled:opacity-50"
              >
                Confirmar cobro
              </button>
              <button
                type="button"
                onClick={() => setSettling(null)}
                className="w-1/2 rounded border border-slate-300 py-2 text-sm text-slate-600 hover:bg-slate-50"
              >
                Cancelar
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
