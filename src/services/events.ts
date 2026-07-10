import { supabase } from './supabase'
import type {
  EventArea,
  EventStatus,
  EventType,
  HotelEvent,
  PaymentMethod,
} from '../domain/events/event'

export async function fetchEventTypes(): Promise<EventType[]> {
  const { data, error } = await supabase
    .from('event_types')
    .select('id, name')
    .eq('active', true)
    .order('name')
  if (error) throw new Error(error.message)
  return data as EventType[]
}

export async function fetchEventAreas(): Promise<EventArea[]> {
  const { data, error } = await supabase
    .from('event_areas')
    .select('id, name')
    .eq('active', true)
    .order('name')
  if (error) throw new Error(error.message)
  return data as EventArea[]
}

export async function createEventType(name: string): Promise<EventType> {
  const { data, error } = await supabase
    .from('event_types')
    .insert({ name })
    .select('id, name')
    .single()
  if (error) throw new Error(error.message)
  return data as EventType
}

export async function createEventArea(name: string): Promise<EventArea> {
  const { data, error } = await supabase
    .from('event_areas')
    .insert({ name })
    .select('id, name')
    .single()
  if (error) throw new Error(error.message)
  return data as EventArea
}

interface EventRow {
  id: string
  title: string
  event_date: string
  start_time: string | null
  end_time: string | null
  price_bs: number
  status: EventStatus
  notes: string | null
  event_types: { name: string } | null
  event_area_use: { event_areas: { name: string } | null }[]
  event_payments: {
    id: string
    amount_bs: number
    method: PaymentMethod
    is_deposit: boolean
    paid_at: string
  }[]
}

export async function fetchEvents(): Promise<HotelEvent[]> {
  const { data, error } = await supabase
    .from('events')
    .select(
      'id, title, event_date, start_time, end_time, price_bs, status, notes, ' +
        'event_types ( name ), ' +
        'event_area_use ( event_areas ( name ) ), ' +
        'event_payments ( id, amount_bs, method, is_deposit, paid_at )',
    )
    .order('event_date', { ascending: false })
  if (error) throw new Error(error.message)

  return (data as unknown as EventRow[]).map((r) => {
    const payments = (r.event_payments ?? []).map((p) => ({
      id: p.id,
      amountBs: Number(p.amount_bs),
      method: p.method,
      isDeposit: p.is_deposit,
      paidAt: p.paid_at,
    }))
    return {
      id: r.id,
      title: r.title,
      typeName: r.event_types?.name ?? null,
      eventDate: r.event_date,
      startTime: r.start_time,
      endTime: r.end_time,
      priceBs: Number(r.price_bs),
      status: r.status,
      notes: r.notes,
      areas: (r.event_area_use ?? [])
        .map((a) => a.event_areas?.name)
        .filter((n): n is string => !!n),
      payments,
      paidBs: payments.reduce((s, p) => s + p.amountBs, 0),
    }
  })
}

export async function createEvent(input: {
  title: string
  typeId: string | null
  eventDate: string
  startTime: string
  endTime: string
  priceBs: number
  notes: string
  areaIds: string[]
}): Promise<void> {
  const { data, error } = await supabase
    .from('events')
    .insert({
      title: input.title,
      type_id: input.typeId,
      event_date: input.eventDate,
      start_time: input.startTime || null,
      end_time: input.endTime || null,
      price_bs: input.priceBs,
      notes: input.notes || null,
    })
    .select('id')
    .single()
  if (error) throw new Error(error.message)

  if (input.areaIds.length > 0) {
    const rows = input.areaIds.map((area_id) => ({ event_id: data.id, area_id }))
    const { error: aErr } = await supabase.from('event_area_use').insert(rows)
    if (aErr) throw new Error(aErr.message)
  }
}

export async function setEventStatus(id: string, status: EventStatus): Promise<void> {
  const { error } = await supabase.from('events').update({ status }).eq('id', id)
  if (error) throw new Error(error.message)
}

// Registra un pago (adelanto o final); si es efectivo alimenta la caja.
export async function addEventPayment(
  eventId: string,
  amount: number,
  method: PaymentMethod,
  isDeposit: boolean,
): Promise<void> {
  const { error } = await supabase.rpc('add_event_payment', {
    p_event_id: eventId,
    p_amount: amount,
    p_method: method,
    p_is_deposit: isDeposit,
  })
  if (error) throw new Error(error.message)
}
