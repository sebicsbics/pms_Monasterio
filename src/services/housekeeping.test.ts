import { describe, expect, it, vi } from 'vitest'

const selectMock = vi.fn()
const orderMock = vi.fn()
const eqMock = vi.fn()
const gteMock = vi.fn()
const lteMock = vi.fn()
const rpcMock = vi.fn(
  async (..._args: unknown[]) =>
    ({ error: null }) as { data?: unknown; error: { message: string } | null },
)
const updateMock = vi.fn()

vi.mock('./supabase', () => ({
  supabase: {
    from: (..._args: unknown[]) => ({
      select: (...selectArgs: unknown[]) => selectMock(...selectArgs),
      update: (...updateArgs: unknown[]) => updateMock(...updateArgs),
    }),
    rpc: (...args: unknown[]) => rpcMock(...args),
  },
}))

import {
  fetchAssignments,
  fetchAssignmentHistory,
  generateAssignments,
  updateAssignmentStatus,
  assignStaffName,
  addAssignmentNote,
  fetchAssignmentEvents,
} from './housekeeping'

describe('fetchAssignments', () => {
  it('maps snake_case rows (with nested room) into camelCase domain objects', async () => {
    orderMock.mockResolvedValueOnce({
      data: [
        {
          id: 'a1',
          room_id: 'r1',
          service_date: '2026-07-22',
          assigned_to_name: 'María',
          kind: 'stayover',
          status: 'done',
          notes: null,
          started_at: '2026-07-22T10:00:00.000Z',
          completed_at: '2026-07-22T10:25:00.000Z',
          created_at: '2026-07-22T09:00:00.000Z',
          rooms: { room_number: '101' },
        },
      ],
      error: null,
    })
    eqMock.mockReturnValueOnce({ order: orderMock })
    selectMock.mockReturnValueOnce({ eq: eqMock })

    const result = await fetchAssignments('2026-07-22')

    expect(result).toEqual([
      {
        id: 'a1',
        roomId: 'r1',
        roomNumber: '101',
        serviceDate: '2026-07-22',
        assignedToName: 'María',
        kind: 'stayover',
        status: 'done',
        notes: null,
        startedAt: '2026-07-22T10:00:00.000Z',
        completedAt: '2026-07-22T10:25:00.000Z',
        createdAt: '2026-07-22T09:00:00.000Z',
      },
    ])
  })

  it('surfaces the query error message unchanged', async () => {
    orderMock.mockResolvedValueOnce({ data: null, error: { message: 'boom' } })
    eqMock.mockReturnValueOnce({ order: orderMock })
    selectMock.mockReturnValueOnce({ eq: eqMock })

    await expect(fetchAssignments('2026-07-22')).rejects.toThrow('boom')
  })
})

describe('fetchAssignmentHistory', () => {
  it('filters by service_date range (no room) and maps rows the same way as fetchAssignments', async () => {
    orderMock.mockResolvedValueOnce({
      data: [
        {
          id: 'a1',
          room_id: 'r1',
          service_date: '2026-07-10',
          assigned_to_name: 'María',
          kind: 'turnover',
          status: 'done',
          notes: null,
          started_at: '2026-07-10T10:00:00.000Z',
          completed_at: '2026-07-10T10:25:00.000Z',
          created_at: '2026-07-10T09:00:00.000Z',
          rooms: { room_number: '202' },
        },
      ],
      error: null,
    })
    lteMock.mockReturnValueOnce({ eq: eqMock, order: orderMock })
    gteMock.mockReturnValueOnce({ lte: lteMock })
    selectMock.mockReturnValueOnce({ gte: gteMock })

    const result = await fetchAssignmentHistory({ from: '2026-07-01', to: '2026-07-31' })

    expect(gteMock).toHaveBeenCalledWith('service_date', '2026-07-01')
    expect(lteMock).toHaveBeenCalledWith('service_date', '2026-07-31')
    expect(result).toEqual([
      {
        id: 'a1',
        roomId: 'r1',
        roomNumber: '202',
        serviceDate: '2026-07-10',
        assignedToName: 'María',
        kind: 'turnover',
        status: 'done',
        notes: null,
        startedAt: '2026-07-10T10:00:00.000Z',
        completedAt: '2026-07-10T10:25:00.000Z',
        createdAt: '2026-07-10T09:00:00.000Z',
      },
    ])
  })

  it('adds a room_id filter when roomId is given', async () => {
    orderMock.mockResolvedValueOnce({ data: [], error: null })
    eqMock.mockReturnValueOnce({ order: orderMock })
    lteMock.mockReturnValueOnce({ eq: eqMock, order: orderMock })
    gteMock.mockReturnValueOnce({ lte: lteMock })
    selectMock.mockReturnValueOnce({ gte: gteMock })

    await fetchAssignmentHistory({ roomId: 'r1', from: '2026-07-01', to: '2026-07-31' })

    expect(eqMock).toHaveBeenCalledWith('room_id', 'r1')
  })

  it('surfaces the query error message unchanged', async () => {
    orderMock.mockResolvedValueOnce({ data: null, error: { message: 'boom' } })
    lteMock.mockReturnValueOnce({ eq: eqMock, order: orderMock })
    gteMock.mockReturnValueOnce({ lte: lteMock })
    selectMock.mockReturnValueOnce({ gte: gteMock })

    await expect(fetchAssignmentHistory({ from: '2026-07-01', to: '2026-07-31' })).rejects.toThrow('boom')
  })
})

