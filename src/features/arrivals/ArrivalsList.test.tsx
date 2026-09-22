import '@testing-library/jest-dom/vitest'
import { describe, expect, it, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { ArrivalsList } from './ArrivalsList'
import type { Arrival } from '../../domain/stays/arrival'

// fix/institutional-ui-coherence: el check-in de una habitación enlazada
// a una reserva bulk (payer_mode='client') ya conoce la agencia/empresa
// responsable vía bookings.receivable_account_id -- no debería obligar a
// recepción a retipearla, y el dato de la cuenta es autoritativo (se
// bloquea la edición acá).

let arrivalsToReturn: Arrival[] = []

vi.mock('../../services/arrivals', () => ({
  fetchArrivals: vi.fn(async () => arrivalsToReturn),
  checkInWithOptionalPayment: vi.fn(async () => ({
    reservationId: 'res-1',
    discountMessage: null,
    paymentRecorded: false,
    paymentError: null,
  })),
}))

vi.mock('../../services/checkin', () => ({
  overrideReservationRate: vi.fn(),
}))

vi.mock('../../services/reservationRate', () => ({
  fetchReservationRate: vi.fn(async () => null),
}))

vi.mock('../../services/reservationGuests', () => ({
  fetchPreloadedOccupants: vi.fn(async () => []),
}))

vi.mock('../../services/reservations', () => ({
  cancelReservation: vi.fn(),
  rescheduleReservation: vi.fn(),
}))

vi.mock('../../services/payments', () => ({
  fetchPaymentMethods: vi.fn(async () => []),
}))

function makeArrival(overrides: Partial<Arrival> = {}): Arrival {
  return {
    reservationId: 'res-1',
    roomId: 'room-1',
    roomNumber: '101',
    roomType: 'Doble',
    firstName: 'Org',
    lastName: 'Anizador',
    phone: null,
    email: null,
    checkInDate: '2026-09-22',
    checkOutDate: '2026-09-24',
    numGuests: 2,
    maxOccupancy: 2,
    method: 'web',
    anticipoTotalBs: 0,
    holderFirstName: 'Juan',
    holderLastName: 'Pérez',
    accountName: null,
    accountKind: null,
    ...overrides,
  }
}

describe('ArrivalsList — check-in de reserva institucional precarga la cuenta', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('precarga y bloquea agencia/empresa y canal cuando la reserva tiene cuenta por cobrar', async () => {
    arrivalsToReturn = [
      makeArrival({ accountName: 'Viajes del Sur', accountKind: 'agencia' }),
    ]
    render(<ArrivalsList role="reception_admin" />)

    await screen.findByText('101')
    fireEvent.click(screen.getByRole('button', { name: 'Check-in' }))

    const agencyInput = await screen.findByPlaceholderText('Agencia / empresa (opcional)')
    expect(agencyInput).toHaveValue('Viajes del Sur')
    expect(agencyInput).toBeDisabled()

    const channelSelect = screen.getByDisplayValue('Agencia')
    expect(channelSelect).toBeDisabled()

    expect(
      screen.getByText(/vienen de la cuenta por cobrar de la reserva institucional/i),
    ).toBeInTheDocument()
  })

  it('deja agencia/empresa y canal editables para una reserva each_stay sin cuenta', async () => {
    arrivalsToReturn = [makeArrival({ accountName: null, accountKind: null })]
    render(<ArrivalsList role="reception_admin" />)

    await screen.findByText('101')
    fireEvent.click(screen.getByRole('button', { name: 'Check-in' }))

    const agencyInput = await screen.findByPlaceholderText('Agencia / empresa (opcional)')
    expect(agencyInput).toHaveValue('')
    expect(agencyInput).not.toBeDisabled()
    fireEvent.change(agencyInput, { target: { value: 'Escrito a mano' } })
    await waitFor(() => expect(agencyInput).toHaveValue('Escrito a mano'))
  })
})
