// Impresión aislada: abre una ventana nueva con el contenido del nodo y los
// estilos de la app clonados, para imprimir solo esa sección (sin el menú
// ni la barra lateral). Los elementos con clase `no-print` se ocultan.
//
// Se usa una ventana aparte (en vez de @media print sobre el documento) para
// que funcione igual en vistas normales y en modales (ej. el folio), sin
// conflictos de "qué se imprime".
export function printRegion(node: HTMLElement, title = document.title): void {
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
      </style></head><body>${node.outerHTML}</body></html>`,
  )
  win.document.close()
  win.focus()

  // Esperar a que carguen los estilos antes de imprimir.
  setTimeout(() => {
    win.print()
    win.close()
  }, 500)
}
