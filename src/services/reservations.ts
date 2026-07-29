import { supabase } from './supabase'
import type { AvailableRoom } from '../domain/reservations/availability'
import type { RoomType } from '../domain/rooms/room'
import type { OccupancySpan } from '../domain/availability/occupancy'

interface AvailableRoomRow {
  room_id: string
  room_number: string
  floor: number
  zone: string | null
  suitable_types: RoomType[] // jsonb ya en camelCase desde la función
}

// Busca habitaciones disponibles para el rango y cantidad de personas.
export async function searchAvailableRooms(
  checkIn: string,
  checkOut: string,
  pax: number,
): Promise<AvailableRoom[]> {
  const { data, error } = await supabase.rpc('available_rooms', {
    p_check_in: checkIn,
    p_check_out: checkOut,
    p_pax: pax,
  })
  if (error) throw new Error(error.message)

  return (data as AvailableRoomRow[]).map((r) => ({
    roomId: r.room_id,
    roomNumber: r.room_number,
    floor: r.floor,
    zone: r.zone,
    suitableTypes: r.suitable_types.map((t) => ({
      id: t.id,
      name: t.name,
      basePriceBs: Number(t.basePriceBs),
      maxOccupancy: t.maxOccupancy,
    })),
  }))
}

// Reservas activas (confirmadas o con huésped adentro) que se solapan con
// el rango [from, to], para la grilla de disponibilidad. Una reserva ocupa
// [check_in, check_out): se solapa si check_in <= to y check_out > from.
export async function fetchOccupancy(
  from: string,
  to: string,
): Promise<OccupancySpan[]> {
  const { data, error } = await supabase
    .from('reservations')
    .select('room_id, check_in_date, check_out_date')
    .in('status', ['confirmed', 'checked_in'])
    .lte('check_in_date', to)
    .gt('check_out_date', from)
  if (error) throw new Error(error.message)
  return (data ?? []).map((r) => ({
    roomId: r.room_id as string,
    checkIn: r.check_in_date as string,
    checkOut: r.check_out_date as string,
  }))
}

export interface ReservationInput {
  roomId: string
  roomTypeId: string
  firstName: string
  lastName: string
  phone: string
  email: string
  checkIn: string
  checkOut: string
  numGuests: number
  method: string
  // Tarifa editable al crear la reserva (root/reception/reception_admin).
  // Si difiere del precio de lista, la justificación es OBLIGATORIA — se
  // valida en la RPC (create_reservation en
  // 20260722020000_discount_approval_workflow.sql). Si el descuento
  // implícito supera el 20% y quien crea NO es reception_admin, la
  // reserva se crea igual a precio de lista y queda una solicitud
  // pendiente de aprobación (ver rateDiscountRequestsService).
  rateBs?: number | null
  reason?: string | null
}

// Devuelve el id de la reserva creada (necesario para poder chequear, del
// lado del cliente, si quedó una solicitud de descuento pendiente).
export async function createReservation(data: ReservationInput): Promise<string> {
  const { data: reservationId, error } = await supabase.rpc('create_reservation', {
    p_room_id: data.roomId,
    p_room_type_id: data.roomTypeId,
    p_first_name: data.firstName,
    p_last_name: data.lastName,
    p_phone: data.phone,
    p_email: data.email,
    p_check_in: data.checkIn,
    p_check_out: data.checkOut,
    p_num_guests: data.numGuests,
    p_method: data.method,
    p_rate_bs: data.rateBs ?? null,
    p_reason: data.reason ?? null,
  })
  if (error) throw new Error(error.message)
  return reservationId as string
}

// Cancela una reserva confirmada. El anticipo (si lo hay) se pierde: no
// hay reembolso (regla de negocio). La justificación es obligatoria — se
// valida acá (fail-fast) y de nuevo en la RPC cancel_reservation.
export async function cancelReservation(
  reservationId: string,
  reason: string,
): Promise<void> {
  const trimmed = reason.trim()
  if (!trimmed) {
    throw new Error('La justificación es obligatoria')
  }
  const { error } = await supabase.rpc('cancel_reservation', {
    p_reservation_id: reservationId,
    p_reason: trimmed,
  })
  if (error) throw new Error(error.message)
}

// Reprograma (mueve las fechas de) una reserva confirmada. La RPC
// re-chequea disponibilidad de la misma habitación y recalcula el total
// conservando la tarifa por noche. La justificación es obligatoria.
export async function rescheduleReservation(
  reservationId: string,
  checkIn: string,
  checkOut: string,
  reason: string,
): Promise<void> {
  const trimmed = reason.trim()
  if (!trimmed) {
    throw new Error('La justificación es obligatoria')
  }
  if (checkOut <= checkIn) {
    throw new Error('La fecha de salida debe ser posterior a la de entrada')
  }
  const { error } = await supabase.rpc('reschedule_reservation', {
    p_reservation_id: reservationId,
    p_check_in: checkIn,
    p_check_out: checkOut,
    p_reason: trimmed,
  })
  if (error) throw new Error(error.message)
}
