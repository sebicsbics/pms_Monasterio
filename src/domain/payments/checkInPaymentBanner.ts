// Aviso no bloqueante cuando el check-in se confirmó pero el cobro no se
// pudo guardar: el check-in NO se revierte, sólo se avisa que el pago
// quedó pendiente. Reutiliza el mismo criterio de detección de caja
// cerrada que domain/anticipos/anticipos.ts (userFacingAnticipoError),
// pero con el texto puntual que pide este flujo (menciona el check-in).
//
// Vive en dominio y no en una vista porque los DOS puntos de entrada de
// check-in lo usan —llegadas (CheckInModal) y walk-in (RoomPanel)— y el
// mensaje tiene que ser idéntico en ambos: para recepción es el mismo
// hecho, no dos incidentes distintos.
export function checkInPaymentBanner(serverMessage: string): string {
  if (serverMessage.includes('No hay una caja abierta')) {
    return (
      'Check-in registrado. El cobro no se pudo guardar: no hay una caja ' +
      'abierta. Abrí la caja y registrá el pago desde Anticipos.'
    )
  }
  return (
    `Check-in registrado. El cobro no se pudo guardar: ${serverMessage}. ` +
    'Reintentalo desde Anticipos.'
  )
}
