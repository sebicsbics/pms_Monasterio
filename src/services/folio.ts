import { supabase } from './supabase'
import type { Folio } from '../domain/folios/folio'

interface ChargeRow {
  id: string
  description: string
  amount_bs: number
}
interface FolioRow {
  reservations: {
    total_amount_bs: number
    room_types: { name: string }
  }
  folio_charges: ChargeRow[]
}

// Trae el folio de la habitación ocupada: cargo de habitación + consumos.
export async function fetchFolio(roomId: string): Promise<Folio | null> {
  const { data, error } = await supabase
    .from('folios')
    .select(
      `
      reservations!inner ( total_amount_bs, room_types ( name ) ),
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

  return {
    roomType: row.reservations.room_types.name,
    roomChargeBs,
    charges,
    extrasTotalBs,
    totalBs: roomChargeBs + extrasTotalBs,
  }
}

// Agrega un consumo al folio de la habitación ocupada.
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
