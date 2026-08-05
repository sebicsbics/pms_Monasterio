import { useCallback, useEffect, useState } from 'react'
import type { UserRole } from '../../domain/auth/profile'
import { ANTICIPOS_ADMIN } from '../../domain/auth/roleGroups'
import { userFacingAnticipoError, type Anticipo } from '../../domain/anticipos/anticipos'
import type { PaymentMethod } from '../../domain/payments/paymentMethod'
import { fetchPaymentMethods } from '../../services/payments'
import { fetchAnticipos, modifyAnticipo } from '../../services/anticipos'
import { Badge, Button, Card, PageHeader } from '../../components/ui'
import type { PaymentProof } from '../../domain/payments/paymentProof'
import {
  EMPTY_PAYMENT_PROOF,
  paymentProofError,
} from '../../domain/payments/paymentProof'
import { PaymentProofFields } from '../payments/PaymentProofFields'

const INPUT = 'w-full rounded-lg border border-slate-300 p-2'

function fmtBs(n: number) {
  return `Bs ${n.toFixed(2)}`
}

// Vista de reception_admin para corregir anticipos. El hotel NO reembolsa
// (si el huésped no viene, se cancela/reprograma la reserva y el anticipo
// se pierde). El original de un anticipo NUNCA se edita en su lugar:
// modify_anticipo escribe una fila de corrección y solo se permite mientras
// status='active' (queda bloqueado si la reserva se canceló → 'forfeited').
export function AnticipoAdminView({ role }: { role?: UserRole | null }) {
  const [reservationId, setReservationId] = useState('')
  const [anticipos, setAnticipos] = useState<Anticipo[]>([])
  const [paymentMethods, setPaymentMethods] = useState<PaymentMethod[]>([])
  const [error, setError] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)

  const [modifyAmount, setModifyAmount] = useState('')
  const [modifyMethod, setModifyMethod] = useState('')
  const [modifyReason, setModifyReason] = useState('')
  const [modifyProof, setModifyProof] = useState<PaymentProof>(EMPTY_PAYMENT_PROOF)

  useEffect(() => {
    fetchPaymentMethods()
      .then(setPaymentMethods)
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

  if (!ANTICIPOS_ADMIN.includes(role as UserRole)) {
    return (
      <div className="mx-auto max-w-3xl p-6">
        <p className="text-sm text-slate-500">No autorizado para ver esta sección.</p>
      </div>
    )
  }

  async function handleModify(a: Anticipo) {
    setError(null)
    setMessage(null)
    if (a.status !== 'active') {
      setError('No se puede modificar un anticipo ya reembolsado (total o parcialmente)')
      return
    }
    const amountNum = Number(modifyAmount)
    if (!amountNum || amountNum <= 0) {
      setError('El monto debe ser mayor a 0')
      return
    }
    const effectiveMethod = modifyMethod || a.paymentMethod
    const proofErr = paymentProofError(effectiveMethod, modifyProof)
    if (proofErr) {
      setError(proofErr)
      return
    }
    if (!modifyReason.trim()) {
      setError('La justificación es obligatoria')
      return
    }
    setBusyId(a.id)
    try {
      await modifyAnticipo(
        a.id,
        amountNum,
        effectiveMethod,
        modifyReason.trim(),
        modifyProof,
      )
      setModifyAmount('')
      setModifyReason('')
      setModifyProof(EMPTY_PAYMENT_PROOF)
      setMessage('Anticipo modificado.')
      await reload(reservationId.trim())
    } catch (e) {
      setError(userFacingAnticipoError((e as Error).message))
    } finally {
      setBusyId(null)
    }
  }

  return (
    <div className="mx-auto max-w-3xl p-6">
      <PageHeader
        title="Corregir anticipos"
        subtitle="Solo reception_admin — el original nunca se pierde, cada corrección queda auditada"
      />
      {error && (
        <p className="mb-4 rounded bg-red-50 p-2 text-sm text-red-700">{error}</p>
      )}
      {message && (
        <p className="mb-4 rounded bg-green-50 p-2 text-sm text-green-700">{message}</p>
      )}
      <div className="mb-4">
        <label className="mb-1 block text-sm text-slate-600">ID de reserva</label>
        <input
          className={INPUT}
          value={reservationId}
          onChange={(e) => setReservationId(e.target.value)}
          placeholder="uuid de la reserva"
        />
      </div>

      {anticipos.length === 0 ? (
        <p className="text-sm text-slate-400">Sin anticipos para esta reserva.</p>
      ) : (
        <div className="space-y-4">
          {anticipos.map((a) => (
            <Card key={a.id} className="p-4">
              <div className="flex items-start justify-between gap-3">
                <div>
                  <p className="text-sm font-semibold text-slate-800">
                    {fmtBs(a.amountBs)} · {a.paymentMethod}
                  </p>
                </div>
                <Badge tone={a.status === 'active' ? 'success' : 'warning'}>{a.status}</Badge>
              </div>

              {a.status === 'active' ? (
                <div className="mt-3 flex flex-wrap items-end gap-2 border-t border-slate-200 pt-3">
                  <input
                    type="number" min={0} step="0.01" placeholder="Nuevo monto"
                    className="w-32 rounded-lg border border-slate-300 p-2 text-sm"
                    value={modifyAmount}
                    onChange={(e) => setModifyAmount(e.target.value)}
                  />
                  <select
                    className="rounded-lg border border-slate-300 p-2 text-sm"
                    value={modifyMethod || a.paymentMethod}
                    onChange={(e) => setModifyMethod(e.target.value)}
                  >
                    {paymentMethods.map((m) => (
                      <option key={m.code} value={m.code}>{m.label}</option>
                    ))}
                  </select>
                  <input
                    placeholder="Motivo de la corrección"
                    className="flex-1 rounded-lg border border-slate-300 p-2 text-sm"
                    value={modifyReason}
                    onChange={(e) => setModifyReason(e.target.value)}
                  />
                  <Button
                    size="sm"
                    variant="secondary"
                    disabled={
                      busyId === a.id ||
                      paymentProofError(modifyMethod || a.paymentMethod, modifyProof) !== null
                    }
                    onClick={() => handleModify(a)}
                  >
                    Corregir
                  </Button>
                  <PaymentProofFields
                    className="w-full"
                    method={modifyMethod || a.paymentMethod}
                    proof={modifyProof}
                    onChange={(patch) => setModifyProof((p) => ({ ...p, ...patch }))}
                  />
                </div>
              ) : (
                <p className="mt-3 border-t border-slate-200 pt-3 text-xs text-slate-400">
                  Anticipo perdido (reserva cancelada): no se puede modificar.
                </p>
              )}
            </Card>
          ))}
        </div>
      )}
    </div>
  )
}
