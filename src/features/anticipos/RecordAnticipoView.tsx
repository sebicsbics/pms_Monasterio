import { useCallback, useEffect, useState } from 'react'
import { userFacingAnticipoError, type Anticipo } from '../../domain/anticipos/anticipos'
import type { PaymentMethod } from '../../domain/payments/paymentMethod'
import { fetchPaymentMethods } from '../../services/payments'
import { fetchAnticipos, recordAnticipo } from '../../services/anticipos'
import { listReservationsBrief, type ReservationBrief } from '../../services/reservations'
import { Button, Card, PageHeader } from '../../components/ui'
import { AnticipoList } from './AnticipoList'
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

const INPUT = 'w-full rounded-lg border border-slate-300 p-2'

function fmtBs(n: number) {
  return `Bs ${n.toFixed(2)}`
}

// Vista de recepción para registrar anticipos (adelantos de huésped) contra
// una reserva. Reception y reception_admin pueden registrar (OPERATIONS) —
// reembolsar/modificar viven en AnticipoAdminView (reception_admin only).
export function RecordAnticipoView() {
  const [reservationId, setReservationId] = useState('')
  const [reservations, setReservations] = useState<ReservationBrief[]>([])
  const [amount, setAmount] = useState('')
  const [paymentMethod, setPaymentMethod] = useState('')
  const [notes, setNotes] = useState('')
  const [proof, setProof] = useState<PaymentProof>(EMPTY_PAYMENT_PROOF)
  const [mixed, setMixed] = useState<MixedPayment>(EMPTY_MIXED_PAYMENT)
  const amountNumber = Number(amount) || 0
  const payError = isMixed(paymentMethod)
    ? mixedPaymentError(amountNumber, mixed, proof)
    : paymentProofError(paymentMethod, proof)
  const [paymentMethods, setPaymentMethods] = useState<PaymentMethod[]>([])
  const [anticipos, setAnticipos] = useState<Anticipo[]>([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const [refreshKey, setRefreshKey] = useState(0)

  useEffect(() => {
    fetchPaymentMethods()
      .then((methods) => {
        setPaymentMethods(methods)
        setPaymentMethod((current) => current || (methods[0]?.code ?? ''))
      })
      .catch((e: Error) => setError(e.message))
    listReservationsBrief()
      .then(setReservations)
      .catch((e: Error) => setError(e.message))
  }, [])

  const reload = useCallback((id: string) => {
    if (!id) {
      setAnticipos([])
      return Promise.resolve()
    }
    return fetchAnticipos(id)
      .then(setAnticipos)
      .catch((e: Error) => setError(userFacingAnticipoError(e.message)))
  }, [])

  useEffect(() => {
    void reload(reservationId.trim())
  }, [reservationId, reload])

  async function handleSubmit() {
    setError(null)
    setMessage(null)
    const trimmedId = reservationId.trim()
    if (!trimmedId) {
      setError('Elegí una reserva')
      return
    }
    const amountNum = Number(amount)
    if (!amountNum || amountNum <= 0) {
      setError('El monto debe ser mayor a 0')
      return
    }
    if (payError) {
      setError(payError)
      return
    }
    setBusy(true)
    try {
      await recordAnticipo({
        reservationId: trimmedId,
        amountBs: amountNum,
        paymentMethod,
        notes: notes.trim() || null,
        proof,
        mixed: isMixed(paymentMethod)
          ? {
              cashBs: Number(mixed.cashBs),
              nonCashBs: Number(mixed.nonCashBs),
              nonCashMethod: mixed.nonCashMethod,
            }
          : null,
      })
      setAmount('')
      setNotes('')
      setMessage('Anticipo registrado.')
      setRefreshKey((k) => k + 1)
      await reload(trimmedId)
    } catch (e) {
      setError(userFacingAnticipoError((e as Error).message))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="mx-auto max-w-2xl p-6">
      <PageHeader
        title="Registrar anticipo"
        subtitle="Adelanto de huésped contra una reserva"
      />
      {error && (
        <p className="mb-4 rounded bg-red-50 p-2 text-sm text-red-700">{error}</p>
      )}
      {message && (
        <p className="mb-4 rounded bg-green-50 p-2 text-sm text-green-700">{message}</p>
      )}
      <Card className="p-4">
        <div className="space-y-3">
          <div>
            <label className="mb-1 block text-sm text-slate-600">Reserva</label>
            <select
              className={INPUT}
              value={reservationId}
              onChange={(e) => setReservationId(e.target.value)}
            >
              <option value="">Elegí una reserva…</option>
              {reservations.map((r) => (
                <option key={r.id} value={r.id}>
                  Hab. {r.roomNumber} · {r.guestName} · {r.checkIn} → {r.checkOut}
                  {r.status === 'checked_in' ? ' (in-house)' : ''}
                </option>
              ))}
            </select>
          </div>
          <div className="flex gap-3">
            <div className="flex-1">
              <label className="mb-1 block text-sm text-slate-600">Monto (Bs)</label>
              <input
                type="number" min={0} step="0.01"
                className={INPUT}
                value={amount}
                onChange={(e) => setAmount(e.target.value)}
              />
            </div>
            <div className="flex-1">
              <label className="mb-1 block text-sm text-slate-600">Forma de pago</label>
              <select
                className={INPUT}
                value={paymentMethod}
                onChange={(e) => setPaymentMethod(e.target.value)}
              >
                {paymentMethods.map((m) => (
                  <option key={m.code} value={m.code}>{m.label}</option>
                ))}
              </select>
            </div>
          </div>
          {isMixed(paymentMethod) ? (
            <MixedPaymentFields
              total={amountNumber}
              split={mixed}
              proof={proof}
              onSplitChange={(patch) => setMixed((m) => ({ ...m, ...patch }))}
              onProofChange={(patch) => setProof((p) => ({ ...p, ...patch }))}
            />
          ) : (
            <PaymentProofFields
              method={paymentMethod}
              proof={proof}
              onChange={(patch) => setProof((p) => ({ ...p, ...patch }))}
            />
          )}
          <div>
            <label className="mb-1 block text-sm text-slate-600">Notas (opcional)</label>
            <input
              className={INPUT}
              value={notes}
              onChange={(e) => setNotes(e.target.value)}
            />
          </div>
          <Button
            loading={busy}
            disabled={payError !== null}
            onClick={handleSubmit}
          >
            Registrar anticipo
          </Button>
        </div>
      </Card>

      {anticipos.length > 0 && (
        <div className="mt-6 space-y-2">
          <h3 className="text-sm font-semibold text-slate-700">Anticipos de esta reserva</h3>
          {anticipos.map((a) => (
            <Card key={a.id} className="p-3">
              <div className="flex items-center justify-between">
                <div>
                  <p className="text-sm font-medium text-slate-800">
                    {fmtBs(a.amountBs)} · {a.paymentMethod}
                  </p>
                  <p className="text-xs text-slate-500">
                    Estado: {a.status}
                  </p>
                </div>
              </div>
            </Card>
          ))}
        </div>
      )}

      <AnticipoList refreshKey={refreshKey} />
    </div>
  )
}
