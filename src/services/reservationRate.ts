import { supabase } from './supabase'

export interface ReservationRateInfo {
  currentRateBs: number | null
  baseRateBs: number | null
}

interface ReservationRateRow {
  total_amount_bs: number | string | null
  check_in_date: string
  check_out_date: string
  room_types: { base_price_bs: number | string | null } | null
}

// Tarifa vigente de una reserva confirmada (pre check-in), SIN migración:
// reservations.total_amount_bs YA es el total acordado (create_reservation
// y override_reservation_rate lo escriben como precio_noche * noches, ver
// 20260722010000_reception_admin_role.sql) y room_types.base_price_bs es
// el precio de lista del tipo. Se muestran los dos porque pueden diferir
// (tarifa custom al reservar) — issue 1 del smoke test manual: el botón
// "Editar tarifa" del check-in no mostraba ninguno de los dos, así que no
// había cómo saber si hacía falta cambiarla.
export async function fetchReservationRate(
  reservationId: string,
): Promise<ReservationRateInfo> {
  const { data, error } = await supabase
    .from('reservations')
    .select('total_amount_bs, check_in_date, check_out_date, room_types(base_price_bs)')
    .eq('id', reservationId)
    .single()
  if (error) throw new Error(error.message)

  const row = data as unknown as ReservationRateRow
  const nights = Math.max(
    1,
    Math.round(
      (new Date(row.check_out_date).getTime() - new Date(row.check_in_date).getTime()) /
        86_400_000,
    ),
  )
  const total = row.total_amount_bs != null ? Number(row.total_amount_bs) : null
  return {
    currentRateBs: total != null ? total / nights : null,
    baseRateBs:
      row.room_types?.base_price_bs != null ? Number(row.room_types.base_price_bs) : null,
  }
}
