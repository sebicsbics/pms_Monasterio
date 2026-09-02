import { describe, expect, it } from 'vitest'
import {
  parseLinkedProject,
  formatDriftResult,
  parseMigrationList,
  formatMigrationCheck,
} from './supabase-guard.mjs'

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

describe('parseMigrationList', () => {
  const json = (rows) => JSON.stringify({ migrations: rows, message: 'Migrations listed' })

  it('reports nothing when every local migration has its remote counterpart', () => {
    const r = parseMigrationList(
      json([
        { local: '20260702220000', remote: '20260702220000' },
        { local: '20260703000000', remote: '20260703000000' },
      ]),
    )
    expect(r).toEqual({ pending: [], orphans: [], paired: 2 })
  })

  it('reports a local migration that never reached the remote', () => {
    // El caso real: agency_field viajó a main y su migración quedó sin
    // aplicar, así que el frontend llamaba una RPC que no existía.
    const r = parseMigrationList(
      json([
        { local: '20260702220000', remote: '20260702220000' },
        { local: '20260827000000', remote: '' },
      ]),
    )
    expect(r.pending).toEqual(['20260827000000'])
    expect(r.orphans).toEqual([])
  })

  it('reports a remote version with no local file as an orphan', () => {
    const r = parseMigrationList(json([{ local: '', remote: '20260902012657' }]))
    expect(r.orphans).toEqual(['20260902012657'])
    expect(r.pending).toEqual([])
  })

  it('survives a malformed payload instead of crashing the push', () => {
    expect(parseMigrationList('{not json')).toEqual({ pending: [], orphans: [], paired: 0 })
  })

  it('ignores the CLI chatter printed before the JSON line', () => {
    const noisy = `Initialising login role...\nConnecting to remote database...\n${json([
      { local: '20260827000000', remote: '' },
    ])}`
    expect(parseMigrationList(noisy).pending).toEqual(['20260827000000'])
  })
})

describe('formatMigrationCheck', () => {
  it('passes when nothing is pending', () => {
    const r = formatMigrationCheck({ pending: [], orphans: [], paired: 94 })
    expect(r.exitCode).toBe(0)
    expect(r.message).toContain('94')
  })

  it('fails and names every pending migration', () => {
    const r = formatMigrationCheck({ pending: ['20260827000000'], orphans: [], paired: 93 })
    expect(r.exitCode).toBe(1)
    expect(r.message).toContain('20260827000000')
  })

  // Los huérfanos no bloquean: aplicar por el MCP registra un timestamp
  // nuevo, así que un par desparejado suele ser la MISMA migración con dos
  // números. Bloquear por eso sería la falsa alarma que vuelve inútil al
  // guardián — pero callarla dejaría el ledger podrido sin que nadie mire.
  it('warns about orphans without blocking the push', () => {
    const r = formatMigrationCheck({ pending: [], orphans: ['20260902012657'], paired: 93 })
    expect(r.exitCode).toBe(0)
    expect(r.message).toContain('20260902012657')
  })

  it('blocks when there are pending migrations even if orphans exist too', () => {
    const r = formatMigrationCheck({
      pending: ['20260827000000'],
      orphans: ['20260902012657'],
      paired: 92,
    })
    expect(r.exitCode).toBe(1)
  })
})
