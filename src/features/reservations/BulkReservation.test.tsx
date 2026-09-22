import '@testing-library/jest-dom/vitest'
import { describe, expect, it, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { BulkReservation } from './BulkReservation'

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
})
