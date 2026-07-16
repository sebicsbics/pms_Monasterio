import { supabase } from './supabase'
import type { PaymentMethod } from '../domain/payments/paymentMethod'

// Formas de pago activas, en el orden de despliegue definido en la tabla
// de referencia `payment_methods`. Única fuente de verdad: no hardcodear
// la lista en el frontend (ver design decision A de
// caja-qr-comprobantes-tarifa).
export async function fetchPaymentMethods(): Promise<PaymentMethod[]> {
  const { data, error } = await supabase
    .from('payment_methods')
    .select('code, label')
    .eq('active', true)
    .order('sort_order', { ascending: true })
  if (error) throw new Error(error.message)
  return (data ?? []).map((r) => ({ code: r.code as string, label: r.label as string }))
}
