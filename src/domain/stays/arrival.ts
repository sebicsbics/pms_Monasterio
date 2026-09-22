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
  // Titular de la habitación (guest_id), si ya se conoce. Puede ser NULL:
  // reservas creadas con "el contacto no se hospeda" o bulk sin ocupantes
  // precargados no tienen titular hasta el check-in.
  holderFirstName: string | null
  holderLastName: string | null
  // Cuenta por cobrar de la reserva institucional (payer_mode='client'),
  // si tiene una asociada. NULL en reservas each_stay. Se usa para
  // precargar agencia/empresa en el check-in sin retipear un dato que la
  // reserva ya conoce (fix/institutional-ui-coherence).
  accountName: string | null
  accountKind: 'empresa' | 'agencia' | 'persona' | null
}
