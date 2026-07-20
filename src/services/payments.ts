import { supabase } from './supabase'
import type { PaymentMethod } from '../domain/payments/paymentMethod'

// Formas de pago activas, ordenadas por etiqueta. Única fuente de verdad:
// no hardcodear la lista en el frontend (ver design decision A de
// caja-qr-comprobantes-tarifa). Tabla real `payment_methods` viene del ETL
// histórico (20260703130000_seed_channels_and_payments.sql): columna
// `is_active` (no `active`), sin `sort_order`, códigos en MAYÚSCULA.
export async function fetchPaymentMethods(): Promise<PaymentMethod[]> {
  const { data, error } = await supabase
    .from('payment_methods')
    .select('code, label')
    .eq('is_active', true)
    .order('label', { ascending: true })
  if (error) throw new Error(error.message)
  return (data ?? []).map((r) => ({ code: r.code as string, label: r.label as string }))
}
