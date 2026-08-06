import { useEffect, useRef, useState } from 'react'
import { X } from 'lucide-react'
import { PrintButton } from '../../components/ui'
import type { Room } from '../../domain/rooms/room'
import type { Folio } from '../../domain/folios/folio'
import {
  walkInCheckIn,
  checkOutRoom,
  setRoomStatus,
  overrideReservationRate,
} from '../../services/checkin'
import { fetchFolio, addFolioCharge } from '../../services/folio'
import { fetchAssignableStaff, createTask } from '../../services/tasks'
import type { AssignableStaff } from '../../domain/tasks/task'
import { fetchPaymentMethods } from '../../services/payments'
import type { PaymentMethod } from '../../domain/payments/paymentMethod'
import type { ReceivableAccount } from '../../domain/receivables/receivable'
import { listReceivableAccounts } from '../../services/receivables'
import { COUNTRIES } from '../../shared/data/countries'
import { TRAVEL_PURPOSES } from '../../shared/data/travelPurposes'
import type { UserRole } from '../../domain/auth/profile'
import { canEditRate as canEditRateGate } from '../../domain/auth/rateGates'
import type { CompanionGuest } from '../../services/arrivals'
import { CompanionFields } from '../checkin/CompanionFields'
import type { StayGuest } from '../../domain/stays/stayGuest'
import { guestFullName } from '../../domain/stays/stayGuest'
import { fetchStayGuests, addGuestsToStay } from '../../services/stayGuests'
import type { StaySegment } from '../../domain/stays/staySegment'
import { segmentNights, segmentTotalBs } from '../../domain/stays/staySegment'
import { fetchStaySegments, extendStay, changeRoom } from '../../services/staySegments'
import { fetchRooms } from '../../services/rooms'
import type { PaymentProof } from '../../domain/payments/paymentProof'
import {
  EMPTY_PAYMENT_PROOF,
  paymentProofError,
  proofForMethod,
} from '../../domain/payments/paymentProof'
import { PaymentProofFields } from '../payments/PaymentProofFields'
import type { MixedPayment } from '../../domain/payments/mixedPayment'
import {
  EMPTY_MIXED_PAYMENT,
  isMixed,
  mixedPaymentError,
} from '../../domain/payments/mixedPayment'
import { MixedPaymentFields } from '../payments/MixedPaymentFields'

interface Props {
  room: Room
  role?: UserRole | null
  onClose: () => void
  onDone: () => void // recargar el tablero tras una acción
}

