// Un consumo cargado al folio (minibar, spa, restaurante...).
export interface FolioCharge {
  id: string
  description: string
  amountBs: number
}

// El folio de una estadía: cargo de habitación + consumos.
export interface Folio {
  reservationId: string
  roomType: string
  roomChargeBs: number // total por la(s) noche(s)
  charges: FolioCharge[]
  extrasTotalBs: number // suma de consumos
  totalBs: number // habitación + consumos
}
