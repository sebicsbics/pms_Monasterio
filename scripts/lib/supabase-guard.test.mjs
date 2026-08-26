import { describe, expect, it } from 'vitest'
import { parseLinkedProject, formatDriftResult } from './supabase-guard.mjs'

describe('parseLinkedProject', () => {
  it('returns null when not linked (no ref file, no json)', () => {
    expect(parseLinkedProject(null, null)).toBeNull()
  })

  it('returns null when ref file is empty', () => {
    expect(parseLinkedProject('', null)).toBeNull()
  })

  it('returns null when ref file is whitespace-only', () => {
    expect(parseLinkedProject('   \n', null)).toBeNull()
  })

  it('returns the trimmed ref with no name when only the ref file exists', () => {
    expect(parseLinkedProject('abcdefghijklmnopqrst', null)).toEqual({
      ref: 'abcdefghijklmnopqrst',
      name: null,
    })
  })

  it('returns ref and name when linked-project.json has all keys', () => {
    const json = JSON.stringify({
      name: 'Proyecto de ejemplo',
      organization_id: 'org1',
      organization_slug: 'org-slug',
      ref: 'abcdefghijklmnopqrst',
    })
    expect(parseLinkedProject('abcdefghijklmnopqrst', json)).toEqual({
      ref: 'abcdefghijklmnopqrst',
      name: 'Proyecto de ejemplo',
    })
  })

  it('falls back to ref-only when linked-project.json is malformed', () => {
    expect(parseLinkedProject('abcdefghijklmnopqrst', '{not valid json')).toEqual({
      ref: 'abcdefghijklmnopqrst',
      name: null,
    })
  })

  it('falls back to ref-only when linked-project.json is missing the name key', () => {
    expect(
      parseLinkedProject('abcdefghijklmnopqrst', JSON.stringify({ organization_id: 'org1' })),
    ).toEqual({ ref: 'abcdefghijklmnopqrst', name: null })
  })

  it('trims a trailing newline on the ref file defensively', () => {
    expect(parseLinkedProject('abcdefghijklmnopqrst\n', null)).toEqual({
      ref: 'abcdefghijklmnopqrst',
      name: null,
    })
  })
})

describe('formatDriftResult', () => {
  it('reports clean when the diff output is empty', () => {
    expect(formatDriftResult('')).toEqual({
      drift: false,
      message: 'No schema drift detected.',
      exitCode: 0,
    })
  })

  it('reports clean when the diff output is whitespace-only', () => {
    expect(formatDriftResult('   \n\t ')).toEqual({
      drift: false,
      message: 'No schema drift detected.',
      exitCode: 0,
    })
  })

  it('reports drift when the diff output is non-empty', () => {
    expect(formatDriftResult('alter table foo add column bar text;')).toEqual({
      drift: true,
      message: 'Schema drift detected — see diff above.',
      exitCode: 2,
    })
  })
})
