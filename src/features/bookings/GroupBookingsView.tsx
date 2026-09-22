import { useCallback, useEffect, useState } from 'react'
import type { PaymentMethod } from '../../domain/payments/paymentMethod'
import { fetchPaymentMethods } from '../../services/payments'
import { listClientBookingsBrief, recordBookingAdvance, type ClientBookingBrief } from '../../services/bookings'
import { Button, Card, PageHeader } from '../../components/ui'
import { isAnticipoMethod } from '../../domain/cash/cash'
import type { UserRole } from '../../domain/auth/profile'
import type { PaymentProof } from '../../domain/payments/paymentProof'
import { EMPTY_PAYMENT_PROOF, paymentProofError } from '../../domain/payments/paymentProof'
import { PaymentProofFields } from '../payments/PaymentProofFields'
import type { MixedPayment } from '../../domain/payments/mixedPayment'
import { EMPTY_MIXED_PAYMENT, isMixed, mixedPaymentError } from '../../domain/payments/mixedPayment'
import { MixedPaymentFields } from '../payments/MixedPaymentFields'

const INPUT = 'w-full rounded-lg border border-slate-300 p-2'

function fmtBs(n: number) {
  return `${n} Bs`
}

// Vista para gestionar el saldo de reservas institucionales (grupo/agencia,
// payer_mode='client'): registrar un adelanto contra el paquete, ver el
// saldo pendiente y avisar si hay habitaciones sin check-in con fecha
// vencida (R11.1–R11.4). No incluye a owner: list_client_bookings_brief()
// lo rechaza (sin acceso a booking_balances/receivables en esta etapa).
// `role` no se usa para gatear contenido acá adentro (a diferencia de
// RecordAnticipoView): el nav tab de App.tsx ya excluye a owner por
// completo (list_client_bookings_brief() lo rechaza), así que cualquier
// role que llegue a esta vista puede escribir. Se recibe igual, por
// consistencia con el resto de las vistas (RecordAnticipoView, etc.) y
// para no romper la firma si un futuro rol de solo-lectura se agrega acá.
export function GroupBookingsView({ role: _role }: { role?: UserRole | null }) {
  const [bookingId, setBookingId] = useState('')
  const [bookings, setBookings] = useState<ClientBookingBrief[]>([])
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
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)

  const reload = useCallback(() => {
    return listClientBookingsBrief()
      .then(setBookings)
      .catch((e: Error) => setError(e.message))
  }, [])

  useEffect(() => {
    fetchPaymentMethods()
      .then((methods) => {
        const usable = methods.filter((m) => isAnticipoMethod(m.code))
        setPaymentMethods(usable)
        setPaymentMethod((current) => current || (usable[0]?.code ?? ''))
      })
      .catch((e: Error) => setError(e.message))
    void reload()
  }, [reload])

  const selected = bookings.find((b) => b.bookingId === bookingId) ?? null

  async function handleSubmit() {
    setError(null)
    setMessage(null)
    if (!bookingId) {
      setError('Elegí una reserva institucional')
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
      await recordBookingAdvance({
        bookingId,
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
      setMessage('Adelanto registrado.')
      await reload()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="mx-auto max-w-2xl p-6">
      <PageHeader
        title="Grupos/Instituciones"
        subtitle="Adelantos y saldo pendiente de reservas institucionales"
      />
      {error && (
        <p className="mb-4 rounded bg-red-50 p-2 text-sm text-red-700">{error}</p>
      )}
      {message && (
        <p className="mb-4 rounded bg-green-50 p-2 text-sm text-green-700">{message}</p>
      )}

      <div className="mb-4 space-y-2">
        {bookings.map((b) => (
          <div key={b.bookingId} onClick={() => setBookingId(b.bookingId)}>
            <Card
              className={`cursor-pointer p-3 ${b.bookingId === bookingId ? 'ring-2 ring-blue-500' : ''}`}
            >
              <p className="text-sm font-medium text-slate-800">
                {b.accountName} · {b.contactName}
              </p>
              <p className="text-xs text-slate-500">Saldo pendiente: {fmtBs(b.netOwedBs)}</p>
            </Card>
          </div>
        ))}
        {bookings.length === 0 && (
          <p className="text-sm text-slate-500">No hay reservas institucionales abiertas.</p>
        )}
      </div>

      {selected && (
        <>
          <p className="mb-2 text-sm font-semibold text-slate-700">
            Saldo pendiente: {fmtBs(selected.netOwedBs)}
          </p>
          {selected.overdueRooms.length > 0 && (
            <p className="mb-4 rounded bg-amber-50 p-2 text-sm text-amber-800">
              Habitaciones sin check-in con fecha vencida: {selected.overdueRooms.join(', ')}
            </p>
          )}

          <Card className="p-4">
            <div className="space-y-3">
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
                Registrar adelanto
              </Button>
            </div>
          </Card>
        </>
      )}
    </div>
  )
}
