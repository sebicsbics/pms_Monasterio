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

  const { data, error } = await supabase.auth.signInWithPassword({
    email: email as string,
    password,
  })
  if (error) {
    // No enmascarar problemas de configuración ni del servidor como
    // "credenciales inválidas". Ya pasó dos veces que un mensaje genérico
    // mandara el diagnóstico al lado equivocado: un 500 de GoTrue por
    // columnas de token en NULL, y un 422 cuando se apagó el proveedor de
    // email entero al querer cerrar sólo el registro público.
    console.error('signInWithPassword error:', error.status, error.code, error.message)

    if (error.status && error.status >= 500) {
      throw new Error(
        'Error del servidor de autenticación. Intentá de nuevo en unos minutos.',
      )
    }
    // 422: el login por correo está deshabilitado en el proyecto. No es un
    // problema de quien entra, y nadie va a poder entrar hasta que se
    // reactive, así que el mensaje tiene que decir exactamente eso.
    if (error.status === 422 || error.code === 'email_provider_disabled') {
      throw new Error(
        'El inicio de sesión está deshabilitado en la configuración del ' +
          'sistema. Avisá al administrador: hay que reactivar el proveedor ' +
          'de correo en Supabase (Authentication → Providers → Email).',
      )
    }
    throw new Error('Usuario o contraseña incorrectos')
  }

  // Marcador de ingreso (best-effort: no bloquea el login si falla).
  if (data.user) {
    await recordAccess(data.user.id, 'login')
  }
}

export async function signOut(): Promise<void> {
  // Registrar la salida ANTES de cerrar sesión (mientras aún hay auth.uid()).
  const { data } = await supabase.auth.getUser()
  if (data.user) {
    await recordAccess(data.user.id, 'logout')
  }
  await supabase.auth.signOut()
}

// Inserta un evento de acceso sin romper el flujo si la RLS o la red fallan.
async function recordAccess(userId: string, type: 'login' | 'logout'): Promise<void> {
  try {
    await supabase.from('login_events').insert({ user_id: userId, event_type: type })
  } catch {
    // El registro de asistencia es secundario; nunca debe impedir entrar/salir.
  }
}

// Primer ingreso: fija la contraseña propia y baja el flag de contraseña
// genérica. NO toca el email de auth: el login es por username y el email
// interno (@staff.monasterio.local) es un identificador inmutable. Cambiar
// el email acá disparaba una validación de GoTrue que rechaza ese TLD y
// hacía fallar TODO el primer ingreso (incluida la contraseña). El correo
// real de contacto, si se necesita, se maneja como feature aparte.
export async function completeFirstLogin(newPassword: string): Promise<void> {
  const { error } = await supabase.auth.updateUser({ password: newPassword })
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
