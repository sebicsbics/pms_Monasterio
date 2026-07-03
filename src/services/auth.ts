import { supabase } from './supabase'
import type { Profile, UserRole } from '../domain/auth/profile'

export async function signIn(email: string, password: string): Promise<void> {
  const { error } = await supabase.auth.signInWithPassword({ email, password })
  if (error) throw new Error(error.message)
}

export async function signOut(): Promise<void> {
  await supabase.auth.signOut()
}

// Trae el perfil (rol) del usuario logueado.
export async function getProfile(userId: string): Promise<Profile | null> {
  const { data, error } = await supabase
    .from('profiles')
    .select('id, full_name, role')
    .eq('id', userId)
    .maybeSingle()
  if (error) throw new Error(error.message)
  if (!data) return null
  return {
    id: data.id,
    fullName: data.full_name ?? '',
    role: data.role as UserRole,
  }
}
