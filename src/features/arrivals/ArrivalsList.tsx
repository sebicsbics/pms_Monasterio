import { useCallback, useEffect, useState } from 'react'
import { X } from 'lucide-react'
import type { Arrival } from '../../domain/stays/arrival'
import {
  fetchArrivals,
  checkInWithOptionalPayment,
  type CompanionGuest,
} from '../../services/arrivals'
import { overrideReservationRate } from '../../services/checkin'
import { fetchReservationRate, type ReservationRateInfo } from '../../services/reservationRate'
import { fetchPreloadedOccupants } from '../../services/reservationGuests'
import {
  companionsFromOccupants,
  holderRpcParams,
  holderUiShape,
  initialHolderSelection,
  isHolderSelectionComplete,
  type HolderSelection,
  type PreloadedOccupant,
} from '../../domain/reservations/holderSelection'
import { checkinEmailError, checkinEmailRequired } from '../../domain/reservations/checkinEmail'
import { holderPrefillFields, holderToPrefill } from '../../domain/reservations/holderPrefill'
import { cancelReservation, rescheduleReservation } from '../../services/reservations'
import { needsOccupancyReason, occupancyReasonParam } from '../../domain/reservations/occupancyReason'
import { CompanionFields } from '../checkin/CompanionFields'
import { DocumentLookupField } from '../checkin/DocumentLookupField'
import { COUNTRIES } from '../../shared/data/countries'
import { TRAVEL_PURPOSES } from '../../shared/data/travelPurposes'
import { CHANNELS, DEFAULT_CHANNEL_CODE } from '../../shared/data/channels'
import type { UserRole } from '../../domain/auth/profile'
import { canEditRate as canEditRateGate } from '../../domain/auth/rateGates'
import { canWrite } from '../../domain/auth/profile'
import type { PaymentMethod } from '../../domain/payments/paymentMethod'
import { fetchPaymentMethods } from '../../services/payments'
import { isAnticipoMethod } from '../../domain/cash/cash'
import {
  EMPTY_PAYMENT_PROOF,
  paymentProofError,
  type PaymentProof,
} from '../../domain/payments/paymentProof'
import { PaymentProofFields } from '../payments/PaymentProofFields'
import {
  EMPTY_MIXED_PAYMENT,
  isMixed,
  mixedPaymentError,
  type MixedPayment,
} from '../../domain/payments/mixedPayment'
import { MixedPaymentFields } from '../payments/MixedPaymentFields'
import { checkInPaymentBanner } from '../../domain/payments/checkInPaymentBanner'

const TODAY = new Date().toISOString().slice(0, 10)

