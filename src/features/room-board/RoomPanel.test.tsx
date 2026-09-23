import '@testing-library/jest-dom/vitest'
import { describe, expect, it, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import { RoomPanel } from './RoomPanel'
import type { Room } from '../../domain/rooms/room'
import type { Folio } from '../../domain/folios/folio'

// fix/institutional-ui-coherence: "Editar tarifa" y "Modificar fechas" no
// deberían ofrecerse en reservas institucionales (payer_mode='client') --
// apply_rate_change y las reglas de estadía ya las rechazan en la base
// (feat/booking-13-rate-lock, feat/booking-13c), así que la UI no debe
// ofrecer un botón que la base va a rebotar con un error.

let folioToReturn: Folio

vi.mock('../../services/folio', () => ({
  fetchFolio: vi.fn(async () => folioToReturn),
  addFolioCharge: vi.fn(async () => undefined),
}))

vi.mock('../../services/stayGuests', () => ({
  fetchStayGuests: vi.fn(async () => []),
  addGuestsToStay: vi.fn(async () => undefined),
}))

vi.mock('../../services/staySegments', () => ({
  fetchStaySegments: vi.fn(async () => []),
  modifyStayDates: vi.fn(async () => undefined),
  changeRoom: vi.fn(async () => undefined),
}))

vi.mock('../../services/payments', () => ({
  fetchPaymentMethods: vi.fn(async () => []),
}))

vi.mock('../../services/receivables', () => ({
  listReceivableAccounts: vi.fn(async () => []),
}))

vi.mock('../../services/rooms', () => ({
  fetchRooms: vi.fn(async () => []),
}))

vi.mock('../../services/checkin', () => ({
  walkInWithOptionalPayment: vi.fn(),
  checkOutRoom: vi.fn(),
  setRoomStatus: vi.fn(),
  overrideReservationRate: vi.fn(),
}))

function makeRoom(operationalStatus: Room['operationalStatus'] = 'occupied'): Room {
  return {
    id: 'room-1',
    roomNumber: '101',
    floor: 1,
    zone: null,
    operationalStatus,
    defaultType: { id: 'type-1', name: 'Doble', basePriceBs: 200, maxOccupancy: 2 },
    typeOptions: [{ id: 'type-1', name: 'Doble', basePriceBs: 200, maxOccupancy: 2 }],
  }
}

function makeFolio(payerMode: Folio['payerMode']): Folio {
  return {
    reservationId: 'res-1',
    roomType: 'Doble',
    payerMode,
    roomChargeBs: 200,
    charges: [],
    extrasTotalBs: 0,
    totalBs: 200,
    anticipoTotalBs: 0,
    balanceDueBs: 200,
  }
}

describe('RoomPanel — acciones bloqueadas para reservas institucionales', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('oculta "Editar tarifa" y "Modificar fechas" cuando payerMode=client, y explica por qué', async () => {
    folioToReturn = makeFolio('client')
    render(<RoomPanel room={makeRoom()} role="reception_admin" onClose={vi.fn()} onDone={vi.fn()} />)

    await waitFor(() => expect(screen.getByText('Total')).toBeInTheDocument())

    expect(screen.queryByRole('button', { name: 'Editar tarifa' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Modificar fechas' })).not.toBeInTheDocument()
    expect(screen.getByText(/fijada por el contrato de la reserva institucional/i)).toBeInTheDocument()
    expect(screen.getByText(/fijadas por el contrato de la reserva institucional/i)).toBeInTheDocument()
    // "Cambiar habitación" no está en el alcance de este fix, sigue disponible.
    expect(screen.getByRole('button', { name: 'Cambiar habitación' })).toBeInTheDocument()
  })

  it('muestra "Editar tarifa" y "Modificar fechas" para una reserva each_stay normal', async () => {
    folioToReturn = makeFolio('each_stay')
    render(<RoomPanel room={makeRoom()} role="reception_admin" onClose={vi.fn()} onDone={vi.fn()} />)

    await waitFor(() => expect(screen.getByText('Total')).toBeInTheDocument())

    expect(screen.getByRole('button', { name: 'Editar tarifa' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Modificar fechas' })).toBeInTheDocument()
  })
})

// change: housekeeping-owns-room-release — la limpieza se gestiona desde
// el módulo de Housekeeping, no desde el tablero de habitaciones.
describe('RoomPanel — la limpieza ya no se gestiona desde el tablero', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('no ofrece "Asignar mucama" ni "Marcar como limpia" para una habitación dirty', async () => {
    render(
      <RoomPanel room={makeRoom('dirty')} role="reception_admin" onClose={vi.fn()} onDone={vi.fn()} />,
    )

    await waitFor(() =>
      expect(
        screen.getByText(/se gestiona desde el módulo de\s*Housekeeping/i),
      ).toBeInTheDocument(),
    )

    expect(screen.queryByRole('button', { name: 'Asignar mucama' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Marcar como limpia' })).not.toBeInTheDocument()
  })

  it('sigue ofreciendo "Marcar como disponible" para una habitación en mantenimiento', async () => {
    render(
      <RoomPanel room={makeRoom('maintenance')} role="reception_admin" onClose={vi.fn()} onDone={vi.fn()} />,
    )

    expect(
      await screen.findByRole('button', { name: 'Marcar como disponible' }),
    ).toBeInTheDocument()
  })
})
