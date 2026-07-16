/**
 * Formatea una fecha ISO como dd/mm/yyyy para mostrar en la UI.
 * El almacenamiento sigue siendo ISO en toda la app — esta función es
 * exclusivamente de presentación, nunca debe usarse en services/domain.
 */
const DATE_ONLY = /^\d{4}-\d{2}-\d{2}$/

export function formatDate(iso: string | null | undefined): string {
  if (!iso) return ''

  // Fechas "solo fecha" (yyyy-mm-dd, sin hora) se parsean manualmente para
  // evitar que `new Date('yyyy-mm-dd')` (interpretada como UTC medianoche)
  // se corra un día al leer los componentes en hora local.
  if (DATE_ONLY.test(iso)) {
    const [year, month, day] = iso.split('-')
    return `${day}/${month}/${year}`
  }

  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return ''
  const day = String(date.getDate()).padStart(2, '0')
  const month = String(date.getMonth() + 1).padStart(2, '0')
  const year = date.getFullYear()
  return `${day}/${month}/${year}`
}
