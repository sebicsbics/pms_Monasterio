import { useEffect, useState } from 'react'
import {
  createSchedule,
  fetchCategories,
  fetchSchedules,
  generateTicketFromSchedule,
  setScheduleActive,
} from '../../services/maintenance'
import { fetchRooms } from '../../services/rooms'
import type { Room } from '../../domain/rooms/room'
import {
  categoryLabeler,
  isDue,
  PRIORITY_LABEL,
  type Category,
  type Schedule,
  type TicketCategory,
  type TicketPriority,
} from '../../domain/maintenance/ticket'

const PRIORITIES = Object.keys(PRIORITY_LABEL) as TicketPriority[]

export function SchedulesPanel({ onGenerated }: { onGenerated: () => void }) {
  const [schedules, setSchedules] = useState<Schedule[]>([])
  const [rooms, setRooms] = useState<Room[]>([])
  const [categories, setCategories] = useState<Category[]>([])
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [msg, setMsg] = useState<string | null>(null)

  const [title, setTitle] = useState('')
  const [category, setCategory] = useState<TicketCategory>('other')
  const [priority, setPriority] = useState<TicketPriority>('medium')
  const [roomId, setRoomId] = useState('')
  const [area, setArea] = useState('')
  const [freq, setFreq] = useState('90')
  const [nextDue, setNextDue] = useState(new Date().toISOString().slice(0, 10))
  const [notes, setNotes] = useState('')

  function reload() {
    return fetchSchedules()
      .then(setSchedules)
      .catch((e: Error) => setError(e.message))
  }

  useEffect(() => {
    Promise.all([fetchSchedules(), fetchRooms(), fetchCategories()])
      .then(([s, r, c]) => {
        setSchedules(s)
        setRooms(r)
        setCategories(c)
        if (c[0]) setCategory(c[0].code)
      })
      .catch((e: Error) => setError(e.message))
      .finally(() => setLoading(false))
  }, [])

  const catLabel = categoryLabeler(categories)

  async function run(action: () => Promise<void>, ok?: string) {
    setBusy(true)
    setError(null)
    setMsg(null)
    try {
      await action()
      await reload()
      if (ok) setMsg(ok)
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  function handleCreate() {
    const f = Number(freq)
    if (!title.trim() || !(f > 0)) {
      setError('Título y frecuencia (días) > 0 son obligatorios')
      return
    }
    if (!roomId && !area.trim()) {
      setError('Indicá una habitación o un área')
      return
    }
    run(async () => {
      await createSchedule({
        title: title.trim(),
        category,
        priority,
        roomId: roomId || null,
        area: area.trim(),
        frequencyDays: f,
        nextDueAt: nextDue,
        notes: notes.trim(),
      })
      setTitle('')
      setArea('')
      setRoomId('')
      setNotes('')
    })
  }

  if (loading) return <p className="p-8 text-slate-500">Cargando agendas…</p>

  return (
    <div>
      {error && <p className="mb-4 rounded bg-red-50 p-2 text-sm text-red-700">{error}</p>}
      {msg && <p className="mb-4 rounded bg-green-50 p-2 text-sm text-green-700">{msg}</p>}

      {/* Alta de agenda */}
      <div className="mb-6 rounded-lg border border-slate-200 bg-white p-4 shadow-sm">
        <h2 className="mb-3 font-semibold text-slate-700">Nueva revisión periódica</h2>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <input placeholder="Título (ej: Limpieza de filtros de AC)" value={title}
            onChange={(e) => setTitle(e.target.value)}
            className="w-full rounded border border-slate-300 p-2 sm:col-span-2" />
          <select value={category} onChange={(e) => setCategory(e.target.value)}
            className="w-full rounded border border-slate-300 p-2">
            {categories.map((c) => <option key={c.code} value={c.code}>{c.label}</option>)}
          </select>
          <select value={priority} onChange={(e) => setPriority(e.target.value as TicketPriority)}
            className="w-full rounded border border-slate-300 p-2">
            {PRIORITIES.map((p) => <option key={p} value={p}>Prioridad: {PRIORITY_LABEL[p]}</option>)}
          </select>
          <select value={roomId} onChange={(e) => setRoomId(e.target.value)}
            className="w-full rounded border border-slate-300 p-2">
            <option value="">Habitación… (opcional)</option>
            {rooms.map((r) => <option key={r.id} value={r.id}>Hab. {r.roomNumber}</option>)}
          </select>
          <input placeholder="…o área (lobby, cocina)" value={area}
            onChange={(e) => setArea(e.target.value)}
            className="w-full rounded border border-slate-300 p-2" />
          <label className="block text-sm">
            <span className="text-slate-600">Cada (días)</span>
            <input type="number" min={1} value={freq} onChange={(e) => setFreq(e.target.value)}
              className="mt-1 w-full rounded border border-slate-300 p-2" />
          </label>
          <label className="block text-sm">
            <span className="text-slate-600">Primera fecha</span>
            <input type="date" value={nextDue} onChange={(e) => setNextDue(e.target.value)}
              className="mt-1 w-full rounded border border-slate-300 p-2" />
          </label>
          <textarea placeholder="Notas / instrucciones" value={notes}
            onChange={(e) => setNotes(e.target.value)} rows={2}
            className="w-full rounded border border-slate-300 p-2 sm:col-span-2" />
        </div>
        <button type="button" disabled={busy} onClick={handleCreate}
          className="mt-3 rounded bg-brand-700 px-4 py-2 font-medium text-white hover:bg-brand-800 disabled:opacity-50">
          {busy ? 'Guardando…' : 'Crear agenda'}
        </button>
      </div>

      {/* Lista de agendas */}
      <div className="space-y-3">
        {schedules.length === 0 && (
          <p className="text-sm text-slate-400">No hay revisiones programadas.</p>
        )}
        {schedules.map((s) => {
          const due = s.active && isDue(s.nextDueAt)
          return (
            <div key={s.id}
              className={`rounded-lg border bg-white p-4 shadow-sm ${
                due ? 'border-amber-400' : 'border-slate-200'
              } ${!s.active ? 'opacity-60' : ''}`}>
              <div className="flex flex-wrap items-start justify-between gap-2">
                <div>
                  <div className="flex items-center gap-2">
                    <p className="font-semibold text-slate-800">{s.title}</p>
                    {due && (
                      <span className="rounded bg-amber-100 px-1.5 py-0.5 text-xs font-medium text-amber-700">
                        Vencida
                      </span>
                    )}
                    {!s.active && (
                      <span className="rounded bg-slate-100 px-1.5 py-0.5 text-xs text-slate-500">
                        Pausada
                      </span>
                    )}
                  </div>
                  <p className="text-xs text-slate-500">
                    {catLabel(s.category)} ·{' '}
                    {s.roomNumber ? `Hab. ${s.roomNumber}` : s.area ?? 'Sin ubicación'} · cada{' '}
                    {s.frequencyDays} días · próxima: {s.nextDueAt}
                    {s.lastDoneAt && ` · última: ${s.lastDoneAt}`}
                  </p>
                </div>
                <div className="flex items-center gap-2">
                  <button type="button" disabled={busy}
                    onClick={() =>
                      run(() => generateTicketFromSchedule(s.id), 'Ticket preventivo generado').then(onGenerated)
                    }
                    className="rounded bg-brand-700 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-800 disabled:opacity-50">
                    Generar ticket
                  </button>
                  <button type="button" disabled={busy}
                    onClick={() => run(() => setScheduleActive(s.id, !s.active))}
                    className="rounded border border-slate-300 px-2.5 py-1.5 text-sm text-slate-600 hover:bg-slate-50 disabled:opacity-50">
                    {s.active ? 'Pausar' : 'Reactivar'}
                  </button>
                </div>
              </div>
            </div>
          )
        })}
      </div>
    </div>
  )
}
