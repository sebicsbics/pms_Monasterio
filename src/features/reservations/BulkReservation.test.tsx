import '@testing-library/jest-dom/vitest'
import { describe, expect, it, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { BulkReservation } from './BulkReservation'
import { searchAvailableRooms, createBulkReservation } from '../../services/reservations'

const TWO_ROOMS = [
  {
    roomId: 'room-1',
    roomNumber: '101',
    floor: 1,
    zone: 'A',
    suitableTypes: [
      { id: 'type-1', name: 'Doble', basePriceBs: 200, maxOccupancy: 2 },
    ],
  },
  {
    roomId: 'room-2',
    roomNumber: '102',
    floor: 1,
    zone: 'A',
    suitableTypes: [
      { id: 'type-1', name: 'Doble', basePriceBs: 200, maxOccupancy: 2 },
    ],
  },
]

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
  createBulkReservation: vi.fn(async () => ({ created: [], failed: [] })),
}))

async function search() {
  fireEvent.change(screen.getByLabelText('Entrada'), { target: { value: '2026-10-01' } })
  fireEvent.change(screen.getByLabelText('Salida'), { target: { value: '2026-10-03' } })
  fireEvent.click(screen.getByRole('button', { name: 'Buscar' }))
  await screen.findByText(/Hab\. 101/)
}

async function searchTwoRoomsAndSelectBoth() {
  vi.mocked(searchAvailableRooms).mockResolvedValueOnce(TWO_ROOMS)
  fireEvent.change(screen.getByLabelText('Entrada'), { target: { value: '2026-10-01' } })
  fireEvent.change(screen.getByLabelText('Salida'), { target: { value: '2026-10-03' } })
  fireEvent.click(screen.getByRole('button', { name: 'Buscar' }))
  await screen.findByText(/Hab\. 101/)
  fireEvent.click(screen.getByRole('button', { name: /Hab\. 101/ }))
  fireEvent.click(screen.getByRole('button', { name: /Hab\. 102/ }))
}

describe('BulkReservation — modalidad de pago (R9.1, R9.2, decisión #339)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('oculta el selector de modalidad de pago para role=reception', async () => {
    render(<BulkReservation role="reception" />)
    await search()
    expect(screen.queryByLabelText(/Modalidad de pago/i)).not.toBeInTheDocument()
  })

  it('muestra el selector de modalidad de pago para role=reception_admin', async () => {
    render(<BulkReservation role="reception_admin" />)
    await search()
    expect(screen.getByLabelText(/Modalidad de pago/i)).toBeInTheDocument()
  })

  it('en modo person bloquea el envío si "Personas" queda en blanco en alguna habitación', async () => {
    render(<BulkReservation role="root" />)
    await searchTwoRoomsAndSelectBoth()
    fireEvent.change(screen.getByLabelText(/Modalidad de pago/i), {
      target: { value: 'client' },
    })
    fireEvent.change(screen.getByLabelText(/Modalidad de tarifa/i), {
      target: { value: 'person' },
    })

    const personasInputs = screen.getAllByLabelText('Personas (contrato)') as HTMLInputElement[]
    expect(personasInputs).toHaveLength(2)
    // Se completa sólo la primera habitación; la segunda queda en blanco.
    fireEvent.change(personasInputs[0], { target: { value: '2' } })

    fireEvent.change(screen.getByPlaceholderText('Nombre'), { target: { value: 'Juan' } })
    fireEvent.change(screen.getByPlaceholderText('Apellido'), { target: { value: 'Pérez' } })
    fireEvent.change(screen.getByPlaceholderText('Celular'), { target: { value: '70000000' } })

    fireEvent.click(screen.getByRole('button', { name: /Crear 2 reserva/ }))

    await waitFor(() => {
      expect(screen.getByText(/Personas.*obligatorio|obligatorio.*Personas/i)).toBeInTheDocument()
    })
    expect(createBulkReservation).not.toHaveBeenCalled()
  })

  it('actualiza el total de contrato en vivo agregando el aporte de todas las habitaciones', async () => {
    render(<BulkReservation role="root" />)
    await searchTwoRoomsAndSelectBoth()
    fireEvent.change(screen.getByLabelText(/Modalidad de pago/i), {
      target: { value: 'client' },
    })
    fireEvent.change(screen.getByLabelText(/Modalidad de tarifa/i), {
      target: { value: 'person' },
    })
    fireEvent.change(screen.getByLabelText('Precio pactado por persona/noche (Bs)'), {
      target: { value: '100' },
    })

    const personasInputs = screen.getAllByLabelText('Personas (contrato)') as HTMLInputElement[]
    fireEvent.change(personasInputs[0], { target: { value: '2' } })
    fireEvent.change(personasInputs[1], { target: { value: '1' } })

    // 2 noches × 100 Bs × (2 + 1) personas = 600
    await screen.findByText(/600/)
  })

  it('una habitación marcada como cortesía no aporta al total, las demás sí', async () => {
    render(<BulkReservation role="root" />)
    await searchTwoRoomsAndSelectBoth()
    fireEvent.change(screen.getByLabelText(/Modalidad de pago/i), {
      target: { value: 'client' },
    })
    fireEvent.change(screen.getByLabelText(/Modalidad de tarifa/i), {
      target: { value: 'person' },
    })
    fireEvent.change(screen.getByLabelText('Precio pactado por persona/noche (Bs)'), {
      target: { value: '100' },
    })

    const personasInputs = screen.getAllByLabelText('Personas (contrato)') as HTMLInputElement[]
    fireEvent.change(personasInputs[0], { target: { value: '2' } })
    fireEvent.change(personasInputs[1], { target: { value: '1' } })

    // Total sin cortesía: 2 noches × 100 Bs × (2 + 1) = 600.
    await screen.findByText(/600/)

    const courtesyCheckboxes = screen.getAllByRole('checkbox', { name: /Cortesía/i })
    expect(courtesyCheckboxes).toHaveLength(2)
    // Marcamos la segunda habitación (102) como cortesía.
    fireEvent.click(courtesyCheckboxes[1])
    fireEvent.change(screen.getByPlaceholderText('Motivo de la cortesía (obligatorio)'), {
      target: { value: 'Cortesía de gerencia' },
    })

    // Ahora sólo aporta la habitación 101: 2 noches × 100 Bs × 2 = 400.
    await screen.findByText(/400/)
    expect(screen.queryByText(/600/)).not.toBeInTheDocument()
  })
})
