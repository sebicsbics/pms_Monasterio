import { useCallback, useEffect, useState } from 'react'
import { userFacingAnticipoError, type Anticipo } from '../../domain/anticipos/anticipos'
import type { PaymentMethod } from '../../domain/payments/paymentMethod'
import { fetchPaymentMethods } from '../../services/payments'
import { fetchAnticipos, recordAnticipo } from '../../services/anticipos'
import { Button, Card, PageHeader } from '../../components/ui'

const INPUT = 'w-full rounded-lg border border-slate-300 p-2'

function fmtBs(n: number) {
  return `Bs ${n.toFixed(2)}`
}

// Vista de recepción para registrar anticipos (adelantos de huésped) contra
// una reserva. Reception y reception_admin pueden registrar (OPERATIONS) —
// reembolsar/modificar viven en AnticipoAdminView (reception_admin only).
export function RecordAnticipoView() {
  const [reservationId, setReservationId] = useState('')
  const [amount, setAmount] = useState('')
  const [paymentMethod, setPaymentMethod] = useState('')
  const [notes, setNotes] = useState('')
  const [paymentMethods, setPaymentMethods] = useState<PaymentMethod[]>([])
  const [anticipos, setAnticipos] = useState<Anticipo[]>([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)

  useEffect(() => {
    fetchPaymentMethods()
      .then((methods) => {
        setPaymentMethods(methods)
        setPaymentMethod((current) => current || (methods[0]?.code ?? ''))
      })
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
      setError('Ingresá el ID de la reserva')
      return
    }
    const amountNum = Number(amount)
    if (!amountNum || amountNum <= 0) {
      setError('El monto debe ser mayor a 0')
      return
    }
    setBusy(true)
    try {
      await recordAnticipo({
        reservationId: trimmedId,
        amountBs: amountNum,
        paymentMethod,
        notes: notes.trim() || null,
      })
      setAmount('')
      setNotes('')
      setMessage('Anticipo registrado.')
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
            <label className="mb-1 block text-sm text-slate-600">ID de reserva</label>
            <input
              className={INPUT}
              value={reservationId}
              onChange={(e) => setReservationId(e.target.value)}
              placeholder="uuid de la reserva"
            />
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
          <div>
            <label className="mb-1 block text-sm text-slate-600">Notas (opcional)</label>
            <input
              className={INPUT}
              value={notes}
              onChange={(e) => setNotes(e.target.value)}
            />
          </div>
          <Button loading={busy} onClick={handleSubmit}>Registrar anticipo</Button>
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
    </div>
  )
}
