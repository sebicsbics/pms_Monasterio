// El checkbox "Acepta recibir promociones por correo" es inútil sin una
// dirección a la que mandarlas. Esta lógica es PURA: decide si el correo es
// obligatorio (según si la persona ya tiene uno cargado) y si el valor
// ingresado es válido. La UI solo la consume — no decide nada acá.

export function isValidEmail(value: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value.trim())
}

// Obligatorio SOLO cuando: quiere recibir ofertas Y no tiene un correo ya
// cargado. Si ya tiene uno, se muestra prellenado pero editable, sin forzar
// a tocarlo.
export function checkinEmailRequired(
  wantsOffers: boolean,
  currentEmail: string | null,
): boolean {
  return wantsOffers && !currentEmail
}

// null = sin error (puede enviarse tal cual). Blanco es válido cuando el
// correo no es obligatorio (deja el valor existente sin cambios, ver la
// migración: NULLIF + coalesce).
export function checkinEmailError(
  wantsOffers: boolean,
  currentEmail: string | null,
  inputEmail: string,
): string | null {
  const trimmed = inputEmail.trim()
  if (checkinEmailRequired(wantsOffers, currentEmail) && trimmed === '') {
    return 'Ingresá un correo para poder aceptar recibir promociones'
  }
  if (trimmed !== '' && !isValidEmail(trimmed)) {
    return 'El correo no es válido'
  }
  return null
}
