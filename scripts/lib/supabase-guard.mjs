/**
 * Pure helpers for the `--linked` command guard (scripts/supabase-guarded.mjs).
 * No fs/execSync here on purpose — everything below takes plain string|null
 * inputs so it can be unit tested without mocking I/O.
 */

/**
 * @param {string | null} refFileContent - raw contents of supabase/.temp/project-ref, or null if absent
 * @param {string | null} linkedProjectJsonContent - raw contents of supabase/.temp/linked-project.json, or null if absent
 * @returns {{ ref: string, name: string | null } | null}
 */
export function parseLinkedProject(refFileContent, linkedProjectJsonContent) {
  const ref = typeof refFileContent === 'string' ? refFileContent.trim() : ''
  if (!ref) return null

  let name = null
  if (linkedProjectJsonContent) {
    try {
      const parsed = JSON.parse(linkedProjectJsonContent)
      if (parsed && typeof parsed.name === 'string') {
        name = parsed.name
      }
    } catch {
      // Malformed/truncated JSON must not throw — fall back to ref-only.
    }
  }

  return { ref, name }
}

/**
 * @param {string} diffOutput - raw stdout from `supabase db diff --linked`
 * @returns {{ drift: boolean, message: string, exitCode: 0 | 2 }}
 */
export function formatDriftResult(diffOutput) {
  const isClean = !diffOutput || diffOutput.trim() === ''
  if (isClean) {
    return { drift: false, message: 'No schema drift detected.', exitCode: 0 }
  }
  return { drift: true, message: 'Schema drift detected — see diff above.', exitCode: 2 }
}

/**
 * Migraciones locales que nunca llegaron a la nube.
 *
 * El caso que motivó esto: `agency_field` viajó a main dentro de un merge
 * de 19 commits y su migración quedó sin aplicar. El frontend salió llamando
 * a walk_in_check_in_with_guests con 20 argumentos contra una base que tenía
 * la de 18, y recepción se comió el error en pantalla con un huésped
 * adelante. El código y el esquema se publican juntos o no se publican.
 *
 * @param {string} listOutput - stdout de `supabase migration list --linked`
 * @returns {{ pending: string[], orphans: string[], paired: number }}
 */
export function parseMigrationList(listOutput) {
  const empty = { pending: [], orphans: [], paired: 0 }
  if (typeof listOutput !== 'string') return empty

  // El CLI imprime "Connecting to remote database..." antes del JSON, así
  // que se busca la línea que lo contiene en vez de parsear todo el stdout.
  const line = listOutput
    .split('\n')
    .reverse()
    .find((l) => l.trim().startsWith('{'))
  if (!line) return empty

  let rows
  try {
    rows = JSON.parse(line).migrations
  } catch {
    return empty
  }
  if (!Array.isArray(rows)) return empty

  const has = (v) => typeof v === 'string' && v.trim() !== ''
  return {
    pending: rows.filter((r) => has(r.local) && !has(r.remote)).map((r) => r.local),
    orphans: rows.filter((r) => !has(r.local) && has(r.remote)).map((r) => r.remote),
    paired: rows.filter((r) => has(r.local) && has(r.remote)).length,
  }
}

/**
 * @param {{ pending: string[], orphans: string[], paired: number }} result
 * @returns {{ message: string, exitCode: 0 | 1 }}
 */
export function formatMigrationCheck(result) {
  const lines = []

  // Los huérfanos avisan pero NO bloquean. Aplicar por el MCP registra un
  // timestamp propio en vez del del archivo, así que un huérfano suele ser
  // la misma migración que figura como pendiente, con otro número. Bloquear
  // por eso sería la falsa alarma que entrena a ignorar al guardián.
  if (result.orphans.length > 0) {
    lines.push(
      `Aviso: ${result.orphans.length} versión(es) en la nube sin archivo local:`,
      ...result.orphans.map((v) => `  ${v}`),
      'Suele ser una migración aplicada por el MCP, que registra su propio',
      'timestamp. Revisá si se empareja con alguna pendiente de abajo y, si',
      'es así, alineá el ledger con `supabase migration repair`.',
      '',
    )
  }

  if (result.pending.length > 0) {
    lines.push(
      `FALTAN ${result.pending.length} migración(es) en la nube:`,
      ...result.pending.map((v) => `  ${v}`),
      '',
      'No publiques el código sin ellas: si alguna cambia la firma de una RPC,',
      'el frontend va a llamar a una función que no existe y recepción se come',
      'el error en pantalla.',
    )
    return { message: lines.join('\n'), exitCode: 1 }
  }

  lines.push(`Esquema alineado: ${result.paired} migración(es) aplicadas en la nube.`)
  return { message: lines.join('\n'), exitCode: 0 }
}
