import { supabase } from './supabase'
import type { StaySegment } from '../domain/stays/staySegment'

interface SegmentRow {
  id: string
  room_id: string
  rate_bs: number | string
  start_date: string
  end_date: string
  reason: string | null
  rooms: { room_number: string } | null
  room_types: { name: string } | null
}

// Tramos de la estadía en curso de una habitación, en orden cronológico.
export async function fetchStaySegments(reservationId: string): Promise<StaySegment[]> {
  const { data, error } = await supabase
    .from('stay_segments')
    .select('id, room_id, rate_bs, start_date, end_date, reason, rooms ( room_number ), room_types ( name )')
    .eq('reservation_id', reservationId)
    .order('start_date', { ascending: true })
  if (error) throw new Error(error.message)

  return (data as unknown as SegmentRow[]).map((r) => ({
    id: r.id,
    roomId: r.room_id,
    roomNumber: r.rooms?.room_number ?? '—',
    roomType: r.room_types?.name ?? '—',
    rateBs: Number(r.rate_bs),
    startDate: r.start_date,
    endDate: r.end_date,
    reason: r.reason,
  }))
}

// Mueve la fecha de salida: el huésped se queda más noches o se va antes.
// La tarifa sólo hace falta al EXTENDER — las noches que ya estaban tienen
// su precio. Devuelve el total nuevo de la estadía.
export async function modifyStayDates(
  roomId: string,
  newCheckOut: string,
  rateBs: number | null,
  reason: string,
): Promise<number> {
  const { data, error } = await supabase.rpc('modify_stay_dates', {
    p_room_id: roomId,
    p_new_check_out: newCheckOut,
    p_rate_bs: rateBs,
    p_reason: reason.trim() || null,
  })
  if (error) throw new Error(error.message)
  return Number(data)
}

// El huésped se muda a otra habitación desde `fromDate` (default: hoy).
// Devuelve el total nuevo de la estadía.
export async function changeRoom(input: {
  roomId: string
  newRoomId: string
  newRoomTypeId: string
  rateBs: number
  fromDate: string | null
  reason: string
}): Promise<number> {
  const { data, error } = await supabase.rpc('change_room', {
    p_room_id: input.roomId,
    p_new_room_id: input.newRoomId,
    p_new_room_type_id: input.newRoomTypeId,
    p_rate_bs: input.rateBs,
    p_from: input.fromDate,
    p_reason: input.reason.trim() || null,
  })
  if (error) throw new Error(error.message)
  return Number(data)
}
