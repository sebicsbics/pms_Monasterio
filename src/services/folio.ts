import { supabase } from './supabase'
import { balanceDue, netAnticipos, type Folio } from '../domain/folios/folio'

interface ChargeRow {
  id: string
  description: string
  amount_bs: number
}
// Los reembolsos NO son una columna del anticipo: viven en la bitácora
// append-only `anticipo_corrections` (action='refund'). Se traen anidados
// para calcular el neto sin un segundo viaje a la base.
interface AnticipoRow {
  amount_bs: number
  status: string
  anticipo_corrections: { action: string; refund_amount_bs: number | null }[] | null
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
        anticipos (
          amount_bs, status,
          anticipo_corrections ( action, refund_amount_bs )
        )
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
      status: a.status,
      refundedBs: (a.anticipo_corrections ?? [])
        .filter((c) => c.action === 'refund')
        .reduce((sum, c) => sum + Number(c.refund_amount_bs ?? 0), 0),
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
export async function addFolioCharge(
  roomId: string,
  description: string,
  amount: number,
): Promise<void> {
  const { error } = await supabase.rpc('add_folio_charge', {
    p_room_id: roomId,
    p_description: description,
    p_amount: amount,
  })
  if (error) throw new Error(error.message)
}

// Carga un PRODUCTO del inventario (minibar): descuenta stock y cobra venta.
export async function addFolioProductCharge(
  roomId: string,
  productId: string,
  quantity: number,
): Promise<void> {
  const { error } = await supabase.rpc('add_folio_product_charge', {
    p_room_id: roomId,
    p_product_id: productId,
    p_quantity: quantity,
  })
  if (error) throw new Error(error.message)
}
