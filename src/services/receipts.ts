import { supabase } from './supabase'

// Sube un comprobante al bucket PRIVADO 'receipts' y devuelve su ruta.
// Convención de ruta plana `${año}/${uuid}.${ext}` — es la que ya usaban
// caja y check-out por separado; ahora vive en un solo lugar porque todos
// los flujos de cobro (anticipos, eventos, cuentas por cobrar) la comparten.
export async function uploadReceipt(file: File | null): Promise<string | null> {
  if (!file) return null
  const ext = (file.name.split('.').pop() ?? 'jpg').toLowerCase()
  const path = `${new Date().getFullYear()}/${crypto.randomUUID()}.${ext}`
  const { error } = await supabase.storage
    .from('receipts')
    .upload(path, file, { contentType: file.type })
  if (error) throw new Error(error.message)
  return path
}

// URL firmada temporal para ver un comprobante del bucket privado.
export async function receiptUrl(path: string): Promise<string | null> {
  const { data, error } = await supabase.storage
    .from('receipts')
    .createSignedUrl(path, 3600)
  if (error) return null
  return data.signedUrl
}
