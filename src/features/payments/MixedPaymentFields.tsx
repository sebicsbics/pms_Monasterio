import {
  completeSplit,
  NON_CASH_METHODS,
  type MixedPayment,
  type NonCashMethod,
} from '../../domain/payments/mixedPayment'
import type { PaymentProof } from '../../domain/payments/paymentProof'
import { PaymentProofFields } from './PaymentProofFields'

// Desglose de un pago mixto. Sólo se renderiza cuando la forma de pago es
// MIXTO (lo decide quien lo usa). Al escribir un monto completa el otro
// contra el total, que es el descuadre más fácil de cometer a mano.
export function MixedPaymentFields({
  total,
  split,
  proof,
  onSplitChange,
  onProofChange,
  className = '',
}: {
  total: number
  split: MixedPayment
  proof: PaymentProof
  onSplitChange: (patch: Partial<MixedPayment>) => void
  onProofChange: (patch: Partial<PaymentProof>) => void
  className?: string
}) {
  const sum = Number(split.cashBs || 0) + Number(split.nonCashBs || 0)
  const off = Math.abs(sum - total) > 0.01

  return (
    <div className={`space-y-2 rounded border border-slate-200 p-3 ${className}`}>
      <p className="text-xs text-slate-500">
        Total a cobrar: <span className="font-semibold">{total.toFixed(2)} Bs</span>
      </p>

      <div className="flex gap-2">
        <label className="w-1/2 text-sm">
          <span className="mb-1 block text-xs font-medium text-slate-500">
            En efectivo (Bs)
          </span>
          <input
            type="number"
            min={0}
            step="0.01"
            value={split.cashBs}
            onChange={(e) => onSplitChange(completeSplit(total, 'cash', e.target.value))}
            placeholder="0.00"
            className="w-full rounded border border-slate-300 p-2 text-sm"
          />
        </label>
        <label className="w-1/2 text-sm">
          <span className="mb-1 block text-xs font-medium text-slate-500">
            Por {split.nonCashMethod === 'QR' ? 'QR' : 'tarjeta'} (Bs)
          </span>
          <input
            type="number"
            min={0}
            step="0.01"
            value={split.nonCashBs}
            onChange={(e) => onSplitChange(completeSplit(total, 'nonCash', e.target.value))}
            placeholder="0.00"
            className="w-full rounded border border-slate-300 p-2 text-sm"
          />
        </label>
      </div>

      <label className="block text-sm">
        <span className="mb-1 block text-xs font-medium text-slate-500">
          Medio de la parte no-efectivo
        </span>
        <select
          value={split.nonCashMethod}
          onChange={(e) =>
            onSplitChange({ nonCashMethod: e.target.value as NonCashMethod })
          }
          className="w-full rounded border border-slate-300 p-2 text-sm"
        >
          {NON_CASH_METHODS.map((m) => (
            <option key={m.code} value={m.code}>
              {m.label}
            </option>
          ))}
        </select>
      </label>

      {/* El respaldo corresponde a la parte electrónica. */}
      <PaymentProofFields
        method={split.nonCashMethod}
        proof={proof}
        onChange={onProofChange}
      />

      <p
        className={`rounded p-2 text-xs ${
          off ? 'bg-amber-50 text-amber-800' : 'bg-green-50 text-green-700'
        }`}
      >
        {split.cashBs === '' && split.nonCashBs === ''
          ? 'Ingresá cuánto se paga en efectivo.'
          : off
            ? `Suma ${sum.toFixed(2)} Bs — no coincide con el total.`
            : `Suma ${sum.toFixed(2)} Bs ✓ · el efectivo va al arqueo, el resto a "Otros medios".`}
      </p>
    </div>
  )
}