export function RoomPanel({ room, role, onClose, onDone }: Props) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)

  // Estado del formulario de walk-in
  const [firstName, setFirstName] = useState('')
  const [lastName, setLastName] = useState('')
  const [document, setDocument] = useState('')
  const [email, setEmail] = useState('')
  const [birthDate, setBirthDate] = useState('')
  const [countryCode, setCountryCode] = useState('')
  const [city, setCity] = useState('')
  const [wantsOffers, setWantsOffers] = useState(false)
  const [originCity, setOriginCity] = useState('')
  const [travelPurpose, setTravelPurpose] = useState('')
  const [occupation, setOccupation] = useState('')
  const [transportMeans, setTransportMeans] = useState('')
  const [nights, setNights] = useState(1)
  const [typeId, setTypeId] = useState(room.defaultType?.id ?? '')

  // Acompañantes (perfil completo de los demás huéspedes de la habitación).
  // El walk-in no fija la cantidad de antemano: se agregan a mano, con tope
  // = max_occupancy del tipo elegido menos el titular.
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
  const [companions, setCompanions] = useState<CompanionGuest[]>([])
  function updateCompanion(index: number, patch: Partial<CompanionGuest>) {
    setCompanions((prev) => prev.map((g, i) => (i === index ? { ...g, ...patch } : g)))
  }

  // Tarifa editable al check-in (root/reception), con justificación
  // obligatoria cuando difiere de la tarifa del tipo elegido — misma
  // regla que "Editar tarifa" post-check-in (ver más abajo).
  const selectedType = room.typeOptions.find((t) => t.id === typeId) ?? room.defaultType
  const defaultRateBs = selectedType?.basePriceBs ?? 0
  // La tarifa NO se precarga ni se muestra el precio de lista: en temporada
  // baja se vende más barato y en alta más caro, así que el precio del tipo
  // casi nunca es el que se cobra. Recepción lo escribe en cada check-in.
  // El precio de lista sigue existiendo por detrás como referencia para el
  // workflow de aprobación de descuentos (>20% pide justificación).
  const [checkInRate, setCheckInRate] = useState('')
  const [checkInRateReason, setCheckInRateReason] = useState('')
  const checkInRateNum = Number(checkInRate)
  const checkInRateMissing = checkInRate.trim() === '' || !(checkInRateNum > 0)
  // Sólo un descuento fuerte pide motivo. Escribir 380 en vez de 420 es la
  // operación normal del hotel, no una excepción que haya que justificar.
  const DEEP_DISCOUNT_PCT = 20
  const checkInDeepDiscount =
    defaultRateBs > 0 &&
    !checkInRateMissing &&
    (defaultRateBs - checkInRateNum) / defaultRateBs > DEEP_DISCOUNT_PCT / 100

  // Huéspedes de la estadía en curso (titular + acompañantes) y alta de
  // huéspedes nuevos mid-stay: el caso real es la simple que se vende a un
  // hombre y a los dos días llega su esposa. El incremento se cobra como
  // línea del folio (ver add_guests_to_stay), no como cambio de tarifa.
  const [stayGuests, setStayGuests] = useState<StayGuest[]>([])
  const [addGuestOpen, setAddGuestOpen] = useState(false)
  const [newGuests, setNewGuests] = useState<CompanionGuest[]>([])
  const [extraCharge, setExtraCharge] = useState('')
  const [extraChargeDesc, setExtraChargeDesc] = useState('')

  // Tramos de la estadía: cuántas noches en qué habitación y a qué tarifa.
  // Es lo que permite extender noches y mudar al huésped sin perder el
  // registro de lo que ya se cobró.
  const [segments, setSegments] = useState<StaySegment[]>([])
  const [stayAction, setStayAction] = useState<'extend' | 'move' | null>(null)
  const [newCheckOut, setNewCheckOut] = useState('')
  const [stayRate, setStayRate] = useState('')
  const [stayReason, setStayReason] = useState('')
  const [moveRooms, setMoveRooms] = useState<Room[]>([])
  const [moveRoomId, setMoveRoomId] = useState('')
  const [moveTypeId, setMoveTypeId] = useState('')
  const [moveFrom, setMoveFrom] = useState(new Date().toISOString().slice(0, 10))

  // Folio (solo si la habitación está ocupada)
  const [folio, setFolio] = useState<Folio | null>(null)
  const folioRef = useRef<HTMLDivElement>(null)
  const [chargeDesc, setChargeDesc] = useState('')
  const [chargeAmount, setChargeAmount] = useState('')
  const [paymentMethod, setPaymentMethod] = useState('EFECTIVO')
  const [paymentMethods, setPaymentMethods] = useState<PaymentMethod[]>([])
  const [receivableAccounts, setReceivableAccounts] = useState<ReceivableAccount[]>([])
  const [receivableAccountId, setReceivableAccountId] = useState('')
  const [proof, setProof] = useState<PaymentProof>(EMPTY_PAYMENT_PROOF)
  const [mixed, setMixed] = useState<MixedPayment>(EMPTY_MIXED_PAYMENT)
  const checkOutTotal = folio?.totalBs ?? 0
  // En MIXTO el respaldo pertenece a la parte electrónica, así que el
  // error se evalúa contra ese medio, no contra 'MIXTO'.
  const proofError = isMixed(paymentMethod)
    ? mixedPaymentError(checkOutTotal, mixed, proof)
    : paymentProofError(paymentMethod, proof)

  // Edición de tarifa (root/reception), con justificación obligatoria
  const [rateEditOpen, setRateEditOpen] = useState(false)
  const [newRate, setNewRate] = useState('')
  const [rateReason, setRateReason] = useState('')
  const canEditRate = canEditRateGate(role)


  // Asignación de mucama (solo si la habitación está por limpiar)
  const [staff, setStaff] = useState<AssignableStaff[]>([])
  const [staffId, setStaffId] = useState('')

  const isOccupied = room.operationalStatus === 'occupied'
  const isDirty = room.operationalStatus === 'dirty'

  useEffect(() => {
    if (isOccupied) {
      fetchFolio(room.id)
        .then((f) => {
          setFolio(f)
          if (f) return fetchStaySegments(f.reservationId).then(setSegments)
        })
        .catch((e: Error) => setError(e.message))
      fetchStayGuests(room.id)
        .then(setStayGuests)
        .catch((e: Error) => setError(e.message))
    }
  }, [room.id, isOccupied])

  useEffect(() => {
    setCheckInRate('')
    setCheckInRateReason('')
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [typeId, room.id])

  useEffect(() => {
    if (isDirty) {
      fetchAssignableStaff()
        .then(setStaff)
        .catch((e: Error) => setError(e.message))
    }
  }, [isDirty])

  useEffect(() => {
    if (isOccupied) {
      fetchPaymentMethods()
        .then(setPaymentMethods)
        .catch((e: Error) => setError(e.message))
      listReceivableAccounts(true)
        .then(setReceivableAccounts)
        .catch((e: Error) => setError(e.message))
    }
  }, [isOccupied])

  function handleAssignCleaning() {
    if (!staffId) {
      setError('Elegí a quién asignar la limpieza')
      return
    }
    const assignee = staff.find((s) => s.personId === staffId)?.fullName ?? ''
    run(() =>
      createTask({
        taskType: 'cleaning',
        assignedToName: assignee,
        notes: `Limpieza habitación ${room.roomNumber}`,
      }),
    )
  }

  async function reloadFolio() {
    const f = await fetchFolio(room.id)
    setFolio(f)
    setSegments(f ? await fetchStaySegments(f.reservationId) : [])
  }

  // Habitaciones a las que se puede mudar: libres o por limpiar, distintas
  // de la actual. La disponibilidad por FECHAS la revalida change_room.
  function openMove() {
    setStayAction('move')
    setStayRate('')
    setStayReason('')
    fetchRooms()
      .then((all) =>
        setMoveRooms(
          all.filter(
            (r) =>
              r.id !== room.id &&
              (r.operationalStatus === 'available' || r.operationalStatus === 'dirty'),
          ),
        ),
      )
      .catch((e: Error) => setError(e.message))
  }

  async function handleExtend() {
    const rate = Number(stayRate)
    if (!newCheckOut) {
      setError('Elegí la nueva fecha de salida')
      return
    }
    if (!(rate > 0)) {
      setError('Ingresá la tarifa por noche de las noches nuevas')
      return
    }
    setBusy(true)
    setError(null)
    setMessage(null)
    try {
      const total = await extendStay(room.id, newCheckOut, rate, stayReason)
      setMessage(`Estadía extendida hasta ${newCheckOut}. Total: ${total.toFixed(2)} Bs`)
      setStayAction(null)
      setNewCheckOut('')
      setStayRate('')
      setStayReason('')
      await reloadFolio()
      onDone()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  async function handleChangeRoom() {
    const rate = Number(stayRate)
    if (!moveRoomId || !moveTypeId) {
      setError('Elegí la habitación destino')
      return
    }
    if (!(rate > 0)) {
      setError('Ingresá la tarifa por noche de la habitación nueva')
      return
    }
    setBusy(true)
    setError(null)
    setMessage(null)
    try {
      const total = await changeRoom({
        roomId: room.id,
        newRoomId: moveRoomId,
        newRoomTypeId: moveTypeId,
        rateBs: rate,
        fromDate: moveFrom || null,
        reason: stayReason,
      })
      setMessage(`Huésped mudado. Total de la estadía: ${total.toFixed(2)} Bs`)
      setStayAction(null)
      onDone()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  async function handleAddCharge() {
    const amount = Number(chargeAmount)
    if (!chargeDesc.trim() || !(amount >= 0)) {
      setError('Descripción y monto válido son obligatorios')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await addFolioCharge(room.id, chargeDesc.trim(), amount)
      setChargeDesc('')
      setChargeAmount('')
      await reloadFolio()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  function updateNewGuest(index: number, patch: Partial<CompanionGuest>) {
    setNewGuests((prev) => prev.map((g, i) => (i === index ? { ...g, ...patch } : g)))
  }

  async function handleAddGuests() {
    const extra = Number(extraCharge || 0)
    if (!(extra >= 0)) {
      setError('El incremento debe ser un monto válido')
      return
    }
    setBusy(true)
    setError(null)
    setMessage(null)
    try {
      const total = await addGuestsToStay(room.id, newGuests, extra, extraChargeDesc)
      setMessage(
        extra > 0
          ? `Huésped(es) agregado(s). Ocupación: ${total}. Se cargó ${extra.toFixed(2)} Bs al folio.`
          : `Huésped(es) agregado(s). Ocupación: ${total}.`,
      )
      setNewGuests([])
      setExtraCharge('')
      setExtraChargeDesc('')
      setAddGuestOpen(false)
      setStayGuests(await fetchStayGuests(room.id))
      await reloadFolio()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  async function handleOverrideRate() {
    if (!folio) return
    const rate = Number(newRate)
    setBusy(true)
    setError(null)
    setMessage(null)
    try {
      const pending = await overrideReservationRate(folio.reservationId, rate, rateReason)
      setMessage(pending ?? 'Tarifa actualizada.')
      setNewRate('')
      setRateReason('')
      setRateEditOpen(false)
      await reloadFolio()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  async function run(action: () => Promise<void | string | null>) {
    setBusy(true)
    setError(null)
    setMessage(null)
    try {
      const result = await action()
      if (typeof result === 'string') setMessage(result)
      onDone()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  function handleCheckIn() {
    if (!firstName.trim() || !lastName.trim()) {
      setError('Nombre y apellido son obligatorios')
      return
    }
    if (checkInRateMissing) {
      setError('Ingresá la tarifa por noche')
      return
    }
    if (checkInDeepDiscount && !checkInRateReason.trim()) {
      setError(
        `La justificación es obligatoria para un descuento mayor al ${DEEP_DISCOUNT_PCT}%`,
      )
      return
    }
    run(() =>
      walkInCheckIn({
        roomId: room.id,
        roomTypeId: typeId,
        firstName: firstName.trim(),
        lastName: lastName.trim(),
        document: document.trim(),
        email: email.trim(),
        birthDate,
        countryCode: countryCode.trim().toUpperCase(),
        city: city.trim(),
        wantsOffers,
        nights,
        rateBs: checkInRateNum,
        rateReason: checkInRateReason.trim() || 'Tarifa de temporada',
        originCity: originCity.trim(),
        travelPurpose: travelPurpose.trim(),
        occupation: occupation.trim(),
        transportMeans: transportMeans.trim(),
        companions,
      }),
    )
  }

  async function handleCheckOut() {
    if (paymentMethod === 'CTAS_POR_COBRAR' && !receivableAccountId) {
      setError('Elegí la cuenta por cobrar a la que se factura')
      return
    }
    if (proofError) {
      setError(proofError)
      return
    }
    setBusy(true)
    setError(null)
    try {
      const mixedOn = isMixed(paymentMethod)
      const total = await checkOutRoom(
        room.id,
        paymentMethod,
        // El respaldo se resuelve contra el medio que realmente lo pide:
        // con MIXTO, el de la parte electrónica.
        proofForMethod(mixedOn ? mixed.nonCashMethod : paymentMethod, proof),
        paymentMethod === 'CTAS_POR_COBRAR' ? receivableAccountId : null,
        mixedOn
          ? {
              cashBs: Number(mixed.cashBs),
              nonCashBs: Number(mixed.nonCashBs),
              nonCashMethod: mixed.nonCashMethod,
            }
          : null,
      )
      setMessage(
        mixedOn
          ? `Check-out realizado. ${Number(mixed.cashBs).toFixed(2)} Bs en efectivo y ` +
            `${Number(mixed.nonCashBs).toFixed(2)} Bs por ${mixed.nonCashMethod.toLowerCase()}, ` +
            'ambos registrados en caja.'
          : `Check-out realizado. Total cobrado: ${total.toFixed(2)} Bs`,
      )
      setProof(EMPTY_PAYMENT_PROOF)
      setMixed(EMPTY_MIXED_PAYMENT)
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
            Habitación {room.roomNumber}
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
          Piso {room.floor} · {room.zone} · {room.defaultType?.name}
        </p>

        {error && (
          <p className="mb-3 rounded bg-red-50 p-2 text-sm text-red-700">
            {error}
          </p>
        )}
        {message && (
          <p className="mb-3 rounded bg-green-50 p-2 text-sm text-green-700">
            {message}
          </p>
        )}

        {/* DISPONIBLE → check-in */}
        {room.operationalStatus === 'available' && (
          <div className="space-y-3">
            <h3 className="font-semibold text-slate-700">Check-in (walk-in)</h3>

            {room.typeOptions.length > 1 && (
              <label className="block text-sm">
                <span className="text-slate-600">Vender como</span>
                <select
                  value={typeId}
                  onChange={(e) => setTypeId(e.target.value)}
                  className="mt-1 w-full rounded border border-slate-300 p-2"
                >
                  {room.typeOptions.map((t) => (
                    <option key={t.id} value={t.id}>
                      {t.name} — hasta {t.maxOccupancy} personas
                    </option>
                  ))}
                </select>
              </label>
            )}

            <input
              placeholder="Nombre"
              value={firstName}
              onChange={(e) => setFirstName(e.target.value)}
              className="w-full rounded border border-slate-300 p-2"
            />
            <input
              placeholder="Apellido"
              value={lastName}
              onChange={(e) => setLastName(e.target.value)}
              className="w-full rounded border border-slate-300 p-2"
            />
            <input
              placeholder="Documento / Pasaporte"
              value={document}
              onChange={(e) => setDocument(e.target.value)}
              className="w-full rounded border border-slate-300 p-2"
            />
            <input
              type="email"
              placeholder="Correo (opcional)"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
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
            <label className="block text-sm">
              <span className="text-slate-600">Noches</span>
              <input
                type="number"
                min={1}
                value={nights}
                onChange={(e) => setNights(Math.max(1, Number(e.target.value)))}
                className="mt-1 w-full rounded border border-slate-300 p-2"
              />
            </label>

            <div className="space-y-2 rounded border border-slate-200 p-3">
              <label className="block text-sm">
                <span className="mb-1 block text-xs font-medium text-slate-500">
                  Tarifa por noche (Bs) — obligatoria
                </span>
                <input
                  type="number"
                  min={0}
                  step="0.01"
                  value={checkInRate}
                  onChange={(e) => setCheckInRate(e.target.value)}
                  placeholder="Precio acordado con el huésped"
                  className="w-full rounded border border-slate-300 p-2 text-sm"
                />
              </label>
              {checkInDeepDiscount && (
                <label className="block text-sm">
                  <span className="mb-1 block text-xs font-medium text-slate-500">
                    Justificación (obligatoria: descuento mayor al {DEEP_DISCOUNT_PCT}%)
                  </span>
                  <textarea
                    value={checkInRateReason}
                    onChange={(e) => setCheckInRateReason(e.target.value)}
                    placeholder="Ej. Última cuádruple disponible, se vende a precio de matrimonial"
                    className="w-full rounded border border-slate-300 p-2 text-sm"
                    rows={2}
                  />
                </label>
              )}
            </div>

            <div className="space-y-3 border-t border-slate-200 pt-3">
              <div className="flex items-center justify-between">
                <span className="text-xs font-medium text-slate-600">
                  Acompañantes {companions.length > 0 && `(${companions.length})`}
                </span>
                {companions.length < (selectedType?.maxOccupancy ?? 1) - 1 && (
                  <button
                    type="button"
                    onClick={() => setCompanions((prev) => [...prev, emptyCompanion()])}
                    className="text-xs font-medium text-brand-700 hover:underline"
                  >
                    + Agregar huésped
                  </button>
                )}
              </div>
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

            <button
              type="button"
              disabled={
                busy ||
                checkInRateMissing ||
                (checkInDeepDiscount && !checkInRateReason.trim())
              }
              onClick={handleCheckIn}
              className="w-full rounded bg-brand-700 py-2 font-medium text-white hover:bg-brand-800 disabled:opacity-50"
            >
              {busy ? 'Procesando…' : 'Confirmar check-in'}
            </button>

            <button
              type="button"
              disabled={busy}
              onClick={() => run(() => setRoomStatus(room.id, 'maintenance'))}
              className="w-full rounded border border-slate-300 py-2 text-sm text-slate-600 hover:bg-slate-50"
            >
              Poner en mantenimiento
            </button>
          </div>
        )}

        {/* OCUPADA → folio + consumos + check-out */}
        {isOccupied && (
          <div className="space-y-4">
            {/* Huéspedes en la habitación — arriba del folio, porque es lo
                primero que recepción necesita saber al abrir el panel. */}
            <div>
              <div className="mb-2 flex items-center justify-between">
                <h3 className="font-semibold text-slate-700">
                  Huéspedes {stayGuests.length > 0 && `(${stayGuests.length})`}
                </h3>
                {!addGuestOpen && (
                  <button
                    type="button"
                    onClick={() => {
                      setAddGuestOpen(true)
                      setNewGuests([emptyCompanion()])
                    }}
                    className="text-xs font-medium text-brand-700 hover:underline"
                  >
                    + Agregar huésped
                  </button>
                )}
              </div>

              {stayGuests.length === 0 ? (
                <p className="text-sm text-slate-400">Cargando huéspedes…</p>
              ) : (
                <ul className="rounded border border-slate-200 text-sm">
                  {stayGuests.map((g) => (
                    <li
                      key={g.personId}
                      className="flex items-center justify-between border-b border-slate-100 px-3 py-2 last:border-b-0"
                    >
                      <span className="text-slate-700">{guestFullName(g)}</span>
                      <span className="text-xs text-slate-400">
                        {g.isHolder ? 'Titular' : g.isMinor ? 'Menor' : 'Acompañante'}
                      </span>
                    </li>
                  ))}
                </ul>
              )}

              {addGuestOpen && (
                <div className="mt-2 space-y-3 rounded border border-slate-200 p-3">
                  <p className="text-xs text-slate-500">
                    El incremento se carga como un consumo del folio, así queda
                    visible por separado en el folio impreso.
                  </p>

                  {newGuests.map((g, i) => (
                    <div key={i} className="space-y-2 rounded border border-slate-200 p-3">
                      <div className="flex items-center justify-between">
                        <p className="text-xs font-semibold text-slate-500">
                          Nuevo huésped {i + 1}
                        </p>
                        {newGuests.length > 1 && (
                          <button
                            type="button"
                            onClick={() =>
                              setNewGuests((prev) => prev.filter((_, j) => j !== i))
                            }
                            className="text-xs text-slate-400 hover:text-red-600"
                          >
                            Quitar
                          </button>
                        )}
                      </div>
                      <CompanionFields
                        companion={g}
                        onChange={(patch) => updateNewGuest(i, patch)}
                      />
                    </div>
                  ))}

                  <button
                    type="button"
                    onClick={() => setNewGuests((prev) => [...prev, emptyCompanion()])}
                    className="text-xs font-medium text-brand-700 hover:underline"
                  >
                    + Otro huésped
                  </button>

                  <label className="block text-sm">
                    <span className="mb-1 block text-xs font-medium text-slate-500">
                      Incremento a cobrar (Bs) — 0 si no se cobra
                    </span>
                    <input
                      type="number"
                      min={0}
                      step="0.01"
                      value={extraCharge}
                      onChange={(e) => setExtraCharge(e.target.value)}
                      placeholder="0.00"
                      className="w-full rounded border border-slate-300 p-2 text-sm"
                    />
                  </label>
                  <label className="block text-sm">
                    <span className="mb-1 block text-xs font-medium text-slate-500">
                      Descripción del cargo (opcional)
                    </span>
                    <input
                      value={extraChargeDesc}
                      onChange={(e) => setExtraChargeDesc(e.target.value)}
                      placeholder="Ej. Huésped adicional — 2 noches"
                      className="w-full rounded border border-slate-300 p-2 text-sm"
                    />
                  </label>

                  <div className="flex gap-2">
                    <button
                      type="button"
                      disabled={
                        busy ||
                        !newGuests.some(
                          (g) => g.firstName.trim() !== '' && g.lastName.trim() !== '',
                        )
                      }
                      onClick={handleAddGuests}
                      className="w-1/2 rounded bg-brand-700 py-2 text-sm font-medium text-white hover:bg-brand-800 disabled:opacity-50"
                    >
                      {busy ? 'Procesando…' : 'Agregar'}
                    </button>
                    <button
                      type="button"
                      onClick={() => {
                        setAddGuestOpen(false)
                        setNewGuests([])
                        setExtraCharge('')
                        setExtraChargeDesc('')
                      }}
                      className="w-1/2 rounded border border-slate-300 py-2 text-sm text-slate-600 hover:bg-slate-50"
                    >
                      Cancelar
                    </button>
                  </div>
                </div>
              )}
            </div>

            <div>
              <div className="mb-2 flex items-center justify-between">
                <h3 className="font-semibold text-slate-700">Folio</h3>
                {folio && (
                  <PrintButton
                    targetRef={folioRef}
                    title={`Folio Hab. ${room.roomNumber}`}
                    label="Imprimir"
                    className="!px-2 !py-1 text-xs"
                  />
                )}
              </div>
              {folio ? (
                <div ref={folioRef} className="rounded border border-slate-200 p-3 text-sm">
                  <div className="mb-2 border-b border-slate-200 pb-2 font-semibold text-slate-800">
                    Folio · Hab. {room.roomNumber}
                    {stayGuests.length > 0 && (
                      <span className="block text-xs font-normal text-slate-500">
                        {stayGuests.map(guestFullName).join(' · ')}
                      </span>
                    )}
                  </div>
                  {segments.length > 1 ? (
                    segments.map((sg) => (
                      <div key={sg.id} className="flex justify-between text-slate-600">
                        <span>
                          Hab. {sg.roomNumber} ({sg.roomType}) · {segmentNights(sg)} noche(s) ×{' '}
                          {sg.rateBs.toFixed(2)}
                          <span className="block text-xs text-slate-400">
                            {sg.startDate} → {sg.endDate}
                          </span>
                        </span>
                        <span>{segmentTotalBs(sg).toFixed(2)} Bs</span>
                      </div>
                    ))
                  ) : (
                    <div className="flex justify-between text-slate-600">
                      <span>Habitación ({folio.roomType})</span>
                      <span>{folio.roomChargeBs.toFixed(2)} Bs</span>
                    </div>
                  )}
                  {folio.charges.map((c) => (
                    <div key={c.id} className="flex justify-between text-slate-600">
                      <span>{c.description}</span>
                      <span>{c.amountBs.toFixed(2)} Bs</span>
                    </div>
                  ))}
                  <div className="mt-2 flex justify-between border-t border-slate-200 pt-2 font-bold text-slate-800">
                    <span>Total</span>
                    <span>{folio.totalBs.toFixed(2)} Bs</span>
                  </div>
                </div>
              ) : (
                <p className="text-sm text-slate-400">Cargando folio…</p>
              )}

              {canEditRate && folio && (
                <div className="mt-2">
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
                      <div className="flex gap-2">
                        <button
                          type="button"
                          disabled={busy || !newRate.trim() || !rateReason.trim()}
                          onClick={handleOverrideRate}
                          className="w-1/2 rounded bg-brand-700 py-2 text-sm font-medium text-white hover:bg-brand-800 disabled:opacity-50"
                        >
                          Guardar tarifa
                        </button>
                        <button
                          type="button"
                          onClick={() => {
                            setRateEditOpen(false)
                            setNewRate('')
                            setRateReason('')
                          }}
                          className="w-1/2 rounded border border-slate-300 py-2 text-sm text-slate-600 hover:bg-slate-50"
                        >
                          Cancelar
                        </button>
                      </div>
                    </div>
                  )}
                </div>
              )}
            </div>

            <div className="space-y-2 border-t border-slate-200 pt-3">
              <div className="flex items-center justify-between">
                <h4 className="text-sm font-medium text-slate-600">Estadía</h4>
                {stayAction === null && (
                  <div className="flex gap-2">
                    <button
                      type="button"
                      onClick={() => {
                        setStayAction('extend')
                        setNewCheckOut('')
                        setStayRate('')
                        setStayReason('')
                      }}
                      className="text-xs font-medium text-brand-700 hover:underline"
                    >
                      Extender noches
                    </button>
                    <button
                      type="button"
                      onClick={openMove}
                      className="text-xs font-medium text-brand-700 hover:underline"
                    >
                      Cambiar habitación
                    </button>
                  </div>
                )}
              </div>

              {stayAction === 'extend' && (
                <div className="space-y-2 rounded border border-slate-200 p-3">
                  <label className="block text-sm">
                    <span className="mb-1 block text-xs font-medium text-slate-500">
                      Nueva fecha de salida
                    </span>
                    <input
                      type="date"
                      value={newCheckOut}
                      onChange={(e) => setNewCheckOut(e.target.value)}
                      className="w-full rounded border border-slate-300 p-2 text-sm"
                    />
                  </label>
                  <label className="block text-sm">
                    <span className="mb-1 block text-xs font-medium text-slate-500">
                      Tarifa por noche de las noches nuevas (Bs)
                    </span>
                    <input
                      type="number"
                      min={0}
                      step="0.01"
                      value={stayRate}
                      onChange={(e) => setStayRate(e.target.value)}
                      placeholder="Precio acordado"
                      className="w-full rounded border border-slate-300 p-2 text-sm"
                    />
                  </label>
                  <input
                    value={stayReason}
                    onChange={(e) => setStayReason(e.target.value)}
                    placeholder="Motivo (opcional)"
                    className="w-full rounded border border-slate-300 p-2 text-sm"
                  />
                  <div className="flex gap-2">
                    <button
                      type="button"
                      disabled={busy || !newCheckOut || !(Number(stayRate) > 0)}
                      onClick={handleExtend}
                      className="w-1/2 rounded bg-brand-700 py-2 text-sm font-medium text-white hover:bg-brand-800 disabled:opacity-50"
                    >
                      {busy ? 'Procesando…' : 'Extender'}
                    </button>
                    <button
                      type="button"
                      onClick={() => setStayAction(null)}
                      className="w-1/2 rounded border border-slate-300 py-2 text-sm text-slate-600 hover:bg-slate-50"
                    >
                      Cancelar
                    </button>
                  </div>
                </div>
              )}

              {stayAction === 'move' && (
                <div className="space-y-2 rounded border border-slate-200 p-3">
                  <label className="block text-sm">
                    <span className="mb-1 block text-xs font-medium text-slate-500">
                      Habitación destino
                    </span>
                    <select
                      value={moveRoomId}
                      onChange={(e) => {
                        setMoveRoomId(e.target.value)
                        const r = moveRooms.find((x) => x.id === e.target.value)
                        setMoveTypeId(r?.defaultType?.id ?? '')
                      }}
                      className="w-full rounded border border-slate-300 p-2 text-sm"
                    >
                      <option value="">Elegí una habitación…</option>
                      {moveRooms.map((r) => (
                        <option key={r.id} value={r.id}>
                          Hab. {r.roomNumber} · {r.defaultType?.name ?? 'Sin tipo'}
                          {r.operationalStatus === 'dirty' ? ' (por limpiar)' : ''}
                        </option>
                      ))}
                    </select>
                  </label>
                  {(moveRooms.find((r) => r.id === moveRoomId)?.typeOptions.length ?? 0) > 1 && (
                    <label className="block text-sm">
                      <span className="mb-1 block text-xs font-medium text-slate-500">
                        Vender como
                      </span>
                      <select
                        value={moveTypeId}
                        onChange={(e) => setMoveTypeId(e.target.value)}
                        className="w-full rounded border border-slate-300 p-2 text-sm"
                      >
                        {moveRooms
                          .find((r) => r.id === moveRoomId)!
                          .typeOptions.map((t) => (
                            <option key={t.id} value={t.id}>
                              {t.name} — hasta {t.maxOccupancy} personas
                            </option>
                          ))}
                      </select>
                    </label>
                  )}
                  <label className="block text-sm">
                    <span className="mb-1 block text-xs font-medium text-slate-500">
                      Se muda desde
                    </span>
                    <input
                      type="date"
                      value={moveFrom}
                      onChange={(e) => setMoveFrom(e.target.value)}
                      className="w-full rounded border border-slate-300 p-2 text-sm"
                    />
                  </label>
                  <label className="block text-sm">
                    <span className="mb-1 block text-xs font-medium text-slate-500">
                      Tarifa por noche en la habitación nueva (Bs)
                    </span>
                    <input
                      type="number"
                      min={0}
                      step="0.01"
                      value={stayRate}
                      onChange={(e) => setStayRate(e.target.value)}
                      placeholder="Precio acordado"
                      className="w-full rounded border border-slate-300 p-2 text-sm"
                    />
                  </label>
                  <input
                    value={stayReason}
                    onChange={(e) => setStayReason(e.target.value)}
                    placeholder="Motivo del cambio (opcional)"
                    className="w-full rounded border border-slate-300 p-2 text-sm"
                  />
                  <p className="text-xs text-slate-500">
                    Las noches ya dormidas en la {room.roomNumber} se conservan en el
                    folio con su tarifa.
                  </p>
                  <div className="flex gap-2">
                    <button
                      type="button"
                      disabled={busy || !moveRoomId || !(Number(stayRate) > 0)}
                      onClick={handleChangeRoom}
                      className="w-1/2 rounded bg-brand-700 py-2 text-sm font-medium text-white hover:bg-brand-800 disabled:opacity-50"
                    >
                      {busy ? 'Procesando…' : 'Mudar huésped'}
                    </button>
                    <button
                      type="button"
                      onClick={() => setStayAction(null)}
                      className="w-1/2 rounded border border-slate-300 py-2 text-sm text-slate-600 hover:bg-slate-50"
                    >
                      Cancelar
                    </button>
                  </div>
                </div>
              )}
            </div>

            <div className="space-y-2">
              <h4 className="text-sm font-medium text-slate-600">
                Agregar consumo
              </h4>
              <input
                placeholder="Descripción (Restaurante, Cafetería, Spa…)"
                value={chargeDesc}
                onChange={(e) => setChargeDesc(e.target.value)}
                className="w-full rounded border border-slate-300 p-2"
              />
              <div className="flex gap-2">
                <input
                  type="number"
                  min={0}
                  step="0.01"
                  placeholder="Monto Bs"
                  value={chargeAmount}
                  onChange={(e) => setChargeAmount(e.target.value)}
                  className="w-2/3 rounded border border-slate-300 p-2"
                />
                <button
                  type="button"
                  disabled={busy}
                  onClick={handleAddCharge}
                  className="w-1/3 rounded bg-slate-700 py-2 text-sm font-medium text-white hover:bg-slate-800 disabled:opacity-50"
                >
                  Agregar
                </button>
              </div>
            </div>

            <label className="block text-sm">
              <span className="mb-1 block text-xs font-medium text-slate-500">
                Forma de pago
              </span>
              <select
                value={paymentMethod}
                onChange={(e) => setPaymentMethod(e.target.value)}
                className="w-full rounded border border-slate-300 p-2"
              >
                {paymentMethods.map((m) => (
                  <option key={m.code} value={m.code}>{m.label}</option>
                ))}
              </select>
            </label>
            {paymentMethod === 'CTAS_POR_COBRAR' && (
              <label className="block text-sm">
                <span className="mb-1 block text-xs font-medium text-slate-500">
                  Cuenta por cobrar
                </span>
                <select
                  value={receivableAccountId}
                  onChange={(e) => setReceivableAccountId(e.target.value)}
                  className="w-full rounded border border-slate-300 p-2"
                >
                  <option value="">Elegí una cuenta…</option>
                  {receivableAccounts.map((a) => (
                    <option key={a.id} value={a.id}>
                      {a.name}
                    </option>
                  ))}
                </select>
                {receivableAccounts.length === 0 && (
                  <span className="mt-1 block text-xs text-amber-700">
                    No hay cuentas. Creá una en "Cuentas por cobrar".
                  </span>
                )}
              </label>
            )}
            {paymentMethod === 'EFECTIVO' && (
              <p className="text-xs text-slate-400">
                El efectivo se registra en la caja (debe estar abierta).
              </p>
            )}

            {isMixed(paymentMethod) ? (
              <MixedPaymentFields
                total={checkOutTotal}
                split={mixed}
                proof={proof}
                onSplitChange={(patch) => setMixed((m) => ({ ...m, ...patch }))}
                onProofChange={(patch) => setProof((p) => ({ ...p, ...patch }))}
              />
            ) : (
              <PaymentProofFields
                method={paymentMethod}
                proof={proof}
                onChange={(patch) => setProof((p) => ({ ...p, ...patch }))}
              />
            )}

            <button
              type="button"
              disabled={busy || proofError !== null}
              onClick={handleCheckOut}
              className="w-full rounded bg-amber-600 py-2 font-medium text-white hover:bg-amber-700 disabled:opacity-50"
            >
              {busy ? 'Procesando…' : 'Check-out'}
            </button>
          </div>
        )}

        {/* POR LIMPIAR → asignar mucama + marcar limpia */}
        {isDirty && (
          <div className="space-y-3">
            <div className="space-y-2">
              <h3 className="font-semibold text-slate-700">Asignar limpieza</h3>
              <select
                value={staffId}
                onChange={(e) => setStaffId(e.target.value)}
                className="w-full rounded border border-slate-300 p-2 text-sm"
              >
                <option value="">Elegí una mucama…</option>
                {staff.map((s) => (
                  <option key={s.personId} value={s.personId}>
                    {s.fullName} — {s.jobTitle}
                  </option>
                ))}
              </select>
              <button
                type="button"
                disabled={busy}
                onClick={handleAssignCleaning}
                className="w-full rounded bg-slate-700 py-2 font-medium text-white hover:bg-slate-800 disabled:opacity-50"
              >
                {busy ? 'Procesando…' : 'Asignar mucama'}
              </button>
            </div>

            <button
              type="button"
              disabled={busy}
              onClick={() => run(() => setRoomStatus(room.id, 'available'))}
              className="w-full rounded bg-green-600 py-2 font-medium text-white hover:bg-green-700 disabled:opacity-50"
            >
              Marcar como limpia
            </button>
          </div>
        )}

        {/* MANTENIMIENTO → volver a disponible */}
        {room.operationalStatus === 'maintenance' && (
          <button
            type="button"
            disabled={busy}
            onClick={() => run(() => setRoomStatus(room.id, 'available'))}
            className="w-full rounded bg-green-600 py-2 font-medium text-white hover:bg-green-700 disabled:opacity-50"
          >
            Marcar como disponible
          </button>
        )}
      </aside>
    </div>
  )
}
