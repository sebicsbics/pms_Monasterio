import { describe, expect, it } from 'vitest'
import {
  ASSIGNMENT_STATUS_LABEL,
  ASSIGNMENT_KIND_LABEL,
  formatDuration,
  type AssignmentStatus,
  type AssignmentKind,
} from './assignment'

describe('ASSIGNMENT_STATUS_LABEL', () => {
  const statuses: AssignmentStatus[] = ['pending', 'in_progress', 'done']

  it('has a label for every AssignmentStatus value', () => {
    for (const s of statuses) {
      expect(ASSIGNMENT_STATUS_LABEL[s]).toBeTruthy()
    }
  })

  it('labels pending, in_progress and done in Spanish', () => {
    expect(ASSIGNMENT_STATUS_LABEL.pending).toBe('Pendiente')
    expect(ASSIGNMENT_STATUS_LABEL.in_progress).toBe('En progreso')
    expect(ASSIGNMENT_STATUS_LABEL.done).toBe('Hecha')
  })
})

describe('ASSIGNMENT_KIND_LABEL', () => {
  const kinds: AssignmentKind[] = ['stayover', 'turnover']

  it('has a label for every AssignmentKind value', () => {
    for (const k of kinds) {
      expect(ASSIGNMENT_KIND_LABEL[k]).toBeTruthy()
    }
  })

  it('labels stayover as Limpieza and turnover as Habilitar', () => {
    expect(ASSIGNMENT_KIND_LABEL.stayover).toBe('Limpieza')
    expect(ASSIGNMENT_KIND_LABEL.turnover).toBe('Habilitar')
  })
})

describe('formatDuration', () => {
  it('returns null if either timestamp is missing', () => {
    expect(formatDuration(null, '2026-07-29T10:00:00Z')).toBeNull()
    expect(formatDuration('2026-07-29T10:00:00Z', null)).toBeNull()
  })

  it('formats minutes under an hour', () => {
    expect(formatDuration('2026-07-29T10:00:00Z', '2026-07-29T10:25:00Z')).toBe('25 min')
  })

  it('formats hours and minutes', () => {
    expect(formatDuration('2026-07-29T10:00:00Z', '2026-07-29T11:05:00Z')).toBe('1 h 5 min')
  })

  it('formats exact hours without minutes', () => {
    expect(formatDuration('2026-07-29T10:00:00Z', '2026-07-29T12:00:00Z')).toBe('2 h')
  })

  it('returns null for an inverted range', () => {
    expect(formatDuration('2026-07-29T11:00:00Z', '2026-07-29T10:00:00Z')).toBeNull()
  })
})
