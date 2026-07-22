// Descuento implícito de una tarifa ingresada vs. el precio base del tipo
// de habitación (room_types.base_price_bs). Espejo EXACTO de la función SQL
// `public.discount_pct` (20260722020000_discount_approval_workflow.sql) —
// cualquier cambio acá debe replicarse ahí (y viceversa), ver riesgo #3 del
// diseño (change: discount-approval-workflow).
export function discountPct(baseBs: number, priceBs: number): number {
  if (!(baseBs > 0)) return 0
  const raw = ((baseBs - priceBs) / baseBs) * 100
  const clamped = Math.min(100, Math.max(0, raw))
  return Math.round(clamped * 100) / 100
}

// Techo de descuento aplicable sin aprobación (REQ discount ceiling).
// Exactamente 20.00% aplica sin aprobación; 20.01% en adelante requiere
// aprobación de reception_admin.
export const DISCOUNT_CEILING_PCT = 20

export function exceedsCeiling(pct: number): boolean {
  return pct > DISCOUNT_CEILING_PCT
}
