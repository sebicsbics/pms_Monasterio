import '@testing-library/jest-dom/vitest'
import { describe, expect, it, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { GroupBookingsView } from './GroupBookingsView'

const BOOKING_OPEN = {
  bookingId: 'booking-1',
  accountName: 'Hotel ABC',
  contactName: 'Juan Perez',
  netOwedBs: 2000,
  overdueRooms: [] as string[],
}

let bookings = [BOOKING_OPEN]

vi.mock('../../services/bookings', () => ({
  listClientBookingsBrief: vi.fn(async () => bookings),
  recordBookingAdvance: vi.fn(async () => 'movement-1'),
}))

vi.mock('../../services/payments', () => ({
  fetchPaymentMethods: vi.fn(async () => [
    { code: 'EFECTIVO', label: 'Efectivo' },
  ]),
}))

describe('GroupBookingsView (R11.1–R11.4)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    bookings = [BOOKING_OPEN]
  })

  it('(a) muestra "Saldo pendiente: 2000 Bs" para la reserva seleccionada', async () => {
    render(<GroupBookingsView role="reception" />)
    await screen.findByText(/Hotel ABC/)
    fireEvent.click(screen.getByText(/Hotel ABC/))
    expect((await screen.findAllByText(/Saldo pendiente: 2000 Bs/)).length).toBeGreaterThan(0)
  })

  it('(b) actualiza el saldo mostrado tras registrar un adelanto exitoso', async () => {
    const bookingsService = await import('../../services/bookings')
    render(<GroupBookingsView role="reception" />)
    await screen.findByText(/Hotel ABC/)
    fireEvent.click(screen.getByText(/Hotel ABC/))
    expect((await screen.findAllByText(/Saldo pendiente: 2000 Bs/)).length).toBeGreaterThan(0)

    // Tras registrar, el mock de listClientBookingsBrief refleja el nuevo saldo.
    bookings = [{ ...BOOKING_OPEN, netOwedBs: 1500 }]

    fireEvent.change(screen.getByRole('spinbutton'), { target: { value: '500' } })
    fireEvent.click(screen.getByRole('button', { name: /Registrar adelanto/i }))

    await waitFor(() => {
      expect(bookingsService.recordBookingAdvance).toHaveBeenCalled()
    })
    expect((await screen.findAllByText(/Saldo pendiente: 1500 Bs/)).length).toBeGreaterThan(0)
  })

  it('(c) muestra el aviso de habitaciones vencidas cuando overdueRooms no está vacío', async () => {
    bookings = [{ ...BOOKING_OPEN, overdueRooms: ['101'] }]
    render(<GroupBookingsView role="reception" />)
    await screen.findByText(/Hotel ABC/)
    fireEvent.click(screen.getByText(/Hotel ABC/))
    await screen.findByText(/habitaciones sin check-in con fecha vencida/i)
  })

  it('(d) no muestra el aviso cuando overdueRooms está vacío', async () => {
    render(<GroupBookingsView role="reception" />)
    await screen.findByText(/Hotel ABC/)
    fireEvent.click(screen.getByText(/Hotel ABC/))
    expect((await screen.findAllByText(/Saldo pendiente: 2000 Bs/)).length).toBeGreaterThan(0)
    expect(screen.queryByText(/habitaciones sin check-in con fecha vencida/i)).not.toBeInTheDocument()
  })
})
