import { supabase } from './supabase'
import type { Profile, UserRole } from '../domain/auth/profile'

// Login por USERNAME: primero traducimos a email, luego autenticamos.
export async function signIn(username: string, password: string): Promise<void> {
  const { data: email, error: rpcError } = await supabase.rpc(
    'username_to_email',
    { p_username: username },
  )
  if (rpcError) throw new Error(rpcError.message)
  if (!email) throw new Error('Usuario o contraseña incorrectos')

  const { error } = await supabase.auth.signInWithPassword({
    email: email as string,
    password,
  })
  if (error) throw new Error('Usuario o contraseña incorrectos')
}

export async function signOut(): Promise<void> {
  await supabase.auth.signOut()
}

// Primer ingreso: fija contraseña propia + correo real (dispara verificación)
// y baja el flag de contraseña genérica.
export async function completeFirstLogin(
  newPassword: string,
  email: string,
): Promise<void> {
  const { error } = await supabase.auth.updateUser({
    password: newPassword,
    email,
  })
  if (error) throw new Error(error.message)
  const { error: flagError } = await supabase.rpc('clear_password_change_flag')
  if (flagError) throw new Error(flagError.message)
}

export async function getProfile(userId: string): Promise<Profile | null> {
  const { data, error } = await supabase
    .from('profiles')
    .select('id, username, full_name, role, must_change_password')
    .eq('id', userId)
    .maybeSingle()
  if (error) throw new Error(error.message)
  if (!data) return null
  return {
    id: data.id,
    username: data.username ?? '',
    fullName: data.full_name ?? '',
    role: data.role as UserRole,
    mustChangePassword: data.must_change_password ?? false,
  }
}
