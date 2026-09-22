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

vi.mock('../../services/receivables', () => ({
  listReceivableAccounts: vi.fn(async () => [
    { id: 'acc-1', name: 'hotel abc.', kind: 'empresa', contact: null, notes: null, isActive: true },
  ]),
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

  // DEFECT 1 (fix/bulk-headcount-room-type-and-errors): "Personas" (paso
  // 2) y "Personas (contrato)" (paso 3, modo person) son AHORA la misma
  // fuente de verdad (guestsByRoom) — editar una actualiza la otra, y el
  // valor que se envía a createBulkReservation es siempre ese mismo,
  // nunca uno paralelo que pueda desincronizarse.
  it('en modo person, "Personas" del paso 2 y "Personas (contrato)" del paso 3 son el mismo valor', async () => {
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
    await screen.findByLabelText('Cuenta por cobrar')
    fireEvent.change(screen.getByLabelText('Cuenta por cobrar'), {
      target: { value: 'acc-1' },
    })

    // Al seleccionar la habitación (capacidad 2), "Personas" ya viene
    // precargada — nunca queda en blanco esperando una segunda entrada
    // paralela.
    const personasContrato = screen.getAllByLabelText('Personas (contrato)') as HTMLInputElement[]
    expect(personasContrato[0].value).toBe('2')

    // Editar desde el paso 3 (contrato) actualiza el mismo estado que
    // maneja el paso 2 (Personas / sobre-ocupación).
    fireEvent.change(personasContrato[0], { target: { value: '3' } })

    fireEvent.change(screen.getByPlaceholderText('Nombre'), { target: { value: 'Juan' } })
    fireEvent.change(screen.getByPlaceholderText('Apellido'), { target: { value: 'Pérez' } })
    fireEvent.change(screen.getByPlaceholderText('Celular'), { target: { value: '70000000' } })
    // La habitación 101 admite 2: 3 personas dispara el aviso de
    // sobre-ocupación y exige motivo — la MISMA cantidad que se editó
    // desde "Personas (contrato)".
    await screen.findByText(/Supera la capacidad/i)
    const motivos = screen.getAllByPlaceholderText('Motivo (ej. cuna adicional)')
    fireEvent.change(motivos[0], { target: { value: 'Cuna adicional' } })

    fireEvent.click(screen.getByRole('button', { name: /Crear 2 reserva/ }))

    await waitFor(() => {
      expect(createBulkReservation).toHaveBeenCalledWith(
        expect.objectContaining({
          rooms: expect.arrayContaining([
            expect.objectContaining({ roomId: 'room-1', numGuests: 3, occupancyReason: 'Cuna adicional' }),
          ]),
        }),
      )
    })
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

describe('BulkReservation — tipo de habitación según ocupación (DEFECT 2)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  // Habitación 7 real: dos fichas de room_type_options a distinto precio
  // y capacidad sobre la MISMA habitación física (pool "aliased").
  const ALIASED_ROOM = [
    {
      roomId: 'room-7',
      roomNumber: '7',
      floor: 1,
      zone: 'A',
      suitableTypes: [
        { id: 'simple', name: 'Simple Estándar', basePriceBs: 350, maxOccupancy: 1 },
        { id: 'matrimonial', name: 'Matrimonial', basePriceBs: 480, maxOccupancy: 2 },
      ],
    },
  ]

  it('con 2 personas usa Matrimonial (no la ficha más barata) y no pide motivo de excepción', async () => {
    vi.mocked(searchAvailableRooms).mockResolvedValueOnce(ALIASED_ROOM)
    render(<BulkReservation role="reception" />)
    fireEvent.change(screen.getByLabelText('Entrada'), { target: { value: '2026-10-01' } })
    fireEvent.change(screen.getByLabelText('Salida'), { target: { value: '2026-10-03' } })
    fireEvent.click(screen.getByRole('button', { name: 'Buscar' }))
    await screen.findByText(/Hab\. 7/)
    fireEvent.click(screen.getByRole('button', { name: /Hab\. 7/ }))

    // Al seleccionar, se precarga con la capacidad de la ficha más
    // barata (Simple, 1) — todavía no sabemos cuántos van.
    const personas = screen.getByLabelText('Personas') as HTMLInputElement
    fireEvent.change(personas, { target: { value: '2' } })

    // Con 2 personas, Simple (cap. 1) ya NO alcanza: el tipo efectivo
    // pasa a Matrimonial y NO debe pedir motivo de sobre-ocupación.
    await screen.findByText(/Matrimonial · hasta 2 · 480 Bs/)
    expect(screen.queryByText(/Supera la capacidad/i)).not.toBeInTheDocument()

    fireEvent.change(screen.getByPlaceholderText('Nombre'), { target: { value: 'Juan' } })
    fireEvent.change(screen.getByPlaceholderText('Apellido'), { target: { value: 'Pérez' } })
    fireEvent.change(screen.getByPlaceholderText('Celular'), { target: { value: '70000000' } })
    fireEvent.click(screen.getByRole('button', { name: /Crear 1 reserva/ }))

    await waitFor(() => {
      expect(createBulkReservation).toHaveBeenCalledWith(
        expect.objectContaining({
          rooms: [
            expect.objectContaining({ roomId: 'room-7', roomTypeId: 'matrimonial', numGuests: 2 }),
          ],
        }),
      )
    })
  })

  it('con 1 persona ofrece un selector de tipo/tarifa y respeta la elección manual', async () => {
    vi.mocked(searchAvailableRooms).mockResolvedValueOnce(ALIASED_ROOM)
    render(<BulkReservation role="reception" />)
    fireEvent.change(screen.getByLabelText('Entrada'), { target: { value: '2026-10-01' } })
    fireEvent.change(screen.getByLabelText('Salida'), { target: { value: '2026-10-03' } })
    fireEvent.click(screen.getByRole('button', { name: 'Buscar' }))
    await screen.findByText(/Hab\. 7/)
    fireEvent.click(screen.getByRole('button', { name: /Hab\. 7/ }))

    fireEvent.change(screen.getByLabelText('Personas'), { target: { value: '1' } })

    // Ambas fichas alcanzan para 1 persona -> selector visible, default
    // al más barato (Simple).
    const selector = await screen.findByLabelText('Tipo/tarifa')
    expect((selector as HTMLSelectElement).value).toBe('simple')

    fireEvent.change(selector, { target: { value: 'matrimonial' } })

    fireEvent.change(screen.getByPlaceholderText('Nombre'), { target: { value: 'Juan' } })
    fireEvent.change(screen.getByPlaceholderText('Apellido'), { target: { value: 'Pérez' } })
    fireEvent.change(screen.getByPlaceholderText('Celular'), { target: { value: '70000000' } })
    fireEvent.click(screen.getByRole('button', { name: /Crear 1 reserva/ }))

    await waitFor(() => {
      expect(createBulkReservation).toHaveBeenCalledWith(
        expect.objectContaining({
          rooms: [
            expect.objectContaining({ roomId: 'room-7', roomTypeId: 'matrimonial', numGuests: 1 }),
          ],
        }),
      )
    })
  })
})

describe('BulkReservation — errores reales por habitación (DEFECT 3a)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('muestra el motivo real devuelto por la RPC en vez de una excusa inventada', async () => {
    vi.mocked(createBulkReservation).mockResolvedValueOnce({
      created: ['res-1'],
      failed: [{ roomId: 'room-2', error: 'La habitación 102 ya no está disponible para esas fechas' }],
    })
    render(<BulkReservation role="reception" />)
    await searchTwoRoomsAndSelectBoth()
    fireEvent.change(screen.getByPlaceholderText('Nombre'), { target: { value: 'Juan' } })
    fireEvent.change(screen.getByPlaceholderText('Apellido'), { target: { value: 'Pérez' } })
    fireEvent.change(screen.getByPlaceholderText('Celular'), { target: { value: '70000000' } })
    fireEvent.click(screen.getByRole('button', { name: /Crear 2 reserva/ }))

    await screen.findByText(/La habitación 102 ya no está disponible para esas fechas/)
    expect(screen.queryByText(/probablemente se ocuparon/i)).not.toBeInTheDocument()
  })
})

describe('BulkReservation — enlace a cuenta por cobrar (R10.1–R10.5)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('en Crear cuenta nueva muestra advertencia no bloqueante si el nombre se parece a uno existente', async () => {
    render(<BulkReservation role="root" />)
    await searchTwoRoomsAndSelectBoth()
    fireEvent.change(screen.getByLabelText(/Modalidad de pago/i), {
      target: { value: 'client' },
    })
    await screen.findByText(/Enlazar a cuenta/i)
    fireEvent.click(screen.getByRole('radio', { name: 'Crear' }))
    fireEvent.change(screen.getByLabelText('Nombre de la cuenta'), {
      target: { value: 'Hotel ABC' },
    })
    await screen.findByText(/parecido/i)
  })

  it('un envío client con cuenta Existente elegida llega a createBulkReservation con receivableAccountId', async () => {
    render(<BulkReservation role="root" />)
    await searchTwoRoomsAndSelectBoth()
    fireEvent.change(screen.getByLabelText(/Modalidad de pago/i), {
      target: { value: 'client' },
    })
    await screen.findByLabelText('Cuenta por cobrar')
    fireEvent.change(screen.getByLabelText('Cuenta por cobrar'), {
      target: { value: 'acc-1' },
    })

    fireEvent.change(screen.getByPlaceholderText('Nombre'), { target: { value: 'Juan' } })
    fireEvent.change(screen.getByPlaceholderText('Apellido'), { target: { value: 'Pérez' } })
    fireEvent.change(screen.getByPlaceholderText('Celular'), { target: { value: '70000000' } })

    fireEvent.click(screen.getByRole('button', { name: /Crear 2 reserva/ }))

    await waitFor(() => {
      expect(createBulkReservation).toHaveBeenCalledWith(
        expect.objectContaining({ receivableAccountId: 'acc-1' }),
      )
    })
  })
})
