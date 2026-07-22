import { useCallback, useEffect, useState } from 'react'
import type { RateDiscountRequest } from '../../domain/pricing/rateDiscountRequest'
import { canApproveDiscountRequests } from '../../domain/pricing/rateDiscountRequest'
import {
  approveRequest,
  fetchPendingRequests,
  rejectRequest,
} from '../../services/rateDiscountRequestsService'
import type { UserRole } from '../../domain/auth/profile'
import { Badge, Button, Card, PageHeader } from '../../components/ui'

// Cola de solicitudes de descuento >20% pendientes de aprobación.
// SOLO visible/operable para reception_admin/root — ver
// canApproveDiscountRequests y DISCOUNT_APPROVAL en roleGroups.ts.
export function DiscountApprovalQueueView({ role }: { role?: UserRole | null }) {
  const [requests, setRequests] = useState<RateDiscountRequest[]>([])
  const [busyId, setBusyId] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  const reload = useCallback(() => {
    return fetchPendingRequests()
      .then(setRequests)
      .catch((e: Error) => setError(e.message))
  }, [])

  useEffect(() => {
    void reload()
  }, [reload])

  if (!canApproveDiscountRequests(role)) {
    return (
      <div className="mx-auto max-w-3xl p-6">
        <p className="text-sm text-slate-500">No autorizado para ver esta sección.</p>
      </div>
    )
  }

  async function handleApprove(id: string) {
    setBusyId(id)
    setError(null)
    try {
      await approveRequest(id)
      await reload()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusyId(null)
    }
  }

  async function handleReject(id: string) {
    setBusyId(id)
    setError(null)
    try {
      await rejectRequest(id)
      await reload()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusyId(null)
    }
  }

  return (
    <div className="mx-auto max-w-3xl p-6">
      <PageHeader
        title="Descuentos pendientes de aprobación"
        subtitle="Solicitudes con descuento implícito superior al 20%"
      />
      {error && (
        <p className="mb-4 rounded bg-red-50 p-2 text-sm text-red-700">{error}</p>
      )}
      {requests.length === 0 ? (
        <p className="text-sm text-slate-400">No hay solicitudes pendientes.</p>
      ) : (
        <div className="space-y-3">
          {requests.map((r) => (
            <Card key={r.id} className="p-4">
              <div className="flex items-start justify-between gap-3">
                <div>
                  <p className="text-sm font-semibold text-slate-800">
                    Reserva {r.reservationId}
                  </p>
                  <p className="mt-1 text-xs text-slate-500">
                    Precio base {r.basePriceBs} Bs/noche → solicitado {r.requestedPriceBs} Bs/noche
                  </p>
                  <p className="mt-1 text-xs text-slate-500">Motivo: {r.reason}</p>
                </div>
                <Badge tone="warning">{r.computedDiscountPct}% de descuento</Badge>
              </div>
              <div className="mt-3 flex gap-2">
                <Button
                  size="sm"
                  disabled={busyId === r.id}
                  onClick={() => handleApprove(r.id)}
                >
                  Aprobar
                </Button>
                <Button
                  size="sm"
                  variant="danger"
                  disabled={busyId === r.id}
                  onClick={() => handleReject(r.id)}
                >
                  Rechazar
                </Button>
              </div>
            </Card>
          ))}
        </div>
      )}
    </div>
  )
}
