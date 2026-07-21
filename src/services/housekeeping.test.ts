import { describe, expect, it, vi } from 'vitest'

const selectMock = vi.fn()
const orderMock = vi.fn()
const eqMock = vi.fn()
const rpcMock = vi.fn(async (..._args: unknown[]) => ({ error: null as { message: string } | null }))
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

import { fetchAssignments, generateAssignments, updateAssignmentStatus, assignStaff } from './housekeeping'

describe('fetchAssignments', () => {
  it('maps snake_case rows (with nested room) into camelCase domain objects', async () => {
    orderMock.mockResolvedValueOnce({
      data: [
        {
          id: 'a1',
          room_id: 'r1',
          service_date: '2026-07-22',
          assigned_to: 'p1',
          kind: 'stayover',
          status: 'pending',
          notes: null,
          completed_at: null,
          created_at: '2026-07-22T10:00:00.000Z',
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
        assignedTo: 'p1',
        kind: 'stayover',
        status: 'pending',
        notes: null,
        completedAt: null,
        createdAt: '2026-07-22T10:00:00.000Z',
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
  it('sets completed_at when status is done', async () => {
    const eqUpdate = vi.fn().mockResolvedValueOnce({ error: null })
    updateMock.mockReturnValueOnce({ eq: eqUpdate })

    await updateAssignmentStatus('a1', 'done')

    expect(updateMock).toHaveBeenCalledWith(
      expect.objectContaining({ status: 'done', completed_at: expect.any(String) }),
    )
    expect(eqUpdate).toHaveBeenCalledWith('id', 'a1')
  })

  it('sets completed_at to null when status is not done', async () => {
    const eqUpdate = vi.fn().mockResolvedValueOnce({ error: null })
    updateMock.mockReturnValueOnce({ eq: eqUpdate })

    await updateAssignmentStatus('a1', 'in_progress')

    expect(updateMock).toHaveBeenCalledWith({ status: 'in_progress', completed_at: null })
  })
})

describe('assignStaff', () => {
  it('updates assigned_to for the given assignment id', async () => {
    const eqUpdate = vi.fn().mockResolvedValueOnce({ error: null })
    updateMock.mockReturnValueOnce({ eq: eqUpdate })

    await assignStaff('a1', 'p1')

    expect(updateMock).toHaveBeenCalledWith({ assigned_to: 'p1' })
    expect(eqUpdate).toHaveBeenCalledWith('id', 'a1')
  })
})
