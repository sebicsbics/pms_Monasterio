import { createClient } from '@supabase/supabase-js'

// Vite expone al navegador SOLO las variables que empiezan con VITE_.
const supabaseUrl = import.meta.env.VITE_SUPABASE_URL
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY

// Falla temprano y claro si faltan las variables, en vez de un error críptico
// más adelante cuando intentemos consultar la base de datos.
if (!supabaseUrl || !supabaseAnonKey) {
  throw new Error(
    'Faltan VITE_SUPABASE_URL o VITE_SUPABASE_ANON_KEY. ' +
      'Creá un archivo .env.local con esos valores; están documentados ' +
      'en el README (sección "Puesta en marcha").',
  )
}

// Cliente único y compartido en toda la app (patrón singleton).
export const supabase = createClient(supabaseUrl, supabaseAnonKey)
