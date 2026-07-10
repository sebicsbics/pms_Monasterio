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
