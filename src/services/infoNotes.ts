import { supabase } from './supabase'
import type { InfoNote, InfoNoteFilters } from '../domain/info/infoNote'

interface InfoNoteRow {
  id: string
  content: string
  created_at: string
  created_by_name: string | null
  resolved: boolean
  resolved_at: string | null
  resolved_by_name: string | null
  resolved_note: string | null
}

// Lista las notas con búsqueda por texto y rango de fechas (vía RPC, que
// resuelve los nombres server-side).
export async function fetchInfoNotes(filters: InfoNoteFilters = {}): Promise<InfoNote[]> {
  const { data, error } = await supabase.rpc('list_info_notes', {
    p_search: filters.search?.trim() || null,
    p_from: filters.from || null,
    p_to: filters.to || null,
    p_include_resolved: filters.includeResolved ?? true,
  })
  if (error) throw new Error(error.message)
  return (data as InfoNoteRow[]).map((r) => ({
    id: r.id,
    content: r.content,
    createdAt: r.created_at,
    createdByName: r.created_by_name,
    resolved: r.resolved,
    resolvedAt: r.resolved_at,
    resolvedByName: r.resolved_by_name,
    resolvedNote: r.resolved_note,
  }))
}

// created_by lo completa la DB con auth.uid().
export async function createInfoNote(content: string): Promise<void> {
  const { error } = await supabase.from('info_notes').insert({ content: content.trim() })
  if (error) throw new Error(error.message)
}

export async function resolveInfoNote(id: string, note: string | null): Promise<void> {
  const { error } = await supabase.rpc('resolve_info_note', {
    p_id: id,
    p_note: note?.trim() || null,
  })
  if (error) throw new Error(error.message)
}
