import { Ban } from 'lucide-react'
import {
  STATUS_FLOW,
  STATUS_LABEL,
  type TicketStatus,
} from '../../domain/maintenance/ticket'

// Stepper visual del ciclo de vida: muestra el proceso completo y en qué etapa
// está el ticket. 'cancelled' no es una etapa del flujo, se muestra aparte.
export function TicketStepper({ status }: { status: TicketStatus }) {
  if (status === 'cancelled') {
    return (
      <span className="inline-flex items-center gap-1 rounded bg-red-50 px-2 py-0.5 text-xs font-medium text-red-600">
        <Ban size={13} /> Cancelado
      </span>
    )
  }

  const current = STATUS_FLOW.indexOf(status)

  return (
    <ol className="flex flex-wrap items-center gap-y-1">
      {STATUS_FLOW.map((s, i) => {
        const done = i < current
        const active = i === current
        return (
          <li key={s} className="flex items-center">
            {i > 0 && (
              <span
                className={`mx-1 h-px w-4 ${i <= current ? 'bg-blue-400' : 'bg-slate-200'}`}
              />
            )}
            <span className="flex items-center gap-1">
              <span
                className={`h-2 w-2 rounded-full ${
                  active
                    ? 'bg-blue-600 ring-2 ring-blue-200'
                    : done
                      ? 'bg-blue-400'
                      : 'bg-slate-300'
                }`}
              />
              <span
                className={`text-xs ${
                  active
                    ? 'font-semibold text-blue-700'
                    : done
                      ? 'text-slate-600'
                      : 'text-slate-400'
                }`}
              >
                {STATUS_LABEL[s]}
              </span>
            </span>
          </li>
        )
      })}
    </ol>
  )
}
