import '@testing-library/jest-dom/vitest'
import { describe, expect, it, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { NewReservation } from './NewReservation'

vi.mock('../../services/reservations', () => ({
  searchAvailableRooms: vi.fn(async () => [
    {
      roomId: 'room-1',
      roomNumber: '101',
      floor: 1,
      zone: 'A',
      suitableTypes: [
        { id: 'type-1', name: 'Doble', basePriceBs: 200, maxOccupancy: 2 },
      ],
    },
  ]),
  createReservation: vi.fn(async () => 'reservation-1'),
}))

vi.mock('../../services/rateDiscountRequestsService', () => ({
  fetchPendingForReservation: vi.fn(async () => null),
}))

async function searchAndSelectRoom() {
  fireEvent.change(screen.getByLabelText('Entrada'), { target: { value: '2026-10-01' } })
  fireEvent.change(screen.getByLabelText('Salida'), { target: { value: '2026-10-03' } })
  fireEvent.click(screen.getByRole('button', { name: 'Buscar' }))
  await screen.findByText(/Hab\. 101/)
  fireEvent.click(screen.getByRole('button', { name: /Hab\. 101/ }))
  await screen.findByText(/3 · Datos de la reserva/)
}

describe('NewReservationForm — modalidad de pago (R9.1, R9.2, decisión #339)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('oculta el selector de modalidad de pago para role=reception', async () => {
    render(<NewReservation role="reception" />)
    await searchAndSelectRoom()
    expect(screen.queryByLabelText(/Modalidad de pago/i)).not.toBeInTheDocument()
  })

  it('muestra el selector de modalidad de pago para role=reception_admin', async () => {
    render(<NewReservation role="reception_admin" />)
    await searchAndSelectRoom()
    expect(screen.getByLabelText(/Modalidad de pago/i)).toBeInTheDocument()
  })

  it('muestra el selector de modalidad de pago para role=root', async () => {
    render(<NewReservation role="root" />)
    await searchAndSelectRoom()
    expect(screen.getByLabelText(/Modalidad de pago/i)).toBeInTheDocument()
  })

  it('en modo person bloquea el envío si "Personas" queda en blanco', async () => {
    render(<NewReservation role="root" />)
    await searchAndSelectRoom()
    fireEvent.change(screen.getByLabelText(/Modalidad de pago/i), {
      target: { value: 'client' },
    })
    fireEvent.change(screen.getByLabelText(/Modalidad de tarifa/i), {
      target: { value: 'person' },
    })
    // El campo Personas debe quedar en blanco por default en modo person
    // (no precargado con la capacidad de la habitación).
    const personasInput = screen.getByLabelText('Personas (contrato)') as HTMLInputElement
    expect(personasInput.value).toBe('')

    fireEvent.change(screen.getByPlaceholderText('Nombre'), { target: { value: 'Juan' } })
    fireEvent.change(screen.getByPlaceholderText('Apellido'), { target: { value: 'Pérez' } })
    fireEvent.change(screen.getByPlaceholderText('Celular'), { target: { value: '70000000' } })

    fireEvent.click(screen.getByRole('button', { name: /Crear reserva/ }))

    await waitFor(() => {
      expect(screen.getByText(/Personas.*obligatorio|obligatorio.*Personas/i)).toBeInTheDocument()
    })

    const { createReservation } = await import('../../services/reservations')
    expect(createReservation).not.toHaveBeenCalled()
  })

  it('actualiza el total de contrato en vivo al cambiar personas en modo person', async () => {
    render(<NewReservation role="root" />)
    await searchAndSelectRoom()
    fireEvent.change(screen.getByLabelText(/Modalidad de pago/i), {
      target: { value: 'client' },
    })
    fireEvent.change(screen.getByLabelText(/Modalidad de tarifa/i), {
      target: { value: 'person' },
    })
    fireEvent.change(screen.getByLabelText('Precio pactado por persona/noche (Bs)'), {
      target: { value: '100' },
    })
    fireEvent.change(screen.getByLabelText('Personas (contrato)'), {
      target: { value: '2' },
    })
    // 2 noches (2026-10-01 -> 2026-10-03) × 2 personas × 100 Bs = 400
    await screen.findByText(/400/)
  })
})
