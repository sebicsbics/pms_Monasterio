import { supabase } from './supabase'
import type { UserRole } from '../domain/auth/profile'

export interface MyProfile {
  fullName: string | null
  username: string | null
  role: UserRole | null
  avatarUrl: string | null
  firstName: string | null
  lastName: string | null
  email: string | null
  birthDate: string | null
  jobTitle: string | null
  hireDate: string | null
  status: string | null
  isEmployee: boolean
}

export async function fetchMyProfile(): Promise<MyProfile> {
  const { data, error } = await supabase.rpc('my_profile')
  if (error) throw new Error(error.message)
  const r = (data?.[0] ?? {}) as Record<string, unknown>
  return {
    fullName: (r.full_name as string | null) ?? null,
    username: (r.username as string | null) ?? null,
    role: (r.role as UserRole | null) ?? null,
    avatarUrl: (r.avatar_url as string | null) ?? null,
    firstName: (r.first_name as string | null) ?? null,
    lastName: (r.last_name as string | null) ?? null,
    email: (r.email as string | null) ?? null,
    birthDate: (r.birth_date as string | null) ?? null,
    jobTitle: (r.job_title as string | null) ?? null,
    hireDate: (r.hire_date as string | null) ?? null,
    status: (r.status as string | null) ?? null,
    isEmployee: r.job_title != null,
  }
}

// Sube la foto a storage (carpeta del propio usuario) y guarda su URL pública.
// Devuelve la URL con cache-bust para refrescar la vista al instante.
export async function uploadAvatar(userId: string, file: File): Promise<string> {
  const ext = (file.name.split('.').pop() ?? 'jpg').toLowerCase()
  const path = `${userId}/avatar.${ext}`

  const { error: upErr } = await supabase.storage
    .from('avatars')
    .upload(path, file, { upsert: true, contentType: file.type })
  if (upErr) throw new Error(upErr.message)

  const { data } = supabase.storage.from('avatars').getPublicUrl(path)
  const url = data.publicUrl

  const { error: rpcErr } = await supabase.rpc('set_my_avatar', { p_url: url })
  if (rpcErr) throw new Error(rpcErr.message)

  return `${url}?v=${Date.now()}`
}
