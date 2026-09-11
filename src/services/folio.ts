import { supabase } from './supabase'
import { balanceDue, netAnticipos, type Folio } from '../domain/folios/folio'
import type { AnticipoStatus } from '../domain/anticipos/anticipos'
import { toUserMessage } from './dbErrors'

interface ChargeRow {
  id: string
  description: string
  amount_bs: number
}
interface AnticipoRow {
  amount_bs: number
  status: string
}
interface FolioRow {
  reservations: {
    id: string
    total_amount_bs: number
    room_types: { name: string }
    anticipos: AnticipoRow[]
  }
  folio_charges: ChargeRow[]
}

// Trae el folio de la habitación ocupada: cargo de habitación + consumos,
// y los anticipos de la reserva.
//
// Los anticipos van EN el folio, no aparte: si no se ven acá, el
// check-out cobra el total otra vez (plata que ya entró a caja cuando se
// recibió el anticipo) y el huésped paga dos veces.
export async function fetchFolio(roomId: string): Promise<Folio | null> {
  const { data, error } = await supabase
    .from('folios')
    .select(
      `
      reservations!inner (
        id, total_amount_bs, room_types ( name ),
        anticipos ( amount_bs, status )
      ),
      folio_charges ( id, description, amount_bs )
    `,
    )
    .eq('reservations.room_id', roomId)
    .eq('reservations.status', 'checked_in')
    .maybeSingle()

  if (error) throw new Error(error.message)
  if (!data) return null

  const row = data as unknown as FolioRow
  const charges = row.folio_charges.map((c) => ({
    id: c.id,
    description: c.description,
    amountBs: Number(c.amount_bs),
  }))
  const roomChargeBs = Number(row.reservations.total_amount_bs)
  const extrasTotalBs = charges.reduce((sum, c) => sum + c.amountBs, 0)
  const totalBs = roomChargeBs + extrasTotalBs
  const anticipoTotalBs = netAnticipos(
    (row.reservations.anticipos ?? []).map((a) => ({
      amountBs: Number(a.amount_bs),
      status: a.status as AnticipoStatus,
    })),
  )

  return {
    reservationId: row.reservations.id,
    roomType: row.reservations.room_types.name,
    roomChargeBs,
    charges,
    extrasTotalBs,
    totalBs,
    anticipoTotalBs,
    balanceDueBs: balanceDue(totalBs, anticipoTotalBs),
  }
}

// Agrega un consumo LIBRE al folio (servicios sin inventario: spa, lavandería).
// consumerPersonId es obligatorio: la RPC rechaza el cargo si el huésped
// indicado no está alojado en esta estadía (trigger
// folio_charges_consumer_is_occupant, PR5).
export async function addFolioCharge(
  roomId: string,
  description: string,
  amount: number,
  consumerPersonId: string,
): Promise<void> {
  const { error } = await supabase.rpc('add_folio_charge', {
    p_room_id: roomId,
    p_description: description,
    p_amount: amount,
    p_consumer_person_id: consumerPersonId,
  })
  if (error) throw new Error(toUserMessage(error))
}

// Carga un PRODUCTO del inventario (minibar): descuenta stock y cobra venta.
export async function addFolioProductCharge(
  roomId: string,
  productId: string,
  quantity: number,
  consumerPersonId: string,
): Promise<void> {
  const { error } = await supabase.rpc('add_folio_product_charge', {
    p_room_id: roomId,
    p_product_id: productId,
    p_quantity: quantity,
    p_consumer_person_id: consumerPersonId,
  })
  if (error) throw new Error(toUserMessage(error))
}
