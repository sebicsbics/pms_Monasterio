// Advertencia NO bloqueante al crear una cuenta por cobrar nueva (R10.3):
// evita duplicados accidentales por variantes de mayúsculas/acentos/
// puntuación, sin impedir que se cree una cuenta legítimamente distinta.
export function normalize(name: string): string {
  return name
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, '')
    .trim()
    .replace(/\s+/g, ' ')
}

export function findSimilarAccountName(name: string, existing: string[]): string | null {
  const normalized = normalize(name)
  if (!normalized) return null
  for (const candidate of existing) {
    const normalizedCandidate = normalize(candidate)
    if (!normalizedCandidate) continue
    if (
      normalizedCandidate === normalized ||
      normalizedCandidate.includes(normalized) ||
      normalized.includes(normalizedCandidate)
    ) {
      return candidate
    }
  }
  return null
}
