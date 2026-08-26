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
