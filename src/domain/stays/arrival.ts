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
  numGuests: number | null // ocupación ESTIMADA al tomar la reserva
  maxOccupancy: number | null // capacidad real del tipo de habitación
  method: string
  anticipoTotalBs: number // suma de anticipos activos (0 si no tiene)
}
