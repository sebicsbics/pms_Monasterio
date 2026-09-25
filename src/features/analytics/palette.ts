// Paleta validada de la skill dataviz (modo claro; superficie #fcfcfb).
// El orden de slots es el mecanismo de seguridad CVD, no cosmético: no reordenar.
export const CATEGORICAL = [
  '#2a78d6', // 1 azul
  '#1baf7a', // 2 aqua
  '#eda100', // 3 amarillo
  '#008300', // 4 verde
  '#4a3aa7', // 5 violeta
  '#e34948', // 6 rojo
  '#e87ba4', // 7 magenta
  '#eb6834', // 8 naranja
] as const

export const INK = {
  primary: '#0b0b0b',
  secondary: '#52514e',
  grid: '#e7e6e2',
} as const

// Hue por ENTIDAD (el color sigue a la entidad, nunca a su rank). Taxonomía de
// canal con orden fijo de slots.
export const CHANNEL_COLOR: Record<string, string> = {
  DIRECTO: CATEGORICAL[0],
  OTA: CATEGORICAL[1],
  AGENCIA: CATEGORICAL[2],
  EMPRESA: CATEGORICAL[4],
  REFERIDO: CATEGORICAL[6],
  EVENTO: CATEGORICAL[7],
  DESCONOCIDO: '#9a9992',
}

export const CHANNEL_LABEL: Record<string, string> = {
  DIRECTO: 'Directo',
  OTA: 'Agencia online',
  AGENCIA: 'Agencia de viajes',
  EMPRESA: 'Empresa / Convenio',
  REFERIDO: 'Referido',
  EVENTO: 'Evento',
  DESCONOCIDO: 'Sin clasificar',
}

// Formateadores. Bolivianos con separador de miles; sin decimales para tableros.
export const fmtBs = (n: number | null): string =>
  n == null ? '—' : `${Math.round(n).toLocaleString('es-BO')} Bs`
export const fmtInt = (n: number | null): string =>
  n == null ? '—' : Math.round(n).toLocaleString('es-BO')
export const fmtPct = (n: number | null): string =>
  n == null ? '—' : `${n.toFixed(1)}%`

export const MONTHS = [
  '', 'Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun',
  'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic',
]

const MONTHS_LOWER = MONTHS.map((m) => m.toLowerCase())

// "parcial: sep–dic" a partir de fechas ISO (YYYY-MM-DD). null si falta
// alguna fecha; mismo mes en ambas puntas colapsa a un solo mes.
export const formatPartialRange = (
  desde: string | null,
  hasta: string | null,
): string | null => {
  if (!desde || !hasta) return null
  const mDesde = Number(desde.slice(5, 7))
  const mHasta = Number(hasta.slice(5, 7))
  if (!mDesde || !mHasta) return null
  const from = MONTHS_LOWER[mDesde]
  const to = MONTHS_LOWER[mHasta]
  return from === to ? `parcial: ${from}` : `parcial: ${from}–${to}`
}

// "datos insuficientes (1–2 ene)" cuando el año tiene menos de 30 días
// cubiertos: a diferencia de formatPartialRange (rango de meses, para
// años con semanas/meses de datos) acá el rango suele caber en unos
// pocos días, así que se muestra día + mes de cada punta.
export const formatInsufficientLabel = (
  desde: string | null,
  hasta: string | null,
): string => {
  if (!desde || !hasta) return 'datos insuficientes'
  const dDesde = Number(desde.slice(8, 10))
  const mDesde = Number(desde.slice(5, 7))
  const dHasta = Number(hasta.slice(8, 10))
  const mHasta = Number(hasta.slice(5, 7))
  if (!dDesde || !mDesde || !dHasta || !mHasta) return 'datos insuficientes'
  const mesDesde = MONTHS_LOWER[mDesde]
  const mesHasta = MONTHS_LOWER[mHasta]
  const range = mesDesde === mesHasta
    ? `${dDesde}–${dHasta} ${mesDesde}`
    : `${dDesde} ${mesDesde}–${dHasta} ${mesHasta}`
  return `datos insuficientes (${range})`
}
