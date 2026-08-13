import { fitScale } from './fitToPage'

// Impresión aislada: abre una ventana nueva con el contenido del nodo y los
// estilos de la app clonados, para imprimir solo esa sección (sin el menú
// ni la barra lateral). Los elementos con clase `no-print` se ocultan.
//
// Se usa una ventana aparte (en vez de @media print sobre el documento) para
// que funcione igual en vistas normales y en modales (ej. el folio), sin
// conflictos de "qué se imprime".
// A4 a 96 dpi menos el margen de @page (12mm arriba y abajo) y el padding
// del body. Es la altura real que queda para el contenido en una página.
const A4_HEIGHT_PX = 1123
const PAGE_MARGIN_PX = 91 // 12mm x2 (~91px) + padding del body

export interface PrintOptions {
  /**
   * Achica el contenido lo necesario para que entre en UNA página. Tiene
   * un piso de legibilidad (ver `fitScale`): si ni así entra, se imprime
   * al mínimo legible y se desborda a una segunda hoja.
   */
  fitToPage?: boolean
}

export function printRegion(
  node: HTMLElement,
  title = document.title,
  options: PrintOptions = {},
): void {
  const win = window.open('', '_blank', 'width=900,height=650')
  if (!win) {
    // Popup bloqueado: como fallback, imprimir el documento actual.
    window.print()
    return
  }

  // Clonar <style> y <link rel="stylesheet"> del documento (mismo origen).
  const styles = Array.from(
    document.head.querySelectorAll('style, link[rel="stylesheet"]'),
  )
    .map((n) => n.outerHTML)
    .join('\n')

  win.document.write(
    `<!doctype html><html><head><meta charset="utf-8"><title>${title}</title>` +
      styles +
      `<style>
        body { padding: 24px; background: #fff; }
        .no-print { display: none !important; }
        @page { margin: 12mm; }
        /* Una fila cortada por la mitad entre dos páginas es ilegible. */
        tr, tbody { break-inside: avoid; }
      </style></head><body><div id="print-root">${node.outerHTML}</div></body></html>`,
  )
  win.document.close()
  win.focus()

  // Esperar a que carguen los estilos antes de imprimir.
  setTimeout(() => {
    if (options.fitToPage) fitContentToOnePage(win)
    win.print()
    win.close()
  }, 500)
}

// Mide el contenido ya renderizado y lo achica con un `transform: scale`
// para que entre en una página. Se hace acá (y no con CSS) porque hasta
// que no está renderizado no se sabe cuánto mide: la lista de desayuno de
// una noche floja y la de hotel lleno no ocupan lo mismo.
function fitContentToOnePage(win: Window): void {
  const root = win.document.getElementById('print-root')
  if (!root) return

  const available = A4_HEIGHT_PX - PAGE_MARGIN_PX
  const scale = fitScale(root.scrollHeight, available)
  if (scale >= 1) return

  root.style.transformOrigin = 'top left'
  root.style.transform = `scale(${scale})`
  // Al escalar, el ancho se encoge junto con el alto y quedaría media
  // hoja vacía a la derecha: se compensa agrandando el ancho del nodo en
  // la misma proporción para que siga usando todo el papel.
  root.style.width = `${100 / scale}%`
}