function CheckInModal({
  arrival,
  role,
  onClose,
  onDone,
}: {
  arrival: Arrival
  role?: UserRole | null
  onClose: () => void
  onDone: (banner?: string) => void
}) {
  const [document, setDocument] = useState('')
  const [birthDate, setBirthDate] = useState('')
  const [countryCode, setCountryCode] = useState('')
  const [city, setCity] = useState('')
  const [wantsOffers, setWantsOffers] = useState(false)
  const [originCity, setOriginCity] = useState('')
  const [agencyName, setAgencyName] = useState('')
  const [channelCode, setChannelCode] = useState(DEFAULT_CHANNEL_CODE)
  const [travelPurpose, setTravelPurpose] = useState('')
  const [occupation, setOccupation] = useState('')
  const [transportMeans, setTransportMeans] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  // Acompañantes: perfil completo de los demás huéspedes de la habitación.
  // Se pre-arma una ficha por cada plaza que la reserva estimó, pero el
  // recepcionista puede AGREGAR o QUITAR: `numGuests` es lo que se estimó
  // al tomar la reserva (muchas veces 1, o null) y no la gente que
  // realmente llega. El tope real es la capacidad de la habitación
  // (max_occupancy), igual que en el walk-in del tablero.
  const emptyCompanion = (): CompanionGuest => ({
    firstName: '',
    lastName: '',
    isMinor: false,
    document: '',
    birthDate: '',
    countryCode: '',
    city: '',
    originCity: '',
    travelPurpose: '',
    occupation: '',
    transportMeans: '',
  })
  const companionSlots = Math.max(0, (arrival.numGuests ?? 1) - 1)
  const [companions, setCompanions] = useState<CompanionGuest[]>(() =>
    Array.from({ length: companionSlots }, emptyCompanion),
  )
  // Ya no es un tope duro: se puede exceder max_occupancy con motivo (ver
  // domain/reservations/occupancyReason.ts). maxCompanions solo decide
  // cuándo aparece el campo de motivo obligatorio.
  const maxCompanions = Math.max(0, (arrival.maxOccupancy ?? 1) - 1)
  const [occupancyReason, setOccupancyReason] = useState('')
  const resultingOccupancy = companions.length + 1
  const overOccupancy = needsOccupancyReason(resultingOccupancy, arrival.maxOccupancy)
  function updateCompanion(index: number, patch: Partial<CompanionGuest>) {
    setCompanions((prev) =>
      prev.map((g, i) => (i === index ? { ...g, ...patch } : g)),
    )
  }

  // Titular sin resolver (reserva creada con "el contacto no se hospeda" o
  // bulk sin ocupante precargado — ver Arrival.holderFirstName/LastName).
  // Recepción tiene que elegir entre un ocupante ya precargado o cargar un
  // nombre nuevo ANTES de poder confirmar el check-in. Ver
  // domain/reservations/holderSelection.ts.
  const needsHolder = !arrival.holderFirstName || !arrival.holderLastName
  const [occupants, setOccupants] = useState<PreloadedOccupant[]>([])
  const [holderSelection, setHolderSelection] = useState<HolderSelection>({ kind: 'none' })
  // Correo YA cargado del titular (para no pedirlo de nuevo si ya existe)
  // y el valor editable que ve el input. Se busca vía reservation_guests
  // (fetchPreloadedOccupants) porque incluye la fila del holder aun
  // cuando ya está resuelto (guest_id no nulo) — arrivals() solo trae el
  // correo del CONTACTO de la booking, no del titular. Ver
  // domain/reservations/checkinEmail.ts.
  const [holderEmailOnFile, setHolderEmailOnFile] = useState<string | null>(null)
  const [emailInput, setEmailInput] = useState('')

  useEffect(() => {
    fetchPreloadedOccupants(arrival.reservationId)
      .then((loaded) => {
        setOccupants(loaded)
        // Sin ocupantes precargados la única opción real es cargar un
        // nombre nuevo: arrancamos ahí directo, sin pedir un click en un
        // radio que no representa ninguna elección (bug del smoke test).
        if (needsHolder) setHolderSelection(initialHolderSelection(loaded))
        const holder = loaded.find((o) => o.role === 'holder')
        setHolderEmailOnFile(holder?.email ?? null)
        setEmailInput(holder?.email ?? '')
      })
      .catch((e: Error) => setError(e.message))
    // Solo al montar: la reserva no cambia durante la vida del modal.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const emailRequired = checkinEmailRequired(wantsOffers, holderEmailOnFile)
  const emailError = wantsOffers
    ? checkinEmailError(wantsOffers, holderEmailOnFile, emailInput)
    : null

  // Los ocupantes precargados que NO se eligieron como titular pasan a la
  // lista de acompañantes a confirmar (prellenados por nombre; el
  // documento se completa por persona, igual que siempre).
  useEffect(() => {
    if (!needsHolder) return
    const excludeId = holderSelection.kind === 'existing' ? holderSelection.personId : null
    setCompanions(
      companionsFromOccupants(occupants, excludeId).map((d) => ({
        ...emptyCompanion(),
        ...d,
      })),
    )
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [occupants, holderSelection])

  // Si el titular ya se conoce (guest_id resuelto al reservar) o recién se
  // eligió de la lista de ocupantes precargados, el check-in es CONFIRMAR
  // sus datos ya guardados, no pedirlos de nuevo vacíos — antes esto solo
  // corría al ELEGIR de la lista ámbar, y esa lista nunca aparece cuando el
  // titular ya viene resuelto desde la reserva (bug reportado: reserva
  // bulk con documento cargado llegaba al check-in con Documento vacío).
  // Ver domain/reservations/holderPrefill.ts.
  useEffect(() => {
    const holder = holderToPrefill(occupants, needsHolder, holderSelection)
    if (!holder) return
    const fields = holderPrefillFields(holder)
    setDocument(fields.document)
    setBirthDate(fields.birthDate)
    setCountryCode(fields.countryCode)
    setCity(fields.city)
    setOccupation(fields.occupation)
    // Procedencia, motivo de viaje y transporte quedan en blanco a
    // propósito: son de esta llegada, no de la persona (ver
    // holderPrefill.ts). Recepción los carga en cada check-in.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [holderSelection, occupants, needsHolder])

  // Edición de tarifa al cargar la reserva (root/reception), con
  // justificación obligatoria. La tarifa se aplica DENTRO del mismo submit
  // del check-in (no hay botón "Guardar" aparte): antes existían dos
  // acciones separadas y si el recepcionista confirmaba el check-in sin
  // guardar la tarifa, el precio se perdía en silencio y el folio quedaba
  // a precio de lista. Ahora es una sola acción atómica desde la UX.
  const [rateEditOpen, setRateEditOpen] = useState(false)
  const [newRate, setNewRate] = useState('')
  const [rateReason, setRateReason] = useState('')
  const canEditRate = canEditRateGate(role)
  // Tarifa vigente, para saber si hace falta cambiarla ANTES de mostrar el
  // botón "Editar tarifa" (issue 1 del smoke test manual): sin esto, no
  // había forma de saber qué tarifa tenía la reserva.
  const [rateInfo, setRateInfo] = useState<ReservationRateInfo | null>(null)
  useEffect(() => {
    if (!canEditRate) return
    fetchReservationRate(arrival.reservationId)
      .then(setRateInfo)
      .catch((e: Error) => setError(e.message))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [canEditRate])

  const ratePending = rateEditOpen && newRate.trim() !== ''

  // Cobro opcional al confirmar el check-in: reutiliza record_anticipo vía
  // checkInWithOptionalPayment (dos llamados secuenciales, ver
  // services/arrivals.ts). Amount vacío/0 = no se intenta ningún cobro
  // (R2.2), es el mismo patrón de RecordAnticipoForm.
  const [paymentAmount, setPaymentAmount] = useState('')
  const [paymentMethod, setPaymentMethod] = useState('')
  const [paymentNotes, setPaymentNotes] = useState('')
  const [paymentProof, setPaymentProof] = useState<PaymentProof>(EMPTY_PAYMENT_PROOF)
  const [paymentMixed, setPaymentMixed] = useState<MixedPayment>(EMPTY_MIXED_PAYMENT)
  const [paymentMethods, setPaymentMethods] = useState<PaymentMethod[]>([])
  const paymentAmountNumber = Number(paymentAmount) || 0
  const wantsPayment = paymentAmountNumber > 0
  const paymentError = !wantsPayment
    ? null
    : isMixed(paymentMethod)
      ? mixedPaymentError(paymentAmountNumber, paymentMixed, paymentProof)
      : paymentProofError(paymentMethod, paymentProof)

  useEffect(() => {
    fetchPaymentMethods()
      .then((methods) => {
        const usable = methods.filter((m) => isAnticipoMethod(m.code))
        setPaymentMethods(usable)
        setPaymentMethod((current) => current || (usable[0]?.code ?? ''))
      })
      .catch((e: Error) => setError(e.message))
  }, [])

  async function handleCheckIn() {
    // Validación fail-fast de la tarifa antes de tocar nada, para no dejar
    // el check-in hecho con la tarifa a medias.
    if (ratePending && rateReason.trim() === '') {
      setError('La justificación de la tarifa es obligatoria')
      return
    }
    // Idem para el cobro: si el respaldo obligatorio (foto QR, referencia
    // de tarjeta, desglose mixto) falta, no llegamos ni a intentar el
    // check-in — mejor cortar antes que dejar el check-in hecho y el
    // cobro rechazado por algo que la UI podía haber evitado.
    if (wantsPayment && paymentError) {
      setError(paymentError)
      return
    }
    if (needsHolder && !isHolderSelectionComplete(needsHolder, holderSelection)) {
      setError('Elegí quién es el titular de la habitación')
      return
    }
    if (overOccupancy && occupancyReason.trim() === '') {
      setError('Indicá un motivo para exceder la capacidad de la habitación')
      return
    }
    if (wantsOffers && emailError) {
      setError(emailError)
      return
    }

    setBusy(true)
    setError(null)
    try {
      // 1) Si hay una tarifa custom, aplicarla primero. Devuelve un aviso
      //    (o null) cuando el descuento >20% queda pendiente de aprobación
      //    de reception_admin: el check-in igual se completa a precio de
      //    lista hasta que se apruebe.
      let pending: string | null = null
      if (ratePending) {
        pending = await overrideReservationRate(
          arrival.reservationId,
          Number(newRate),
          rateReason,
        )
      }

      // 2) Check-in del titular + acompañantes, y recién si eso funciona,
      //    el cobro opcional (segundo llamado independiente — ver
      //    checkInWithOptionalPayment). Un cobro rechazado NO revierte
      //    el check-in ni relanza: viaja en outcome.paymentError.
      const outcome = await checkInWithOptionalPayment(
        arrival.reservationId,
        {
          document: document.trim(),
          birthDate,
          countryCode: countryCode.trim().toUpperCase(),
          city: city.trim(),
          wantsOffers,
          email: wantsOffers ? emailInput.trim() : undefined,
          originCity: originCity.trim(),
          travelPurpose: travelPurpose.trim(),
          occupation: occupation.trim(),
          transportMeans: transportMeans.trim(),
          agencyName: agencyName.trim(),
          channelCode,
          ...holderRpcParams(needsHolder, holderSelection),
          ...occupancyReasonParam(resultingOccupancy, arrival.maxOccupancy, occupancyReason),
        },
        companions,
        wantsPayment
          ? {
              amountBs: paymentAmountNumber,
              paymentMethod,
              notes: paymentNotes.trim() || null,
              proof: paymentProof,
              mixed: isMixed(paymentMethod)
                ? {
                    cashBs: Number(paymentMixed.cashBs),
                    nonCashBs: Number(paymentMixed.nonCashBs),
                    nonCashMethod: paymentMixed.nonCashMethod,
                  }
                : null,
            }
          : null,
      )

      // Si quedó un descuento pendiente, avisamos y no cerramos el modal
      // de golpe: que recepción vea el mensaje.
      if (pending) {
        setError(pending)
        setBusy(false)
        return
      }
      onDone(outcome.paymentError ? checkInPaymentBanner(outcome.paymentError) : undefined)
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="fixed inset-0 z-10 flex justify-end bg-black/30">
      <aside className="h-full w-full max-w-sm overflow-y-auto bg-white p-6 shadow-xl">
        <div className="mb-4 flex items-center justify-between">
          <h2 className="text-xl font-bold text-slate-800">
            Check-in · Hab. {arrival.roomNumber}
          </h2>
          <button
            type="button"
            onClick={onClose}
            aria-label="Cerrar"
            className="text-slate-400 hover:text-slate-700"
          >
            <X size={20} />
          </button>
        </div>

        <p className="mb-4 text-sm text-slate-500">
          {arrival.firstName} {arrival.lastName} · {arrival.roomType}
          <br />
          {arrival.checkInDate} → {arrival.checkOutDate}
        </p>

        {error && (
          <p className="mb-3 rounded bg-red-50 p-2 text-sm text-red-700">
            {error}
          </p>
        )}

        {needsHolder && holderUiShape(occupants) === 'direct-new' && (
          <div className="mb-4 space-y-2 rounded border border-amber-200 bg-amber-50 p-3">
            <p className="text-xs font-medium text-amber-800">
              Esta reserva no tiene titular definido. Cargá los datos de
              quien se aloja en la habitación:
            </p>
            <div className="flex gap-2">
              <input
                placeholder="Nombre"
                value={holderSelection.kind === 'new' ? holderSelection.firstName : ''}
                onChange={(e) =>
                  setHolderSelection((prev) =>
                    prev.kind === 'new'
                      ? { ...prev, firstName: e.target.value }
                      : { kind: 'new', firstName: e.target.value, lastName: '' },
                  )
                }
                className="w-1/2 rounded border border-slate-300 p-2 text-sm"
              />
              <input
                placeholder="Apellido"
                value={holderSelection.kind === 'new' ? holderSelection.lastName : ''}
                onChange={(e) =>
                  setHolderSelection((prev) =>
                    prev.kind === 'new'
                      ? { ...prev, lastName: e.target.value }
                      : { kind: 'new', firstName: '', lastName: e.target.value },
                  )
                }
                className="w-1/2 rounded border border-slate-300 p-2 text-sm"
              />
            </div>
            {!isHolderSelectionComplete(needsHolder, holderSelection) && (
              <p className="text-xs text-amber-700">Nombre y apellido son obligatorios.</p>
            )}
          </div>
        )}

        {needsHolder && holderUiShape(occupants) === 'choose-occupant' && (
          <div className="mb-4 space-y-2 rounded border border-amber-200 bg-amber-50 p-3">
            <p className="text-xs font-medium text-amber-800">
              Esta reserva no tiene titular definido. Elegí quién se aloja en
              la habitación (los datos de abajo son del titular):
            </p>
            {occupants.map((o) => (
              <label key={o.personId} className="flex items-center gap-2 text-sm text-slate-700">
                <input
                  type="radio"
                  name="holder-selection"
                  checked={
                    holderSelection.kind === 'existing' && holderSelection.personId === o.personId
                  }
                  onChange={() => setHolderSelection({ kind: 'existing', personId: o.personId })}
                />
                {o.firstName} {o.lastName}
              </label>
            ))}
            <label className="flex items-center gap-2 text-sm text-slate-700">
              <input
                type="radio"
                name="holder-selection"
                checked={holderSelection.kind === 'new'}
                onChange={() => setHolderSelection({ kind: 'new', firstName: '', lastName: '' })}
              />
              Otro huésped (no está en la lista)
            </label>
            {holderSelection.kind === 'new' && (
              <div className="flex gap-2 pl-6">
                <input
                  placeholder="Nombre"
                  value={holderSelection.firstName}
                  onChange={(e) =>
                    setHolderSelection((prev) =>
                      prev.kind === 'new' ? { ...prev, firstName: e.target.value } : prev,
                    )
                  }
                  className="w-1/2 rounded border border-slate-300 p-2 text-sm"
                />
                <input
                  placeholder="Apellido"
                  value={holderSelection.lastName}
                  onChange={(e) =>
                    setHolderSelection((prev) =>
                      prev.kind === 'new' ? { ...prev, lastName: e.target.value } : prev,
                    )
                  }
                  className="w-1/2 rounded border border-slate-300 p-2 text-sm"
                />
              </div>
            )}
            {!isHolderSelectionComplete(needsHolder, holderSelection) && (
              <p className="text-xs text-amber-700">Elegí un huésped o cargá uno nuevo.</p>
            )}
          </div>
        )}

        {canEditRate && (
          <div className="mb-4">
            {rateInfo && (
              <p className="mb-1 text-xs text-slate-500">
                Tarifa actual: Bs {rateInfo.currentRateBs?.toFixed(2) ?? '—'} / noche
                {rateInfo.baseRateBs != null &&
                  rateInfo.currentRateBs != null &&
                  rateInfo.baseRateBs !== rateInfo.currentRateBs && (
                    <> (precio de lista del tipo: Bs {rateInfo.baseRateBs.toFixed(2)})</>
                  )}
              </p>
            )}
            {!rateEditOpen ? (
              <button
                type="button"
                onClick={() => setRateEditOpen(true)}
                className="text-xs font-medium text-brand-700 hover:underline"
              >
                Editar tarifa
              </button>
            ) : (
              <div className="mt-2 space-y-2 rounded border border-slate-200 p-3">
                <p className="text-xs text-slate-500">
                  La tarifa se aplica al confirmar el check-in.
                </p>
                <label className="block text-sm">
                  <span className="mb-1 block text-xs font-medium text-slate-500">
                    Nueva tarifa (Bs)
                  </span>
                  <input
                    type="number"
                    min={0}
                    step="0.01"
                    value={newRate}
                    onChange={(e) => setNewRate(e.target.value)}
                    className="w-full rounded border border-slate-300 p-2 text-sm"
                  />
                </label>
                <label className="block text-sm">
                  <span className="mb-1 block text-xs font-medium text-slate-500">
                    Justificación (obligatoria)
                  </span>
                  <textarea
                    value={rateReason}
                    onChange={(e) => setRateReason(e.target.value)}
                    placeholder="Ej. Última cuádruple disponible, se vende a precio de matrimonial"
                    className="w-full rounded border border-slate-300 p-2 text-sm"
                    rows={2}
                  />
                </label>
                <button
                  type="button"
                  onClick={() => {
                    setRateEditOpen(false)
                    setNewRate('')
                    setRateReason('')
                  }}
                  className="text-xs text-slate-500 hover:underline"
                >
                  Quitar tarifa custom
                </button>
              </div>
            )}
          </div>
        )}

        <div className="space-y-3">
          <p className="text-xs text-slate-500">Completá el perfil del huésped:</p>
          {/* El titular ya tiene nombre por la reserva: la búsqueda solo
              rellena el resto de su ficha, nunca lo renombra. */}
          <DocumentLookupField
            value={document}
            onChange={setDocument}
            onFound={(p) => {
              setBirthDate(p.birthDate)
              setCountryCode(p.countryCode)
              setCity(p.city)
              setOccupation(p.occupation)
              setWantsOffers(p.wantsOffers)
            }}
            className="w-full rounded border border-slate-300 p-2"
          />
          <div className="flex gap-2">
            <select
              value={countryCode}
              onChange={(e) => setCountryCode(e.target.value)}
              className="w-1/2 rounded border border-slate-300 p-2"
            >
              <option value="">País…</option>
              {COUNTRIES.map((c) => (
                <option key={c.code} value={c.code}>
                  {c.name}
                </option>
              ))}
            </select>
            <input
              placeholder="Ciudad"
              value={city}
              onChange={(e) => setCity(e.target.value)}
              className="w-1/2 rounded border border-slate-300 p-2"
            />
          </div>
          <div className="flex gap-2">
            <input
              placeholder="Agencia / empresa (opcional)"
              value={agencyName}
              onChange={(e) => setAgencyName(e.target.value)}
              className="w-1/2 rounded border border-slate-300 p-2"
            />
            <select
              value={channelCode}
              onChange={(e) => setChannelCode(e.target.value)}
              className="w-1/2 rounded border border-slate-300 p-2 text-slate-700"
            >
              {CHANNELS.map((c) => (
                <option key={c.code} value={c.code}>
                  {c.label}
                </option>
              ))}
            </select>
          </div>
          <label className="block text-sm">
            <span className="text-slate-600">Fecha de nacimiento</span>
            <input
              type="date"
              value={birthDate}
              onChange={(e) => setBirthDate(e.target.value)}
              className="mt-1 w-full rounded border border-slate-300 p-2"
            />
          </label>
          <input
            placeholder="Ciudad de procedencia"
            value={originCity}
            onChange={(e) => setOriginCity(e.target.value)}
            className="w-full rounded border border-slate-300 p-2"
          />
          <select
            value={travelPurpose}
            onChange={(e) => setTravelPurpose(e.target.value)}
            className="w-full rounded border border-slate-300 p-2 text-slate-700"
          >
            <option value="">Motivo de viaje…</option>
            {TRAVEL_PURPOSES.map((p) => (
              <option key={p} value={p}>
                {p}
              </option>
            ))}
          </select>
          <div className="flex gap-2">
            <input
              placeholder="Profesión / Ocupación"
              value={occupation}
              onChange={(e) => setOccupation(e.target.value)}
              className="w-1/2 rounded border border-slate-300 p-2"
            />
            <input
              placeholder="Medio de transporte"
              value={transportMeans}
              onChange={(e) => setTransportMeans(e.target.value)}
              className="w-1/2 rounded border border-slate-300 p-2"
            />
          </div>
          <label className="flex items-center gap-2 text-sm text-slate-600">
            <input
              type="checkbox"
              checked={wantsOffers}
              onChange={(e) => setWantsOffers(e.target.checked)}
            />
            Acepta recibir promociones por correo
          </label>
          {wantsOffers && (
            <div>
              <input
                type="email"
                placeholder={emailRequired ? 'Correo (obligatorio)' : 'Correo'}
                value={emailInput}
                onChange={(e) => setEmailInput(e.target.value)}
                className="w-full rounded border border-slate-300 p-2"
              />
              {emailError && <p className="mt-1 text-xs text-red-600">{emailError}</p>}
            </div>
          )}

          <div className="space-y-3 border-t border-slate-200 pt-3">
            <div className="flex items-center justify-between">
              <span className="text-xs font-medium text-slate-600">
                Acompañantes {companions.length > 0 && `(${companions.length})`}
              </span>
              <button
                type="button"
                onClick={() => setCompanions((prev) => [...prev, emptyCompanion()])}
                className="text-xs font-medium text-brand-700 hover:underline"
              >
                + Agregar huésped
              </button>
            </div>
            {overOccupancy && (
              <div className="rounded border border-amber-200 bg-amber-50 p-3">
                <p className="mb-2 text-xs font-medium text-amber-800">
                  La habitación admite {maxCompanions + 1} huésped(es); estás
                  registrando {resultingOccupancy}. Indicá un motivo para exceder el límite.
                </p>
                <input
                  placeholder="Motivo (ej. cuna adicional, colchón extra)"
                  value={occupancyReason}
                  onChange={(e) => setOccupancyReason(e.target.value)}
                  className="w-full rounded border border-slate-300 p-2 text-sm"
                />
              </div>
            )}
            {companions.map((g, i) => (
              <div key={i} className="space-y-2 rounded border border-slate-200 p-3">
                <div className="flex items-center justify-between">
                  <p className="text-xs font-semibold text-slate-500">Huésped {i + 2}</p>
                  <button
                    type="button"
                    onClick={() => setCompanions((prev) => prev.filter((_, j) => j !== i))}
                    className="text-xs text-slate-400 hover:text-red-600"
                  >
                    Quitar
                  </button>
                </div>
                <CompanionFields
                  companion={g}
                  onChange={(patch) => updateCompanion(i, patch)}
                />
              </div>
            ))}
          </div>

          <div className="space-y-3 border-t border-slate-200 pt-3">
            <p className="text-xs font-medium text-slate-600">
              Cobrar al check-in (opcional)
            </p>
            <p className="text-xs text-slate-400">
              Dejá el monto en blanco si no se cobra nada ahora — la reserva
              queda igual de en-in-house y se puede cobrar después desde
              Anticipos.
            </p>
            <div className="flex gap-2">
              <label className="w-1/2 text-sm">
                <span className="mb-1 block text-xs font-medium text-slate-500">
                  Monto a cobrar (Bs)
                </span>
                <input
                  type="number"
                  min={0}
                  step="0.01"
                  value={paymentAmount}
                  onChange={(e) => setPaymentAmount(e.target.value)}
                  placeholder="0.00"
                  className="w-full rounded border border-slate-300 p-2 text-sm"
                />
              </label>
              <label className="w-1/2 text-sm">
                <span className="mb-1 block text-xs font-medium text-slate-500">
                  Forma de pago
                </span>
                <select
                  value={paymentMethod}
                  onChange={(e) => setPaymentMethod(e.target.value)}
                  disabled={!wantsPayment}
                  className="w-full rounded border border-slate-300 p-2 text-sm disabled:opacity-50"
                >
                  {paymentMethods.map((m) => (
                    <option key={m.code} value={m.code}>
                      {m.label}
                    </option>
                  ))}
                </select>
              </label>
            </div>
            {wantsPayment &&
              (isMixed(paymentMethod) ? (
                <MixedPaymentFields
                  total={paymentAmountNumber}
                  split={paymentMixed}
                  proof={paymentProof}
                  onSplitChange={(patch) => setPaymentMixed((m) => ({ ...m, ...patch }))}
                  onProofChange={(patch) => setPaymentProof((p) => ({ ...p, ...patch }))}
                />
              ) : (
                <PaymentProofFields
                  method={paymentMethod}
                  proof={paymentProof}
                  onChange={(patch) => setPaymentProof((p) => ({ ...p, ...patch }))}
                />
              ))}
            {wantsPayment && (
              <label className="block text-sm">
                <span className="mb-1 block text-xs font-medium text-slate-500">
                  Notas del cobro (opcional)
                </span>
                <input
                  value={paymentNotes}
                  onChange={(e) => setPaymentNotes(e.target.value)}
                  className="w-full rounded border border-slate-300 p-2 text-sm"
                />
              </label>
            )}
          </div>

          <button
            type="button"
            disabled={
              busy ||
              (ratePending && !rateReason.trim()) ||
              (wantsPayment && paymentError !== null) ||
              (needsHolder && !isHolderSelectionComplete(needsHolder, holderSelection))
            }
            onClick={handleCheckIn}
            className="w-full rounded bg-brand-700 py-2 font-medium text-white hover:bg-brand-800 disabled:opacity-50"
          >
            {busy
              ? 'Procesando…'
              : ratePending
                ? 'Aplicar tarifa y confirmar check-in'
                : 'Confirmar check-in'}
          </button>
        </div>
      </aside>
    </div>
  )
}

// Suma días a una fecha 'YYYY-MM-DD' devolviendo el mismo formato.
function addDays(date: string, days: number): string {
  const d = new Date(`${date}T00:00:00`)
  d.setDate(d.getDate() + days)
  return d.toISOString().slice(0, 10)
}

// Cancelar o reprogramar una reserva confirmada. El hotel NO reembolsa:
// al cancelar, el anticipo (si lo hay) se pierde; al reprogramar, se
// mueven las fechas (se re-chequea disponibilidad en el backend).
function ReservationActionModal({
  arrival,
  kind,
  onClose,
  onDone,
}: {
  arrival: Arrival
  kind: 'cancel' | 'reschedule'
  onClose: () => void
  onDone: () => void
}) {
  const [reason, setReason] = useState('')
  const [checkIn, setCheckIn] = useState(arrival.checkInDate)
  const [checkOut, setCheckOut] = useState(arrival.checkOutDate)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const isCancel = kind === 'cancel'

  async function handleSubmit() {
    setBusy(true)
    setError(null)
    try {
      if (isCancel) {
        await cancelReservation(arrival.reservationId, reason)
      } else {
        await rescheduleReservation(arrival.reservationId, checkIn, checkOut, reason)
      }
      onDone()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="fixed inset-0 z-10 flex justify-end bg-black/30">
      <aside className="h-full w-full max-w-sm overflow-y-auto bg-white p-6 shadow-xl">
        <div className="mb-4 flex items-center justify-between">
          <h2 className="text-xl font-bold text-slate-800">
            {isCancel ? 'Cancelar reserva' : 'Reprogramar reserva'} · Hab. {arrival.roomNumber}
          </h2>
          <button
            type="button"
            onClick={onClose}
            aria-label="Cerrar"
            className="text-slate-400 hover:text-slate-700"
          >
            <X size={20} />
          </button>
        </div>

        <p className="mb-4 text-sm text-slate-500">
          {arrival.firstName} {arrival.lastName} · {arrival.roomType}
          <br />
          {arrival.checkInDate} → {arrival.checkOutDate}
        </p>

        {error && (
          <p className="mb-3 rounded bg-red-50 p-2 text-sm text-red-700">{error}</p>
        )}

        {isCancel ? (
          <p className="mb-3 rounded bg-amber-50 p-2 text-xs text-amber-800">
            El anticipo (si lo hay) se pierde: no hay reembolso.
          </p>
        ) : (
          <div className="mb-3 space-y-3">
            <label className="block text-sm">
              <span className="mb-1 block text-xs font-medium text-slate-500">Nueva entrada</span>
              <input
                type="date"
                value={checkIn}
                max={checkOut}
                onChange={(e) => setCheckIn(e.target.value)}
                className="w-full rounded border border-slate-300 p-2 text-sm"
              />
            </label>
            <label className="block text-sm">
              <span className="mb-1 block text-xs font-medium text-slate-500">Nueva salida</span>
              <input
                type="date"
                value={checkOut}
                min={checkIn}
                onChange={(e) => setCheckOut(e.target.value)}
                className="w-full rounded border border-slate-300 p-2 text-sm"
              />
            </label>
          </div>
        )}

        <label className="block text-sm">
          <span className="mb-1 block text-xs font-medium text-slate-500">
            Justificación (obligatoria)
          </span>
          <textarea
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            rows={2}
            className="w-full rounded border border-slate-300 p-2 text-sm"
          />
        </label>

        <button
          type="button"
          disabled={busy || !reason.trim()}
          onClick={handleSubmit}
          className={`mt-4 w-full rounded py-2 font-medium text-white disabled:opacity-50 ${
            isCancel ? 'bg-red-600 hover:bg-red-700' : 'bg-brand-700 hover:bg-brand-800'
          }`}
        >
          {busy
            ? 'Procesando…'
            : isCancel
              ? 'Confirmar cancelación'
              : 'Confirmar reprogramación'}
        </button>
      </aside>
    </div>
  )
}

export function ArrivalsList({ role }: { role?: UserRole | null }) {
  // owner consulta las llegadas del día pero no hace check-in ni cancela.
  const readOnly = !canWrite(role)
  const [arrivals, setArrivals] = useState<Arrival[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  // Aviso no bloqueante: check-in confirmado pero el cobro asociado no se
  // pudo guardar (caja cerrada u otro motivo). El check-in NO se revierte
  // — esto solo recuerda a recepción que hay que cobrar aparte.
  const [paymentBanner, setPaymentBanner] = useState<string | null>(null)
  const [selected, setSelected] = useState<Arrival | null>(null)
  const [action, setAction] = useState<{ arrival: Arrival; kind: 'cancel' | 'reschedule' } | null>(
    null,
  )
  // Rango de fechas de entrada. Default: solo hoy (incluye vencidas via
  // cota inferior null cuando el rango arranca en hoy).
  const [from, setFrom] = useState(TODAY)
  const [to, setTo] = useState(TODAY)

  const reload = useCallback(() => {
    // Si el rango arranca hoy, dejamos la cota inferior abierta para no
    // perder las llegadas vencidas que aún no hicieron check-in.
    const lowerBound = from <= TODAY ? null : from
    return fetchArrivals(lowerBound, to)
      .then(setArrivals)
      .catch((e: Error) => setError(e.message))
  }, [from, to])

  useEffect(() => {
    setLoading(true)
    reload().finally(() => setLoading(false))
  }, [reload])

  const isToday = from === TODAY && to === TODAY

  return (
    <div className="mx-auto max-w-6xl p-6">
      <header className="mb-6">
        <h1 className="text-2xl font-bold text-slate-800">
          {isToday ? 'Llegadas de hoy' : 'Llegadas'}
        </h1>
        <div className="mt-3 flex flex-wrap items-end gap-3">
          <label className="text-xs font-medium text-slate-500">
            Desde
            <input
              type="date"
              value={from}
              max={to}
              onChange={(e) => setFrom(e.target.value)}
              className="mt-1 block rounded border border-slate-300 p-2 text-sm text-slate-700"
            />
          </label>
          <label className="text-xs font-medium text-slate-500">
            Hasta
            <input
              type="date"
              value={to}
              min={from}
              onChange={(e) => setTo(e.target.value)}
              className="mt-1 block rounded border border-slate-300 p-2 text-sm text-slate-700"
            />
          </label>
          <div className="flex gap-2 pb-0.5">
            <button
              type="button"
              onClick={() => {
                setFrom(TODAY)
                setTo(TODAY)
              }}
              className="rounded border border-slate-300 px-3 py-2 text-xs font-medium text-slate-600 hover:bg-slate-50"
            >
              Hoy
            </button>
            <button
              type="button"
              onClick={() => {
                setFrom(addDays(TODAY, 1))
                setTo(addDays(TODAY, 7))
              }}
              className="rounded border border-slate-300 px-3 py-2 text-xs font-medium text-slate-600 hover:bg-slate-50"
            >
              Próxima semana
            </button>
          </div>
        </div>
        <p className="mt-2 text-sm text-slate-500">
          {loading
            ? 'Cargando…'
            : `${arrivals.length} reserva(s) pendiente(s) de check-in`}
        </p>
      </header>

      {error && <p className="mb-4 text-red-600">Error: {error}</p>}
      {paymentBanner && (
        <p className="mb-4 rounded bg-amber-50 p-3 text-sm text-amber-800">
          {paymentBanner}
          <button
            type="button"
            onClick={() => setPaymentBanner(null)}
            className="ml-2 font-medium underline"
          >
            Entendido
          </button>
        </p>
      )}

      {arrivals.length === 0 ? (
        <p className="text-slate-400">No hay llegadas pendientes.</p>
      ) : (
        <div className="overflow-x-auto rounded border border-slate-200">
          <table className="w-full text-left text-sm">
            <thead className="bg-slate-100 text-slate-600">
              <tr>
                <th className="p-3">Hab.</th>
                <th className="p-3">Contacto</th>
                <th className="p-3">Titular</th>
                <th className="p-3">Tipo</th>
                <th className="p-3">Entrada</th>
                <th className="p-3">Salida</th>
                <th className="p-3">Canal</th>
                <th className="p-3">Anticipo</th>
                <th className="p-3"></th>
              </tr>
            </thead>
            <tbody>
              {arrivals.map((a) => (
                <tr key={a.reservationId} className="border-t border-slate-100">
                  <td className="p-3 font-semibold">{a.roomNumber}</td>
                  <td className="p-3">
                    {a.firstName} {a.lastName}
                    <span className="block text-xs text-slate-400">
                      {a.phone ?? a.email ?? '—'}
                    </span>
                  </td>
                  <td className="p-3">
                    {a.holderFirstName && a.holderLastName ? (
                      `${a.holderFirstName} ${a.holderLastName}`
                    ) : (
                      <span className="text-xs text-slate-400">
                        Titular: pendiente (se registra en el check-in)
                      </span>
                    )}
                  </td>
                  <td className="p-3">{a.roomType}</td>
                  <td className="p-3">{a.checkInDate}</td>
                  <td className="p-3">{a.checkOutDate}</td>
                  <td className="p-3">{a.method}</td>
                  <td className="p-3">
                    {a.anticipoTotalBs > 0 ? (
                      <span className="rounded bg-green-100 px-2 py-1 text-xs font-medium text-green-800">
                        Bs {a.anticipoTotalBs.toFixed(2)}
                      </span>
                    ) : (
                      <span className="text-xs text-slate-400">—</span>
                    )}
                  </td>
                  <td className="p-3">
                    <div className="flex flex-wrap justify-end gap-1">
                      {readOnly && <span className="text-xs text-slate-400">—</span>}
                      {!readOnly && (
                       <>
                      <button
                        type="button"
                        onClick={() => setSelected(a)}
                        className="rounded bg-brand-700 px-3 py-1 text-xs font-medium text-white hover:bg-brand-800"
                      >
                        Check-in
                      </button>
                      <button
                        type="button"
                        onClick={() => setAction({ arrival: a, kind: 'reschedule' })}
                        className="rounded border border-slate-300 px-3 py-1 text-xs font-medium text-slate-600 hover:bg-slate-50"
                      >
                        Reprogramar
                      </button>
                      <button
                        type="button"
                        onClick={() => setAction({ arrival: a, kind: 'cancel' })}
                        className="rounded border border-red-300 px-3 py-1 text-xs font-medium text-red-600 hover:bg-red-50"
                      >
                        Cancelar
                      </button>
                       </>
                      )}
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {selected && (
        <CheckInModal
          arrival={selected}
          role={role}
          onClose={() => setSelected(null)}
          onDone={(banner) => {
            void reload()
            setSelected(null)
            if (banner) setPaymentBanner(banner)
          }}
        />
      )}

      {action && (
        <ReservationActionModal
          arrival={action.arrival}
          kind={action.kind}
          onClose={() => setAction(null)}
          onDone={() => {
            void reload()
            setAction(null)
          }}
        />
      )}
    </div>
  )
}
