import { useCallback, useEffect, useState } from 'react'
import type { UserRole } from '../../domain/auth/profile'
import { ANTICIPOS_ADMIN } from '../../domain/auth/roleGroups'
import {
  anticipoLabel,
  isCorrectable,
  userFacingAnticipoError,
  type AnticipoListItem,
} from '../../domain/anticipos/anticipos'
import type { PaymentMethod } from '../../domain/payments/paymentMethod'
import { fetchPaymentMethods } from '../../services/payments'
import { listAnticipos, modifyAnticipo } from '../../services/anticipos'
import { Badge, Button, Card, PageHeader } from '../../components/ui'
import { isAnticipoMethod } from '../../domain/cash/cash'
import { canWrite } from '../../domain/auth/profile'
import { AnticipoList } from './AnticipoList'
import type { MixedPayment } from '../../domain/payments/mixedPayment'
import {
  EMPTY_MIXED_PAYMENT,
  isMixed,
  mixedPaymentError,
} from '../../domain/payments/mixedPayment'
import { MixedPaymentFields } from '../payments/MixedPaymentFields'
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
  // Se elige el ANTICIPO directamente. Antes había que pegar a mano el
  // UUID de la reserva, que nadie tiene a mano en el mostrador.
  const [anticipos, setAnticipos] = useState<AnticipoListItem[]>([])
  const [selectedId, setSelectedId] = useState('')
  const [paymentMethods, setPaymentMethods] = useState<PaymentMethod[]>([])
  const [error, setError] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)

  const [modifyAmount, setModifyAmount] = useState('')
  const [modifyMethod, setModifyMethod] = useState('')
  const [modifyReason, setModifyReason] = useState('')
  const [modifyProof, setModifyProof] = useState<PaymentProof>(EMPTY_PAYMENT_PROOF)
  const [modifyMixed, setModifyMixed] = useState<MixedPayment>(EMPTY_MIXED_PAYMENT)

  useEffect(() => {
    fetchPaymentMethods()
      .then((methods) => setPaymentMethods(methods.filter((m) => isAnticipoMethod(m.code))))
      .catch((e: Error) => setError(e.message))
  }, [])

  // Sólo los vigentes: un anticipo 'forfeited' (reserva cancelada) está
  // congelado y modify_anticipo lo rechaza, así que ofrecerlo en el
  // selector sería ofrecer una acción que siempre falla.
  const reload = useCallback(() => {
    return listAnticipos(true)
      .then(setAnticipos)
      .catch((e: Error) => setError(userFacingAnticipoError(e.message)))
  }, [])

  useEffect(() => {
    void reload()
  }, [reload])

  const selected = anticipos.find((a) => a.id === selectedId) ?? null

  // owner entra al grupo para VER, pero corregir es escritura.
  if (!canWrite(role)) {
    return (
      <div className="mx-auto max-w-3xl p-6">
        <PageHeader
          title="Corregir anticipos"
          subtitle="Solo lectura: para corregir un anticipo, pedíselo al administrador"
        />
        <AnticipoList />
      </div>
    )
  }

  if (!ANTICIPOS_ADMIN.includes(role as UserRole)) {
    return (
      <div className="mx-auto max-w-3xl p-6">
        <p className="text-sm text-slate-500">No autorizado para ver esta sección.</p>
      </div>
    )
  }

  async function handleModify(a: AnticipoListItem) {
    setError(null)
    setMessage(null)
    if (!isCorrectable(a)) {
      setError('El anticipo está perdido (reserva cancelada): no se puede modificar')
      return
    }
    const amountNum = Number(modifyAmount)
    if (!amountNum || amountNum <= 0) {
      setError('El monto debe ser mayor a 0')
      return
    }
    const effectiveMethod = modifyMethod || a.paymentMethod
    const payErr = isMixed(effectiveMethod)
      ? mixedPaymentError(amountNum, modifyMixed, modifyProof)
      : paymentProofError(effectiveMethod, modifyProof)
    if (payErr) {
      setError(payErr)
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
        isMixed(effectiveMethod)
          ? {
              cashBs: Number(modifyMixed.cashBs),
              nonCashBs: Number(modifyMixed.nonCashBs),
              nonCashMethod: modifyMixed.nonCashMethod,
            }
          : null,
      )
      setModifyAmount('')
      setModifyReason('')
      setModifyProof(EMPTY_PAYMENT_PROOF)
      setModifyMixed(EMPTY_MIXED_PAYMENT)
      setMessage('Anticipo modificado.')
      await reload()
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
      <label className="mb-4 block text-sm">
        <span className="mb-1 block text-slate-600">Anticipo a corregir</span>
        <select
          className={INPUT}
          value={selectedId}
          onChange={(e) => {
            setSelectedId(e.target.value)
            setModifyAmount('')
            setModifyMethod('')
            setModifyReason('')
            setModifyProof(EMPTY_PAYMENT_PROOF)
            setModifyMixed(EMPTY_MIXED_PAYMENT)
            setError(null)
            setMessage(null)
          }}
        >
          <option value="">Elegí un anticipo…</option>
          {anticipos.map((a) => (
            <option key={a.id} value={a.id}>
              {anticipoLabel(a)}
            </option>
          ))}
        </select>
      </label>

      {anticipos.length === 0 ? (
        <p className="text-sm text-slate-400">
          No hay anticipos vigentes para corregir.
        </p>
      ) : !selected ? (
        <p className="text-sm text-slate-400">
          Elegí un anticipo de la lista para corregirlo.
        </p>
      ) : (
        <Card className="p-4">
          <div className="flex items-start justify-between gap-3">
            <div>
              <p className="text-sm font-semibold text-slate-800">
                Hab. {selected.roomNumber} · {selected.guestName}
              </p>
              <p className="text-xs text-slate-500">
                {fmtBs(selected.amountBs)} · {selected.paymentMethod} · cobrado por{' '}
                {selected.receivedByName}
              </p>
              <p className="text-xs text-slate-400">
                Estadía {selected.checkInDate} → {selected.checkOutDate}
                {selected.notes && ` · ${selected.notes}`}
              </p>
            </div>
            <Badge tone="success">vigente</Badge>
          </div>

          <div className="mt-3 flex flex-wrap items-end gap-2 border-t border-slate-200 pt-3">
            <input
              type="number" min={0} step="0.01" placeholder="Nuevo monto"
              className="w-32 rounded-lg border border-slate-300 p-2 text-sm"
              value={modifyAmount}
              onChange={(e) => setModifyAmount(e.target.value)}
            />
            <select
              className="rounded-lg border border-slate-300 p-2 text-sm"
              value={modifyMethod || selected.paymentMethod}
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
                busyId === selected.id ||
                (isMixed(modifyMethod || selected.paymentMethod)
                  ? mixedPaymentError(Number(modifyAmount) || 0, modifyMixed, modifyProof) !== null
                  : paymentProofError(modifyMethod || selected.paymentMethod, modifyProof) !== null)
              }
              onClick={() => handleModify(selected)}
            >
              Corregir
            </Button>
            {/* Con MIXTO el desglose se valida contra el monto NUEVO, que
                es lo que se va a cobrar tras la corrección. */}
            {isMixed(modifyMethod || selected.paymentMethod) ? (
              <MixedPaymentFields
                className="w-full"
                total={Number(modifyAmount) || 0}
                split={modifyMixed}
                proof={modifyProof}
                onSplitChange={(patch) => setModifyMixed((m) => ({ ...m, ...patch }))}
                onProofChange={(patch) => setModifyProof((p) => ({ ...p, ...patch }))}
              />
            ) : (
              <PaymentProofFields
                className="w-full"
                method={modifyMethod || selected.paymentMethod}
                proof={modifyProof}
                onChange={(patch) => setModifyProof((p) => ({ ...p, ...patch }))}
              />
            )}
          </div>
        </Card>
      )}

    </div>
  )
}
