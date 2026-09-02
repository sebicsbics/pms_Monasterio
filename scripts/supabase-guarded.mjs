#!/usr/bin/env node
/**
 * Confirmation gate for Supabase CLI commands that touch a linked (remote)
 * project — `supabase link` and `supabase db diff --linked`.
 *
 * Link state lives in supabase/.temp/project-ref, is invisible in code
 * review, and persists across terminal sessions. This wrapper makes any
 * `--linked` invocation an explicit, confirmed action instead of a silent
 * default.
 *
 * Usage:
 *   node scripts/supabase-guarded.mjs db diff --linked
 *   node scripts/supabase-guarded.mjs link --project-ref <ref>
 *   node scripts/supabase-guarded.mjs migrations:check
 */
import { execSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { createInterface } from 'node:readline/promises'
import {
  parseLinkedProject,
  formatDriftResult,
  parseMigrationList,
  formatMigrationCheck,
} from './lib/supabase-guard.mjs'

const REF_FILE = 'supabase/.temp/project-ref'
const LINKED_PROJECT_JSON_FILE = 'supabase/.temp/linked-project.json'

function readOrNull(path) {
  try {
    return readFileSync(path, 'utf8')
  } catch {
    return null
  }
}

function getLinkedProject() {
  const refContent = readOrNull(REF_FILE)
  const jsonContent = readOrNull(LINKED_PROJECT_JSON_FILE)
  return parseLinkedProject(refContent, jsonContent)
}

async function confirm(promptText) {
  if (!process.stdin.isTTY) {
    console.error('No hay una terminal interactiva disponible — abortando por seguridad.')
    process.exit(1)
  }

  const rl = createInterface({ input: process.stdin, output: process.stdout })
  const answer = await rl.question(promptText)
  rl.close()

  return ['y', 'yes'].includes(answer.trim().toLowerCase())
}

async function runDriftCheck(linked) {
  const label = linked.name ?? linked.ref
  const proceed = await confirm(
    `Estás por ejecutar "supabase db diff --linked" contra el proyecto: ${label}. ¿Continuar? [y/N] `,
  )

  if (!proceed) {
    console.log('Abortado.')
    process.exit(0)
  }

  let diffOutput
  try {
    diffOutput = execSync('npx supabase db diff --linked', { encoding: 'utf8' })
  } catch (error) {
    console.error(error.stdout ?? '')
    console.error(error.stderr ?? String(error))
    process.exit(1)
  }

  console.log(diffOutput)
  const result = formatDriftResult(diffOutput)
  console.log(result.message)
  process.exit(result.exitCode)
}

// Sólo LEE el ledger remoto, así que no pide confirmación: la barrera de
// este wrapper existe para lo que escribe. Un chequeo que molesta se saltea,
// y uno que se saltea no protege nada.
async function runMigrationsCheck(linked) {
  const label = linked.name ?? linked.ref
  console.log(`Comparando migraciones locales contra: ${label}\n`)

  let listOutput
  try {
    listOutput = execSync('npx supabase migration list --linked', { encoding: 'utf8' })
  } catch (error) {
    console.error(error.stdout ?? '')
    console.error(error.stderr ?? String(error))
    process.exit(1)
  }

  const result = formatMigrationCheck(parseMigrationList(listOutput))
  console.log(result.message)
  process.exit(result.exitCode)
}

async function runGenericLinkedCommand(args) {
  const linked = getLinkedProject()
  const label = linked ? (linked.name ?? linked.ref) : 'ningún proyecto (no estás linkeado)'
  const proceed = await confirm(
    `Estás por ejecutar "supabase ${args.join(' ')}" contra: ${label}. ¿Continuar? [y/N] `,
  )

  if (!proceed) {
    console.log('Abortado.')
    process.exit(0)
  }

  try {
    execSync(`npx supabase ${args.join(' ')}`, { stdio: 'inherit' })
  } catch (error) {
    process.exit(typeof error.status === 'number' ? error.status : 1)
  }
}

async function main() {
  const args = process.argv.slice(2)
  const joined = args.join(' ')
  const isDriftCheck = joined === 'db diff --linked'

  if (joined === 'migrations:check') {
    const linked = getLinkedProject()
    if (!linked) {
      console.log('No estás linkeado a ningún proyecto — no hay nada contra qué comparar.')
      process.exit(1)
    }
    await runMigrationsCheck(linked)
    return
  }

  if (isDriftCheck) {
    const linked = getLinkedProject()
    if (!linked) {
      console.log('No estás linkeado a ningún proyecto — no hay nada contra qué comparar.')
      process.exit(1)
    }
    await runDriftCheck(linked)
    return
  }

  await runGenericLinkedCommand(args)
}

main()
