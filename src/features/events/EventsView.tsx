import { useCallback, useEffect, useState } from 'react'
import { Plus } from 'lucide-react'
import {
  addEventPayment,
  createEvent,
  createEventArea,
  createEventType,
  fetchEventAreas,
  fetchEvents,
  fetchEventTypes,
  setEventStatus,
} from '../../services/events'
import {
  EVENT_STATUS_LABEL,
  PAYMENT_METHOD_LABEL,
  type EventArea,
  type EventType,
  type HotelEvent,
  type PaymentMethod,
} from '../../domain/events/event'
import { Badge, Button, Card, PageHeader } from '../../components/ui'
import { formatDate } from '../../lib/date'
import type { PaymentProof } from '../../domain/payments/paymentProof'
import {
  EMPTY_PAYMENT_PROOF,
  paymentProofError,
} from '../../domain/payments/paymentProof'
import { PaymentProofFields } from '../payments/PaymentProofFields'

const fmtBs = (n: number) =>
  `${n.toLocaleString('es-BO', { minimumFractionDigits: 2, maximumFractionDigits: 2 })} Bs`
const INPUT = 'w-full rounded-lg border border-slate-300 p-2'
const METHODS = Object.keys(PAYMENT_METHOD_LABEL) as PaymentMethod[]

function Labeled({ label, className = '', children }: {
  label: string; className?: string; children: React.ReactNode
}) {
  return (
    <label className={`block text-sm ${className}`}>
      <span className="mb-1 block text-xs font-medium text-slate-500">{label}</span>
      {children}
    </label>
  )
}

