import { useEffect, useState } from 'react'
import {
  assignTicket,
  createTicket,
  deleteTicket,
  fetchCategories,
  fetchTickets,
  updateTicketStatus,
} from '../../services/maintenance'
import { fetchRooms } from '../../services/rooms'
import { fetchAssignableStaff } from '../../services/tasks'
import type { Room } from '../../domain/rooms/room'
import type { AssignableStaff } from '../../domain/tasks/task'
import {
  categoryLabeler,
  NEXT_STATUS,
  PRIORITY_LABEL,
  STATUS_LABEL,
  type Category,
  type Ticket,
  type TicketCategory,
  type TicketPriority,
  type TicketStatus,
} from '../../domain/maintenance/ticket'
import { TicketParts } from './TicketParts'
import { TicketHistory } from './TicketHistory'
import { TicketStepper } from './TicketStepper'
import { SchedulesPanel } from './SchedulesPanel'
import { MaintenanceMetrics } from './MaintenanceMetrics'
import type { UserRole } from '../../domain/auth/profile'
import { PageHeader } from '../../components/ui'

const fmtBs = (n: number) => `${Math.round(n).toLocaleString('es-BO')} Bs`

const PRIORITIES = Object.keys(PRIORITY_LABEL) as TicketPriority[]

const PRIORITY_STYLE: Record<TicketPriority, string> = {
  low: 'bg-slate-100 text-slate-600',
  medium: 'bg-blue-100 text-blue-700',
  high: 'bg-amber-100 text-amber-700',
  urgent: 'bg-red-100 text-red-700',
}
const FILTERS: { id: TicketStatus | 'all'; label: string }[] = [
  { id: 'all', label: 'Todos' },
  { id: 'open', label: 'Abiertos' },
  { id: 'assigned', label: 'Asignados' },
  { id: 'in_progress', label: 'En progreso' },
  { id: 'resolved', label: 'Resueltos' },
  { id: 'closed', label: 'Cerrados' },
]