describe('generateAssignments', () => {
  it('calls the generate_housekeeping_assignments RPC with the service date', async () => {
    rpcMock.mockClear()
    await generateAssignments('2026-07-22')
    expect(rpcMock).toHaveBeenCalledWith('generate_housekeeping_assignments', {
      p_service_date: '2026-07-22',
    })
  })

  it('surfaces the RPC error message unchanged', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({ error: { message: 'No autorizado' } })
    await expect(generateAssignments('2026-07-22')).rejects.toThrow('No autorizado')
  })
})

describe('updateAssignmentStatus', () => {
  it('calls change_housekeeping_assignment_status with the new status and note', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({ error: null })

    await updateAssignmentStatus('a1', 'done', 'Encontramos la ventana rota')

    expect(rpcMock).toHaveBeenCalledWith('change_housekeeping_assignment_status', {
      p_assignment_id: 'a1',
      p_status: 'done',
      p_note: 'Encontramos la ventana rota',
    })
  })

  it('sends null as the note when none is given', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({ error: null })

    await updateAssignmentStatus('a1', 'in_progress')

    expect(rpcMock).toHaveBeenCalledWith('change_housekeeping_assignment_status', {
      p_assignment_id: 'a1',
      p_status: 'in_progress',
      p_note: null,
    })
  })

  it('surfaces the RPC error message unchanged', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({ error: { message: 'No autorizado para cambiar el estado de una limpieza' } })

    await expect(updateAssignmentStatus('a1', 'pending')).rejects.toThrow(
      'No autorizado para cambiar el estado de una limpieza',
    )
  })
})

describe('addAssignmentNote', () => {
  it('calls change_housekeeping_assignment_status with the current status and the note', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({ error: null })

    await addAssignmentNote('a1', 'in_progress', 'Faltó reponer amenities')

    expect(rpcMock).toHaveBeenCalledWith('change_housekeeping_assignment_status', {
      p_assignment_id: 'a1',
      p_status: 'in_progress',
      p_note: 'Faltó reponer amenities',
    })
  })

  it('surfaces the RPC error message unchanged (e.g. blank note)', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({ error: { message: 'La nota no puede estar vacía' } })

    await expect(addAssignmentNote('a1', 'done', '   ')).rejects.toThrow('La nota no puede estar vacía')
  })
})

describe('fetchAssignmentEvents', () => {
  it('maps snake_case rows into camelCase domain events', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({
      data: [
        {
          id: 'e1',
          assignment_id: 'a1',
          from_status: 'pending',
          to_status: 'in_progress',
          note: 'Empezando',
          created_by_name: 'María',
          created_at: '2026-07-22T10:00:00.000Z',
        },
      ],
      error: null,
    })

    const result = await fetchAssignmentEvents(['a1'])

    expect(rpcMock).toHaveBeenCalledWith('list_housekeeping_assignment_events', {
      p_assignment_ids: ['a1'],
    })
    expect(result).toEqual([
      {
        id: 'e1',
        assignmentId: 'a1',
        fromStatus: 'pending',
        toStatus: 'in_progress',
        note: 'Empezando',
        createdByName: 'María',
        createdAt: '2026-07-22T10:00:00.000Z',
      },
    ])
  })

  it('surfaces the RPC error message unchanged', async () => {
    rpcMock.mockClear()
    rpcMock.mockResolvedValueOnce({ data: null, error: { message: 'boom' } })

    await expect(fetchAssignmentEvents(['a1'])).rejects.toThrow('boom')
  })
})

describe('assignStaffName', () => {
  it('updates assigned_to_name (trimmed) for the given assignment id', async () => {
    const eqUpdate = vi.fn().mockResolvedValueOnce({ error: null })
    updateMock.mockReturnValueOnce({ eq: eqUpdate })

    await assignStaffName('a1', '  María  ')

    expect(updateMock).toHaveBeenCalledWith({ assigned_to_name: 'María' })
    expect(eqUpdate).toHaveBeenCalledWith('id', 'a1')
  })

  it('sends null when the name is blank', async () => {
    const eqUpdate = vi.fn().mockResolvedValueOnce({ error: null })
    updateMock.mockReturnValueOnce({ eq: eqUpdate })

    await assignStaffName('a1', '   ')

    expect(updateMock).toHaveBeenCalledWith({ assigned_to_name: null })
  })
})
