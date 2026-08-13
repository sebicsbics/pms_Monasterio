/**
 * Escala de impresión para meter un contenido alto en una sola página.
 *
 * Nunca agranda (una hoja corta no se estira), y nunca achica más allá de
 * MIN_FIT_SCALE: por debajo de eso la hoja deja de ser legible, y una
 * lista que nadie puede leer es peor que una lista de dos páginas.
 */
export const MIN_FIT_SCALE = 0.55

export function fitScale(contentHeightPx: number, availableHeightPx: number): number {
  // Sin medición confiable (nodo oculto, estilos que no cargaron) se
  // imprime tal cual en vez de aplicar una escala inventada.
  if (contentHeightPx <= 0 || availableHeightPx <= 0) return 1
  if (contentHeightPx <= availableHeightPx) return 1
  return Math.max(MIN_FIT_SCALE, availableHeightPx / contentHeightPx)
}
