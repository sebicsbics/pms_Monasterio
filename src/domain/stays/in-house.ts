// Una estadía en curso (huésped actualmente hospedado).
export interface InHouseStay {
  reservationId: string
  roomId: string
  roomNumber: string
  floor: number
  zone: string | null
  roomType: string
  firstName: string
  lastName: string
  email: string | null
  countryCode: string | null
  city: string | null
  checkInDate: string
  checkOutDate: string
  roomTotalBs: number
  /** Huéspedes realmente hospedados en la habitación (titular + acompañantes). */
  guestCount: number
}