export function MaintenanceView({ role }: { role?: UserRole | null }) {
  const [tickets, setTickets] = useState<Ticket[]>([])
  const [rooms, setRooms] = useState<Room[]>([])
  const [staff, setStaff] = useState<AssignableStaff[]>([])
  const [categories, setCategories] = useState<Category[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [filter, setFilter] = useState<TicketStatus | 'all'>('open')
  const [subView, setSubView] = useState<'tickets' | 'preventive' | 'metrics'>('tickets')
  const [expandedId, setExpandedId] = useState<string | null>(null)

  // Formulario de alta.
  const [title, setTitle] = useState('')
  const [description, setDescription] = useState('')
  const [category, setCategory] = useState<TicketCategory>('other')
  const [priority, setPriority] = useState<TicketPriority>('medium')
  const [roomId, setRoomId] = useState('')
  const [area, setArea] = useState('')

  function reload() {
    return fetchTickets()
      .then(setTickets)
      .catch((e: Error) => setError(e.message))
  }

  useEffect(() => {
    Promise.all([fetchTickets(), fetchRooms(), fetchAssignableStaff(), fetchCategories()])
      .then(([t, r, s, c]) => {
        setTickets(t)
        setRooms(r)
        setStaff(s)
        setCategories(c)
        if (c[0]) setCategory(c[0].code)
      })
      .catch((e: Error) => setError(e.message))
      .finally(() => setLoading(false))
  }, [])

  const catLabel = categoryLabeler(categories)

  async function run(action: () => Promise<void>) {
    setBusy(true)
    setError(null)
    try {
      await action()
      await reload()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  function handleCreate() {
    if (!title.trim()) {
      setError('El título es obligatorio')
      return
    }
    if (!roomId && !area.trim()) {
      setError('Indicá una habitación o un área')
      return
    }
    run(async () => {
      await createTicket({
        title: title.trim(),
        description: description.trim(),
        category,
        priority,
        roomId: roomId || null,
        area: area.trim(),
      })
      setTitle('')
      setDescription('')
      setArea('')
      setRoomId('')
      setPriority('medium')
      setCategory('ac')
    })
  }

  const visible =
    filter === 'all' ? tickets : tickets.filter((t) => t.status === filter)

  if (loading) return <p className="p-8 text-slate-500">Cargando tickets…</p>

  return (
    <div className="mx-auto max-w-6xl p-6">
      <PageHeader
        title="Mantenimiento"
        subtitle={`${tickets.filter((t) => ['open', 'assigned', 'in_progress'].includes(t.status)).length} activos · ${tickets.length} en total`}
      />

      {/* Sub-navegación: tickets vs preventivo */}
      <div className="mb-6 flex gap-2 border-b border-slate-200">
        {([
          ['tickets', 'Tickets'],
          ['preventive', 'Preventivo'],
          ['metrics', 'Métricas'],
        ] as const).map(([id, label]) => (
          <button
            key={id}
            type="button"
            onClick={() => setSubView(id)}
            className={`-mb-px border-b-2 px-3 py-2 text-sm font-medium ${
              subView === id
                ? 'border-brand-600 text-brand-700'
                : 'border-transparent text-slate-500 hover:text-slate-700'
            }`}
          >
            {label}
          </button>
        ))}
      </div>

      {subView === 'metrics' ? (
        <MaintenanceMetrics />
      ) : subView === 'preventive' ? (
        <SchedulesPanel onGenerated={() => void reload()} />
      ) : (
        <>
      {error && (
        <p className="mb-4 rounded bg-red-50 p-2 text-sm text-red-700">{error}</p>
      )}

      {/* Alta de ticket */}
      <div className="mb-6 rounded-lg border border-slate-200 bg-white p-4 shadow-sm">
        <h2 className="mb-3 font-semibold text-slate-700">Abrir ticket</h2>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <input
            placeholder="Título (ej: Aire acondicionado no enfría)"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            className="w-full rounded border border-slate-300 p-2 sm:col-span-2"
          />
          <select value={category} onChange={(e) => setCategory(e.target.value)}
            className="w-full rounded border border-slate-300 p-2">
            {categories.map((c) => (
              <option key={c.code} value={c.code}>{c.label}</option>
            ))}
          </select>
          <select value={priority} onChange={(e) => setPriority(e.target.value as TicketPriority)}
            className="w-full rounded border border-slate-300 p-2">
            {PRIORITIES.map((p) => (
              <option key={p} value={p}>Prioridad: {PRIORITY_LABEL[p]}</option>
            ))}
          </select>
          <select value={roomId} onChange={(e) => setRoomId(e.target.value)}
            className="w-full rounded border border-slate-300 p-2">
            <option value="">Habitación… (opcional)</option>
            {rooms.map((r) => (
              <option key={r.id} value={r.id}>Hab. {r.roomNumber}</option>
            ))}
          </select>
          <input
            placeholder="…o área (lobby, cocina, pasillo)"
            value={area}
            onChange={(e) => setArea(e.target.value)}
            className="w-full rounded border border-slate-300 p-2"
          />
          <textarea
            placeholder="Descripción (qué falla, desde cuándo)"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            className="w-full rounded border border-slate-300 p-2 sm:col-span-2"
            rows={2}
          />
        </div>
        <button
          type="button"
          disabled={busy}
          onClick={handleCreate}
          className="mt-3 rounded bg-brand-700 px-4 py-2 font-medium text-white hover:bg-brand-800 disabled:opacity-50"
        >
          {busy ? 'Guardando…' : 'Abrir ticket'}
        </button>
      </div>

      {/* Filtros */}
      <div className="mb-4 flex flex-wrap gap-2">
        {FILTERS.map((f) => (
          <button
            key={f.id}
            type="button"
            onClick={() => setFilter(f.id)}
            className={`rounded-full px-3 py-1 text-sm ${
              filter === f.id
                ? 'bg-slate-800 text-white'
                : 'bg-slate-100 text-slate-600 hover:bg-slate-200'
            }`}
          >
            {f.label}
          </button>
        ))}
      </div>

      {/* Lista */}
      <div className="space-y-3">
        {visible.length === 0 && (
          <p className="text-sm text-slate-400">No hay tickets en este filtro.</p>
        )}
        {visible.map((t) => (
          <div key={t.id} className="rounded-lg border border-slate-200 bg-white p-4 shadow-sm">
            <div className="flex flex-wrap items-start justify-between gap-2">
              <div>
                <div className="flex items-center gap-2">
                  <span className="text-xs font-mono text-slate-400">MT-{t.ticketNo}</span>
                  <span className={`rounded px-1.5 py-0.5 text-xs font-medium ${PRIORITY_STYLE[t.priority]}`}>
                    {PRIORITY_LABEL[t.priority]}
                  </span>
                </div>
                <p className="mt-1 font-semibold text-slate-800">{t.title}</p>
                <p className="text-xs text-slate-500">
                  {catLabel(t.category)} ·{' '}
                  {t.roomNumber ? `Hab. ${t.roomNumber}` : t.area ?? 'Sin ubicación'}
                  {t.assigneeName && ` · ${t.assigneeName}`}
                </p>
                <div className="mt-2">
                  <TicketStepper status={t.status} />
                </div>
                {t.description && (
                  <p className="mt-1 text-sm text-slate-600">{t.description}</p>
                )}
              </div>
              {t.partsTotalBs > 0 && (
                <span className="rounded bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-600">
                  Gasto: {fmtBs(t.partsTotalBs)}
                </span>
              )}
            </div>

            {/* Acciones: asignar + avanzar estado + repuestos */}
            <div className="mt-3 flex flex-wrap items-center gap-2">
              {t.status === 'open' && (
                <select
                  defaultValue=""
                  disabled={busy}
                  onChange={(e) => e.target.value && run(() => assignTicket(t.id, e.target.value))}
                  className="rounded border border-slate-300 p-1.5 text-sm"
                >
                  <option value="">Asignar a…</option>
                  {staff.map((s) => (
                    <option key={s.personId} value={s.personId}>{s.fullName}</option>
                  ))}
                </select>
              )}
              {NEXT_STATUS[t.status].map((next) => (
                <button
                  key={next}
                  type="button"
                  disabled={busy}
                  onClick={() => run(() => updateTicketStatus(t.id, next))}
                  className="rounded border border-slate-300 px-2.5 py-1 text-sm text-slate-600 hover:bg-slate-50 disabled:opacity-50"
                >
                  → {STATUS_LABEL[next]}
                </button>
              ))}
              <button
                type="button"
                onClick={() => setExpandedId(expandedId === t.id ? null : t.id)}
                className="rounded border border-slate-300 px-2.5 py-1 text-sm text-slate-600 hover:bg-slate-50"
              >
                {expandedId === t.id ? 'Ocultar detalle' : 'Detalle'}
              </button>
              {role === 'root' && (
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => {
                    if (window.confirm(`¿Eliminar el ticket MT-${t.ticketNo}? Esta acción no se puede deshacer.`)) {
                      run(() => deleteTicket(t.id))
                    }
                  }}
                  className="ml-auto rounded border border-red-200 px-2.5 py-1 text-sm text-red-600 hover:bg-red-50 disabled:opacity-50"
                >
                  Eliminar
                </button>
              )}
            </div>

            {expandedId === t.id && (
              <>
                <TicketHistory ticketId={t.id} />
                <TicketParts ticketId={t.id} onChange={() => void reload()} />
              </>
            )}
          </div>
        ))}
      </div>
        </>
      )}
    </div>
  )
}