export function EventsView() {
  const [events, setEvents] = useState<HotelEvent[]>([])
  const [types, setTypes] = useState<EventType[]>([])
  const [areas, setAreas] = useState<EventArea[]>([])
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  // Alta de evento
  const [title, setTitle] = useState('')
  const [typeId, setTypeId] = useState('')
  const [date, setDate] = useState('')
  const [start, setStart] = useState('')
  const [end, setEnd] = useState('')
  const [areaIds, setAreaIds] = useState<Set<string>>(new Set())
  const [price, setPrice] = useState('')
  const [notes, setNotes] = useState('')

  // Alta inline de tipo / área
  const [newType, setNewType] = useState('')
  const [newArea, setNewArea] = useState('')

  // Pago (del evento expandido)
  const [expandedId, setExpandedId] = useState<string | null>(null)
  const [payAmount, setPayAmount] = useState('')
  const [payMethod, setPayMethod] = useState<PaymentMethod>('EFECTIVO')
  const [payProof, setPayProof] = useState<PaymentProof>(EMPTY_PAYMENT_PROOF)
  const [payDeposit, setPayDeposit] = useState(false)

  const reload = useCallback(async () => {
    setEvents(await fetchEvents())
  }, [])

  useEffect(() => {
    Promise.all([fetchEvents(), fetchEventTypes(), fetchEventAreas()])
      .then(([e, t, a]) => {
        setEvents(e)
        setTypes(t)
        setAreas(a)
        setTypeId((prev) => prev || t[0]?.id || '')
      })
      .catch((err: Error) => setError(err.message))
      .finally(() => setLoading(false))
  }, [])

  async function run(action: () => Promise<void>) {
    setBusy(true)
    setError(null)
    try {
      await action()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  function toggleArea(id: string) {
    setAreaIds((s) => {
      const n = new Set(s)
      if (n.has(id)) n.delete(id)
      else n.add(id)
      return n
    })
  }

  function handleAddType() {
    const n = newType.trim()
    if (!n) return
    run(async () => {
      const t = await createEventType(n)
      setTypes((ts) => [...ts, t].sort((a, b) => a.name.localeCompare(b.name)))
      setTypeId(t.id)
      setNewType('')
    })
  }

  function handleAddArea() {
    const n = newArea.trim()
    if (!n) return
    run(async () => {
      const a = await createEventArea(n)
      setAreas((as) => [...as, a].sort((x, y) => x.name.localeCompare(y.name)))
      setNewArea('')
    })
  }

  function handleCreate() {
    if (!title.trim() || !date) {
      setError('Título y fecha del evento son obligatorios')
      return
    }
    run(async () => {
      await createEvent({
        title: title.trim(),
        typeId: typeId || null,
        eventDate: date,
        startTime: start,
        endTime: end,
        priceBs: Number(price) || 0,
        notes: notes.trim(),
        areaIds: [...areaIds],
      })
      setTitle('')
      setDate('')
      setStart('')
      setEnd('')
      setPrice('')
      setNotes('')
      setAreaIds(new Set())
      await reload()
    })
  }

  function handlePay(ev: HotelEvent) {
    const amt = Number(payAmount)
    if (!(amt > 0)) {
      setError('El monto debe ser mayor a 0')
      return
    }
    const proofErr = paymentProofError(payMethod, payProof)
    if (proofErr) {
      setError(proofErr)
      return
    }
    run(async () => {
      await addEventPayment(ev.id, amt, payMethod, payDeposit, payProof)
      setPayAmount('')
      setPayDeposit(false)
      setPayProof(EMPTY_PAYMENT_PROOF)
      await reload()
    })
  }

  if (loading) return <p className="p-8 text-slate-500">Cargando eventos…</p>

  return (
    <div className="mx-auto max-w-5xl p-6">
      <PageHeader title="Eventos" subtitle="Salones, bodas, sesiones y más" />

      {error && <p className="mb-4 rounded bg-red-50 p-2 text-sm text-red-700">{error}</p>}

      {/* Alta de evento */}
      <Card className="mb-6 p-4">
        <h3 className="mb-3 font-semibold text-slate-700">Nuevo evento</h3>
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <Labeled label="Evento / cliente" className="col-span-2">
            <input value={title} onChange={(e) => setTitle(e.target.value)}
              placeholder="Ej: Boda García" className={INPUT} />
          </Labeled>
          <Labeled label="Tipo" className="col-span-2">
            <div className="flex gap-1">
              <select value={typeId} onChange={(e) => setTypeId(e.target.value)} className={INPUT}>
                {types.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
              </select>
              <input value={newType} onChange={(e) => setNewType(e.target.value)}
                onKeyDown={(e) => e.key === 'Enter' && handleAddType()}
                placeholder="+ nuevo tipo" className="w-28 rounded-lg border border-slate-300 p-2 text-sm" />
              <button type="button" onClick={handleAddType} aria-label="Agregar tipo"
                className="shrink-0 rounded-lg border border-slate-300 px-2 text-slate-600 hover:bg-slate-50">
                <Plus size={16} />
              </button>
            </div>
          </Labeled>
          <Labeled label="Fecha del evento">
            <input type="date" value={date} onChange={(e) => setDate(e.target.value)} className={INPUT} />
          </Labeled>
          <Labeled label="Desde">
            <input type="time" value={start} onChange={(e) => setStart(e.target.value)} className={INPUT} />
          </Labeled>
          <Labeled label="Hasta">
            <input type="time" value={end} onChange={(e) => setEnd(e.target.value)} className={INPUT} />
          </Labeled>
          <Labeled label="Precio (Bs)">
            <input type="number" min={0} step="0.01" value={price}
              onChange={(e) => setPrice(e.target.value)} className={INPUT} placeholder="0.00" />
          </Labeled>
        </div>

        {/* Áreas */}
        <div className="mt-3">
          <p className="mb-1 text-xs font-medium text-slate-500">Áreas utilizadas</p>
          <div className="flex flex-wrap items-center gap-2">
            {areas.map((a) => {
              const on = areaIds.has(a.id)
              return (
                <button key={a.id} type="button" onClick={() => toggleArea(a.id)}
                  className={`rounded-full border px-3 py-1 text-sm ${
                    on ? 'border-brand-600 bg-brand-50 text-brand-700'
                       : 'border-slate-300 text-slate-600 hover:bg-slate-50'}`}>
                  {a.name}
                </button>
              )
            })}
            <input value={newArea} onChange={(e) => setNewArea(e.target.value)}
              onKeyDown={(e) => e.key === 'Enter' && handleAddArea()}
              placeholder="+ nueva área" className="w-32 rounded-lg border border-slate-300 p-1.5 text-sm" />
            <button type="button" onClick={handleAddArea} aria-label="Agregar área"
              className="rounded-lg border border-slate-300 px-2 py-1.5 text-slate-600 hover:bg-slate-50">
              <Plus size={14} />
            </button>
          </div>
        </div>

        <textarea value={notes} onChange={(e) => setNotes(e.target.value)} rows={2}
          placeholder="Notas (menú, invitados, requerimientos…)" className={`${INPUT} mt-3`} />

        <Button loading={busy} onClick={handleCreate} className="mt-3">Programar evento</Button>
      </Card>

      {/* Lista de eventos */}
      <div className="space-y-3">
        {events.length === 0 && <p className="text-sm text-slate-400">No hay eventos programados.</p>}
        {events.map((ev) => {
          const balance = ev.priceBs - ev.paidBs
          return (
            <Card key={ev.id} className={`p-4 ${ev.status === 'cancelled' ? 'opacity-60' : ''}`}>
              <div className="flex flex-wrap items-start justify-between gap-2">
                <div>
                  <div className="flex items-center gap-2">
                    <p className="font-semibold text-slate-800">{ev.title}</p>
                    {ev.typeName && <Badge tone="brand">{ev.typeName}</Badge>}
                    <Badge tone={ev.status === 'cancelled' ? 'danger' : ev.status === 'done' ? 'neutral' : 'success'}>
                      {EVENT_STATUS_LABEL[ev.status]}
                    </Badge>
                  </div>
                  <p className="mt-1 text-xs text-slate-500">
                    {ev.eventDate}
                    {ev.startTime && ` · ${ev.startTime.slice(0, 5)}`}
                    {ev.endTime && `–${ev.endTime.slice(0, 5)}`}
                    {ev.areas.length > 0 && ` · ${ev.areas.join(', ')}`}
                  </p>
                  {ev.notes && <p className="mt-1 text-sm text-slate-600">{ev.notes}</p>}
                </div>
                <div className="text-right">
                  <p className="tabular font-bold text-slate-800">{fmtBs(ev.priceBs)}</p>
                  {balance > 0.009 ? (
                    <p className="tabular text-xs text-amber-700">Adeuda {fmtBs(balance)}</p>
                  ) : ev.priceBs > 0 ? (
                    <p className="text-xs text-green-700">Pagado</p>
                  ) : null}
                </div>
              </div>

              <div className="mt-3 flex flex-wrap items-center gap-2">
                <Button size="sm" variant="secondary"
                  onClick={() => setExpandedId(expandedId === ev.id ? null : ev.id)}>
                  {expandedId === ev.id ? 'Ocultar pagos' : `Pagos (${ev.payments.length})`}
                </Button>
                {ev.status === 'scheduled' && (
                  <>
                    <Button size="sm" variant="ghost" onClick={() => run(() => setEventStatus(ev.id, 'done').then(reload))}>
                      Marcar realizado
                    </Button>
                    <Button size="sm" variant="ghost" onClick={() => run(() => setEventStatus(ev.id, 'cancelled').then(reload))}>
                      Cancelar
                    </Button>
                  </>
                )}
              </div>

              {expandedId === ev.id && (
                <div className="mt-3 rounded-lg bg-slate-50 p-3">
                  {ev.payments.length > 0 && (
                    <div className="mb-3 space-y-1 text-sm">
                      {ev.payments.map((p) => (
                        <div key={p.id} className="flex justify-between text-slate-600">
                          <span>
                            {p.isDeposit ? 'Adelanto' : 'Pago'} · {PAYMENT_METHOD_LABEL[p.method]} ·{' '}
                            {formatDate(p.paidAt)}
                          </span>
                          <span className="tabular font-medium">{fmtBs(p.amountBs)}</span>
                        </div>
                      ))}
                      <div className="flex justify-between border-t border-slate-200 pt-1 font-semibold text-slate-800">
                        <span>Pagado / Total</span>
                        <span className="tabular">{fmtBs(ev.paidBs)} / {fmtBs(ev.priceBs)}</span>
                      </div>
                    </div>
                  )}
                  <div className="flex flex-wrap items-end gap-2">
                    <input type="number" min={0} step="0.01" value={payAmount}
                      onChange={(e) => setPayAmount(e.target.value)} placeholder="Monto Bs"
                      className="w-28 rounded-lg border border-slate-300 p-2 text-sm" />
                    <select value={payMethod} onChange={(e) => setPayMethod(e.target.value as PaymentMethod)}
                      className="rounded-lg border border-slate-300 p-2 text-sm">
                      {METHODS.map((m) => <option key={m} value={m}>{PAYMENT_METHOD_LABEL[m]}</option>)}
                    </select>
                    <label className="flex items-center gap-1 text-sm text-slate-600">
                      <input type="checkbox" checked={payDeposit} onChange={(e) => setPayDeposit(e.target.checked)} />
                      Adelanto
                    </label>
                    <Button
                      size="sm"
                      loading={busy}
                      disabled={paymentProofError(payMethod, payProof) !== null}
                      onClick={() => handlePay(ev)}
                    >
                      Registrar pago
                    </Button>
                  </div>
                  <PaymentProofFields
                    className="mt-2 max-w-xs"
                    method={payMethod}
                    proof={payProof}
                    onChange={(patch) => setPayProof((p) => ({ ...p, ...patch }))}
                  />
                  {payMethod === 'EFECTIVO' && (
                    <p className="mt-1 text-xs text-slate-400">El efectivo entra a la caja (debe estar abierta).</p>
                  )}
                </div>
              )}
            </Card>
          )
        })}
      </div>
    </div>
  )
}
