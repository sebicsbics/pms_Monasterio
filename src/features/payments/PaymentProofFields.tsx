import {
  needsPaymentReference,
  needsReceiptPhoto,
  type PaymentProof,
} from '../../domain/payments/paymentProof'

// Campos de respaldo del cobro, compartidos por TODOS los puntos donde se
// elige forma de pago. No renderiza nada salvo que la forma de pago lo
// pida: foto sólo para QR, número de transacción sólo para tarjeta.
export function PaymentProofFields({
  method,
  proof,
  onChange,
  className = '',
}: {
  method: string | null | undefined
  proof: PaymentProof
  onChange: (patch: Partial<PaymentProof>) => void
  className?: string
}) {
  const wantsPhoto = needsReceiptPhoto(method)
  const wantsReference = needsPaymentReference(method)
  if (!wantsPhoto && !wantsReference) return null

  return (
    <div className={`space-y-2 ${className}`}>
      {wantsPhoto && (
        <label className="block text-sm">
          <span className="mb-1 block text-xs font-medium text-slate-500">
            Foto del comprobante QR (obligatoria)
          </span>
          <input
            type="file"
            accept="image/*"
            onChange={(e) => onChange({ receipt: e.target.files?.[0] ?? null })}
            className="w-full rounded border border-slate-300 p-2 text-sm"
          />
        </label>
      )}
      {wantsReference && (
        <label className="block text-sm">
          <span className="mb-1 block text-xs font-medium text-slate-500">
            Código de referencia (obligatorio)
          </span>
          <input
            value={proof.paymentReference}
            onChange={(e) => onChange({ paymentReference: e.target.value })}
            placeholder="Ej. AB12345"
            className="w-full rounded border border-slate-300 p-2 text-sm"
          />
        </label>
      )}
    </div>
  )
}
