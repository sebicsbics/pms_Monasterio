// Una llegada: reserva confirmada pendiente de check-in.
export interface Arrival {
  reservationId: string
  roomId: string
  roomNumber: string
  roomType: string
  firstName: string
  lastName: string
  phone: string | null
  email: string | null
  checkInDate: string
  checkOutDate: string
  numGuests: number | null
  method: string
}
