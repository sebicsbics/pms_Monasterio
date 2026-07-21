import { describe, expect, it } from 'vitest'
import {
  ASSIGNMENT_STATUS_LABEL,
  ASSIGNMENT_KIND_LABEL,
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

  it('labels stayover and turnover in Spanish', () => {
    expect(ASSIGNMENT_KIND_LABEL.stayover).toBe('Repaso (huésped en curso)')
    expect(ASSIGNMENT_KIND_LABEL.turnover).toBe('Salida (rotación)')
  })
})
