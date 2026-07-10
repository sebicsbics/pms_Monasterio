import { supabase } from './supabase'
import type { UserRole } from '../domain/auth/profile'

export interface LoginEvent {
  id: string
  eventType: 'login' | 'logout'
  occurredAt: string
  userName: string
  username: string
  role: UserRole | null
}

interface Row {
  id: string
  event_type: 'login' | 'logout'
  occurred_at: string
  profiles: { full_name: string | null; username: string | null; role: string | null } | null
}

// Solo root/accountant obtienen filas (la RLS lo garantiza).
export async function fetchLoginEvents(limit = 200): Promise<LoginEvent[]> {
  const { data, error } = await supabase
    .from('login_events')
    .select('id, event_type, occurred_at, profiles ( full_name, username, role )')
    .order('occurred_at', { ascending: false })
    .limit(limit)
  if (error) throw new Error(error.message)
  return (data as unknown as Row[]).map((r) => ({
    id: r.id,
    eventType: r.event_type,
    occurredAt: r.occurred_at,
    userName: r.profiles?.full_name ?? '—',
    username: r.profiles?.username ?? '',
    role: (r.profiles?.role as UserRole | null) ?? null,
  }))
}

// ---------- Fichaje (time_entries) ----------

export interface TimeEntry {
  id: string
  userId: string
  userName: string
  username: string
  role: UserRole | null
  clockIn: string
  clockOut: string | null
}

interface TimeRow {
  id: string
  user_id: string
  clock_in: string
  clock_out: string | null
  profiles: { full_name: string | null; username: string | null; role: string | null } | null
}

const mapTime = (r: TimeRow): TimeEntry => ({
  id: r.id,
  userId: r.user_id,
  userName: r.profiles?.full_name ?? '—',
  username: r.profiles?.username ?? '',
  role: (r.profiles?.role as UserRole | null) ?? null,
  clockIn: r.clock_in,
  clockOut: r.clock_out,
})

const TIME_SELECT =
  'id, user_id, clock_in, clock_out, profiles ( full_name, username, role )'

export async function clockIn(): Promise<void> {
  const { error } = await supabase.rpc('clock_in')
  if (error) throw new Error(error.message)
}

export async function clockOut(): Promise<void> {
  const { error } = await supabase.rpc('clock_out')
  if (error) throw new Error(error.message)
}

// La sesión abierta del usuario actual (o null si está fuera).
export async function fetchMyOpenEntry(userId: string): Promise<TimeEntry | null> {
  const { data, error } = await supabase
    .from('time_entries')
    .select(TIME_SELECT)
    .eq('user_id', userId)
    .is('clock_out', null)
    .maybeSingle()
  if (error) throw new Error(error.message)
  return data ? mapTime(data as unknown as TimeRow) : null
}

// Sesiones del usuario actual desde una fecha ISO (YYYY-MM-DD).
export async function fetchMyEntriesSince(
  userId: string,
  sinceIso: string,
): Promise<TimeEntry[]> {
  const { data, error } = await supabase
    .from('time_entries')
    .select(TIME_SELECT)
    .eq('user_id', userId)
    .gte('clock_in', sinceIso)
    .order('clock_in', { ascending: false })
  if (error) throw new Error(error.message)
  return (data as unknown as TimeRow[]).map(mapTime)
}

// Todas las sesiones (root/accountant ven todo; otros solo lo propio por RLS).
export async function fetchTimeEntries(limit = 300): Promise<TimeEntry[]> {
  const { data, error } = await supabase
    .from('time_entries')
    .select(TIME_SELECT)
    .order('clock_in', { ascending: false })
    .limit(limit)
  if (error) throw new Error(error.message)
  return (data as unknown as TimeRow[]).map(mapTime)
}
