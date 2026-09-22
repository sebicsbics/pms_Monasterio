import { useEffect, useState } from 'react'
import type { AvailableRoom, ReservationMethod } from '../../domain/reservations/availability'
import { RESERVATION_METHODS } from '../../domain/reservations/availability'
import {
  searchAvailableRooms,
  createBulkReservation,
  type BulkReservationResult,
  type RoomOccupantInput,
} from '../../services/reservations'
import { occupantCountWarning } from '../../domain/reservations/occupants'
import { occupancyReasonParam } from '../../domain/reservations/occupancyReason'
import { computeContractPreview } from '../../domain/reservations/groupContractPreview'
import { fittingRoomTypes, selectDefaultRoomType } from '../../domain/reservations/roomTypeSelection'
import type { RoomType } from '../../domain/rooms/room'
import { findSimilarAccountName } from '../../domain/receivables/accountNameSimilarity'
import { listReceivableAccounts } from '../../services/receivables'
import type { ReceivableAccount, ReceivableAccountKind } from '../../domain/receivables/receivable'
import type { UserRole } from '../../domain/auth/profile'

// Rol gate para la modalidad de pago institucional (decisión #339): sólo
// root/reception_admin ven la opción 'client'.
function canManagePayerMode(role?: UserRole | null): boolean {
  return role === 'root' || role === 'reception_admin'
}

// Precarga desde la grilla de Disponibilidad: fechas del bloque + números
// de habitación a preseleccionar.
export interface BulkReservationPrefill {
  checkIn: string
  checkOut: string
  roomNumbers: string[]
}

const METHOD_LABELS: Record<ReservationMethod, string> = {
  phone: 'Llamada',
  whatsapp: 'WhatsApp',
  email: 'Correo',
  web: 'Página web',
  'walk-in': 'Presencial',
}
const METHODS = RESERVATION_METHODS.map((value) => ({ value, label: METHOD_LABELS[value] }))

// Reserva en grupo: mismas fechas para muchas habitaciones, un contacto
// organizador. Los datos de cada huésped se completan en el check-in.
export function BulkReservation({
  prefill,
  role,
}: {
  prefill?: BulkReservationPrefill | null
  role?: UserRole | null
}) {
  const [checkIn, setCheckIn] = useState('')
  const [checkOut, setCheckOut] = useState('')
  const [results, setResults] = useState<AvailableRoom[] | null>(null)
  const [selected, setSelected] = useState<Set<string>>(new Set())
  // Personas por habitación (roomId -> cantidad). Se siembra con la
  // capacidad del tipo al seleccionar, pero se puede exceder: cuando el
  // hotel se llena se habilitan camas extras.
  const [guestsByRoom, setGuestsByRoom] = useState<Record<string, number>>({})
  // Huéspedes precargados por habitación (opcional). El primero cargado es
  // el titular; el resto son acompañantes. El organizador (contacto del
  // grupo, más abajo) NUNCA se agrega acá automáticamente.
  const [occupantsByRoom, setOccupantsByRoom] = useState<Record<string, RoomOccupantInput[]>>({})
  // Motivo obligatorio POR habitación cuando guestsByRoom supera el
  // max_occupancy del tipo — ver domain/reservations/occupancyReason.ts.
  // Sin motivo, esa habitación puntual queda en `failed` (el resto de la
  // reserva grupal no se ve afectada).
  const [occupancyReasonByRoom, setOccupancyReasonByRoom] = useState<Record<string, string>>({})
  // Tipo elegido a mano por el usuario cuando más de una ficha de
  // room_type_options alcanza para la cantidad de huéspedes cargada
  // (DEFECT 2: una misma habitación física puede venderse a varios
  // precios/capacidades — ej. Simple Estándar 1px vs. Matrimonial 2px
  // sobre la habitación 7). Si no hay elección manual (o dejó de estar
  // entre las opciones vigentes), se recalcula el default con
  // selectDefaultRoomType en cada render.
  const [roomTypeByRoom, setRoomTypeByRoom] = useState<Record<string, string>>({})

  const [firstName, setFirstName] = useState('')
  const [lastName, setLastName] = useState('')
  const [phone, setPhone] = useState('')
  const [email, setEmail] = useState('')
  const [method, setMethod] = useState('phone')
  // Precio pactado POR HABITACIÓN (sdd/per-room-rate-in-bulk): antes había
  // un único campo "Tarifa" a nivel de toda la reserva que se aplicaba a
  // TODAS las habitaciones por igual, aplanando precios distintos (ej.
  // habitación 6 a 480 y habitación 7 a 350 quedaban ambas en 400 con un
  // solo valor ingresado). Ahora cada habitación tiene su propio precio,
  // opcional — vacío significa "precio de lista de esa habitación", sin
  // cambio de tarifa.
  const [priceByRoom, setPriceByRoom] = useState<Record<string, string>>({})
  // Justificación ÚNICA para toda el alta (decisión de usuario): se pide
  // una sola vez cuando AL MENOS UNA habitación tiene un precio pactado
  // distinto de su propio precio de lista, y se graba igual en la
  // auditoría de cada habitación que difiera.
  const [priceReason, setPriceReason] = useState('')

  // Reserva institucional (stage 6, group-billing) — decisión #339.
  const [payerMode, setPayerMode] = useState<'each_stay' | 'client'>('each_stay')
  const [rateMode, setRateMode] = useState<'room' | 'person'>('room')
  const [agreedUnitPriceBs, setAgreedUnitPriceBs] = useState('')
  const [courtesyByRoom, setCourtesyByRoom] = useState<Record<string, boolean>>({})
  const [courtesyReasonByRoom, setCourtesyReasonByRoom] = useState<Record<string, string>>({})

  // Enlace a cuenta por cobrar (R10.1–R10.5), a nivel de grupo (no por
  // habitación) — no es un llamado aparte, viaja como p_new_account_* dentro
  // de create_bulk_reservation (atomicidad garantizada por
  // _resolve_receivable_account).
  const [accounts, setAccounts] = useState<ReceivableAccount[]>([])
  const [linkMode, setLinkMode] = useState<'existing' | 'new'>('existing')
  const [receivableAccountId, setReceivableAccountId] = useState('')
  const [newAccountName, setNewAccountName] = useState('')
  const [newAccountKind, setNewAccountKind] = useState<ReceivableAccountKind>('empresa')
  const [newAccountContact, setNewAccountContact] = useState('')
  const [newAccountNotes, setNewAccountNotes] = useState('')

  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [result, setResult] = useState<BulkReservationResult | null>(null)

  // Precarga desde Disponibilidad: fija fechas, busca y preselecciona las
  // habitaciones del bloque que sigan disponibles.
  useEffect(() => {
    if (!prefill) return
    setCheckIn(prefill.checkIn)
    setCheckOut(prefill.checkOut)
    setError(null)
    setResult(null)
    setBusy(true)
    searchAvailableRooms(prefill.checkIn, prefill.checkOut, 1)
      .then((rooms) => {
        setResults(rooms)
        const wanted = new Set(prefill.roomNumbers)
        setSelected(new Set(rooms.filter((r) => wanted.has(r.roomNumber)).map((r) => r.roomId)))
      })
      .catch((e: Error) => setError(e.message))
      .finally(() => setBusy(false))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [prefill])

  // Cuentas por cobrar disponibles para "Enlazar a cuenta" (R10.1).
  useEffect(() => {
    if (payerMode !== 'client') return
    let active = true
    listReceivableAccounts(true)
      .then((list) => {
        if (active) setAccounts(list)
      })
      .catch(() => {})
    return () => {
      active = false
    }
  }, [payerMode])

  const similarAccountName =
    payerMode === 'client' && linkMode === 'new' && newAccountName.trim()
      ? findSimilarAccountName(newAccountName, accounts.map((a) => a.name))
      : null

  async function handleSearch() {
    setError(null)
    setResult(null)
    setSelected(new Set())
    if (!checkIn || !checkOut) {
      setError('Elegí fecha de entrada y salida')
      return
    }
    if (checkOut <= checkIn) {
      setError('La salida debe ser posterior a la entrada')
      return
    }
    setBusy(true)
    try {
      // pax = 1: la búsqueda muestra TODAS las habitaciones libres y la
      // ocupación se decide por habitación en el paso 2. Filtrar acá por
      // el total del grupo escondería justamente las chicas que el grupo
      // igual necesita.
      setResults(await searchAvailableRooms(checkIn, checkOut, 1))
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  // Tipo efectivo para una habitación dada la cantidad de huéspedes
  // actual (DEFECT 2): el elegido a mano si sigue siendo una opción
  // válida de esa habitación, si no el default (el más barato que
  // alcanza — ver domain/reservations/roomTypeSelection).
  const effectiveRoomType = (room: AvailableRoom, guests: number): RoomType | null => {
    const manual = roomTypeByRoom[room.roomId]
    if (manual) {
      const found = room.suitableTypes.find((t) => t.id === manual)
      if (found) return found
    }
    return selectDefaultRoomType(room.suitableTypes, guests)
  }

  const capacityOf = (roomId: string) =>
    results?.find((r) => r.roomId === roomId)?.suitableTypes[0]?.maxOccupancy ?? 1

  function toggle(roomId: string) {
    setSelected((prev) => {
      const next = new Set(prev)
      if (next.has(roomId)) next.delete(roomId)
      else {
        next.add(roomId)
        setGuestsByRoom((g) => (g[roomId] ? g : { ...g, [roomId]: capacityOf(roomId) }))
      }
      return next
    })
  }

  function selectAll() {
    const all = results ?? []
    setSelected(new Set(all.map((r) => r.roomId)))
    setGuestsByRoom((g) => {
      const next = { ...g }
      for (const r of all) {
        if (!next[r.roomId]) next[r.roomId] = r.suitableTypes[0]?.maxOccupancy ?? 1
      }
      return next
    })
  }

  const totalPax = [...selected].reduce((sum, id) => sum + (guestsByRoom[id] ?? 1), 0)

  function addOccupant(roomId: string) {
    setOccupantsByRoom((prev) => ({
      ...prev,
      [roomId]: [...(prev[roomId] ?? []), { firstName: '', lastName: '', document: '' }],
    }))
  }

  function updateOccupant(roomId: string, index: number, patch: Partial<RoomOccupantInput>) {
    setOccupantsByRoom((prev) => ({
      ...prev,
      [roomId]: (prev[roomId] ?? []).map((o, i) => (i === index ? { ...o, ...patch } : o)),
    }))
  }

  function removeOccupant(roomId: string, index: number) {
    setOccupantsByRoom((prev) => ({
      ...prev,
      [roomId]: (prev[roomId] ?? []).filter((_, i) => i !== index),
    }))
  }

  // Vuelve la pantalla a cero: hasta ahora, elegida una fecha, la única
  // forma de empezar de nuevo era recargar el navegador entero.
  function handleReset() {
    setCheckIn('')
    setCheckOut('')
    setResults(null)
    setSelected(new Set())
    setGuestsByRoom({})
    setOccupantsByRoom({})
    setOccupancyReasonByRoom({})
    setRoomTypeByRoom({})
    setFirstName('')
    setLastName('')
    setPhone('')
    setEmail('')
    setMethod('phone')
    setPriceByRoom({})
    setPriceReason('')
    setPayerMode('each_stay')
    setRateMode('room')
    setAgreedUnitPriceBs('')
    setCourtesyByRoom({})
    setCourtesyReasonByRoom({})
    setLinkMode('existing')
    setReceivableAccountId('')
    setNewAccountName('')
    setNewAccountKind('empresa')
    setNewAccountContact('')
    setNewAccountNotes('')
    setError(null)
    setResult(null)
  }

  const nights =
    checkIn && checkOut
      ? Math.round((new Date(checkOut).getTime() - new Date(checkIn).getTime()) / 86400000)
      : 0

  // Precio pactado efectivo de una habitación: el que cargó el usuario en
  // el paso 2, o si lo dejó vacío, el precio de lista de su tipo efectivo
  // (sin cambio de tarifa para esa habitación).
  const agreedPriceOf = (roomId: string): number => {
    const entered = priceByRoom[roomId]?.trim()
    if (entered) return Number(entered)
    const room = results?.find((r) => r.roomId === roomId)
    if (!room) return 0
    const guests = guestsByRoom[roomId] ?? 1
    return effectiveRoomType(room, guests)?.basePriceBs ?? 0
  }

  // Al menos una habitación seleccionada tiene un precio pactado distinto
  // de su PROPIO precio de lista -> la justificación (única para toda el
  // alta) pasa a ser obligatoria.
  const anyRoomPriceDeviates = [...selected].some((roomId) => {
    const entered = priceByRoom[roomId]?.trim()
    if (!entered) return false
    const room = results?.find((r) => r.roomId === roomId)
    if (!room) return false
    const guests = guestsByRoom[roomId] ?? 1
    const listPrice = effectiveRoomType(room, guests)?.basePriceBs ?? 0
    return Number(entered) !== listPrice
  })

  const contractPreview =
    payerMode === 'client'
      ? computeContractPreview({
          rooms: [...selected].map((roomId) => ({
            isCourtesy: courtesyByRoom[roomId] ?? false,
            numGuests: guestsByRoom[roomId] ?? 0,
            roomTotalBs: agreedPriceOf(roomId) * Math.max(nights, 0),
          })),
          rateMode,
          nights: Math.max(nights, 0),
          agreedUnitPriceBs: agreedUnitPriceBs.trim() ? Number(agreedUnitPriceBs) : null,
        })
      : null

  async function handleCreate() {
    if (!results) return
    const chosen = results.filter((r) => selected.has(r.roomId))
    if (chosen.length === 0) {
      setError('Seleccioná al menos una habitación')
      return
    }
    if (!firstName.trim() || !lastName.trim()) {
      setError('Nombre y apellido del contacto son obligatorios')
      return
    }
    if (!phone.trim() && !email.trim()) {
      setError('Cargá al menos un contacto: celular o correo')
      return
    }
    if (anyRoomPriceDeviates && !priceReason.trim()) {
      setError('La justificación es obligatoria si cambiás el precio pactado de alguna habitación')
      return
    }
    if (
      payerMode === 'client' &&
      chosen.some((r) => courtesyByRoom[r.roomId] && !(courtesyReasonByRoom[r.roomId] ?? '').trim())
    ) {
      setError('La justificación de cortesía es obligatoria')
      return
    }
    if (payerMode === 'client' && linkMode === 'existing' && !receivableAccountId) {
      setError('Elegí una cuenta existente o cambiá a Crear cuenta nueva')
      return
    }
    if (payerMode === 'client' && linkMode === 'new' && !newAccountName.trim()) {
      setError('El nombre de la cuenta nueva es obligatorio')
      return
    }
    setBusy(true)
    setError(null)
    setResult(null)
    try {
      const res = await createBulkReservation({
        rooms: chosen.map((r) => {
          // DEFECT 1: una sola cantidad de huéspedes por habitación, la
          // misma que se envía y la que decide si hace falta motivo de
          // sobre-ocupación — antes había dos fuentes (guestsByRoom vs.
          // contractGuestsByRoom) que podían desincronizarse.
          const guests = guestsByRoom[r.roomId] ?? 1
          const type = effectiveRoomType(r, guests)
          return {
            roomId: r.roomId,
            roomTypeId: type?.id ?? '',
            numGuests: guests,
            occupants: (occupantsByRoom[r.roomId] ?? []).filter(
              (o) => o.firstName.trim() !== '' && o.lastName.trim() !== '',
            ),
            ...occupancyReasonParam(
              guests,
              type?.maxOccupancy ?? null,
              occupancyReasonByRoom[r.roomId] ?? '',
            ),
            isCourtesy: payerMode === 'client' ? courtesyByRoom[r.roomId] ?? false : false,
            courtesyReason:
              payerMode === 'client' && courtesyByRoom[r.roomId]
                ? (courtesyReasonByRoom[r.roomId] ?? '').trim()
                : null,
            // Precio pactado POR HABITACIÓN (sdd/per-room-rate-in-bulk):
            // vacío significa "precio de lista de esa habitación", nunca
            // se aplana con el de otras habitaciones del mismo grupo.
            rateBs: priceByRoom[r.roomId]?.trim() ? Number(priceByRoom[r.roomId]) : null,
          }
        }),
        firstName: firstName.trim(),
        lastName: lastName.trim(),
        phone: phone.trim(),
        email: email.trim(),
        checkIn,
        checkOut,
        method,
        reason: priceReason.trim() || null,
        payerMode,
        rateMode: payerMode === 'client' ? rateMode : undefined,
        agreedUnitPriceBs:
          payerMode === 'client' && rateMode === 'person' && agreedUnitPriceBs.trim()
            ? Number(agreedUnitPriceBs)
            : null,
        receivableAccountId:
          payerMode === 'client' && linkMode === 'existing' ? receivableAccountId : null,
        newAccountName:
          payerMode === 'client' && linkMode === 'new' ? newAccountName.trim() : null,
        newAccountKind: payerMode === 'client' && linkMode === 'new' ? newAccountKind : null,
        newAccountContact:
          payerMode === 'client' && linkMode === 'new'
            ? newAccountContact.trim() || null
            : null,
        newAccountNotes:
          payerMode === 'client' && linkMode === 'new' ? newAccountNotes.trim() || null : null,
      })
      setResult(res)
      // Sacar de la lista las que se crearon, dejar las fallidas visibles.
      const createdRoomIds = new Set(chosen.map((r) => r.roomId))
      const failedRoomIds = new Set(res.failed.map((f) => f.roomId))
      setResults((results ?? []).filter((r) => !createdRoomIds.has(r.roomId) || failedRoomIds.has(r.roomId)))
      setSelected(new Set())
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  const roomNumberOf = (roomId: string) =>
    results?.find((r) => r.roomId === roomId)?.roomNumber ?? roomId

  return (
    <div className="space-y-6">
      {error && (
        <p className="rounded bg-red-50 p-2 text-sm text-red-700">{error}</p>
      )}
      {result && (
        <div className="rounded bg-green-50 p-3 text-sm text-green-800">
          <p className="font-medium">
            {result.created.length} reserva(s) creada(s)
            {' · '}
            {checkIn} → {checkOut}
          </p>
          {result.failed.length > 0 && (
            <div className="mt-1 text-amber-800">
              <p>No se pudieron crear {result.failed.length}:</p>
              {/* DEFECT 3(a): la RPC ya devuelve el motivo REAL por
                  habitación (sqlerrm) — mostrarlo tal cual en vez de
                  inventar "probablemente se ocuparon", que muchas veces
                  es directamente falso. */}
              <ul className="list-disc pl-4">
                {result.failed.map((f) => (
                  <li key={f.roomId}>
                    Hab. {roomNumberOf(f.roomId)}: {f.error}
                  </li>
                ))}
              </ul>
            </div>
          )}
        </div>
      )}

      {/* Paso 1: fechas */}
      <section className="rounded border border-slate-200 p-4">
        <h2 className="mb-3 font-semibold text-slate-700">1 · Fechas del grupo</h2>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-4">
          <label className="text-sm">
            <span className="text-slate-600">Entrada</span>
            <input type="date" value={checkIn} onChange={(e) => setCheckIn(e.target.value)}
              className="mt-1 w-full rounded border border-slate-300 p-2" />
          </label>
          <label className="text-sm">
            <span className="text-slate-600">Salida</span>
            <input type="date" value={checkOut} onChange={(e) => setCheckOut(e.target.value)}
              className="mt-1 w-full rounded border border-slate-300 p-2" />
          </label>
          <div className="flex items-end">
            <button type="button" disabled={busy} onClick={handleSearch}
              className="w-full rounded bg-brand-700 py-2 font-medium text-white hover:bg-brand-800 disabled:opacity-50">
              Buscar
            </button>
          </div>
          <div className="flex items-end">
            <button type="button" onClick={handleReset}
              className="w-full rounded border border-slate-300 py-2 text-sm font-medium text-slate-600 hover:bg-slate-50">
              Empezar de nuevo
            </button>
          </div>
        </div>
      </section>

      {/* Paso 2: elegir habitaciones */}
      {results && (
        <section className="rounded border border-slate-200 p-4">
          <div className="mb-3 flex items-center justify-between">
            <h2 className="font-semibold text-slate-700">
              2 · Elegí habitaciones ({selected.size}/{results.length})
              {selected.size > 0 && (
                <span className="ml-2 text-sm font-normal text-slate-500">
                  · {totalPax} huésped(es) en total
                </span>
              )}
            </h2>
            <div className="flex gap-2 text-xs">
              <button type="button" onClick={selectAll}
                className="rounded border border-slate-300 px-2 py-1 text-slate-600 hover:bg-slate-50">
                Seleccionar todas
              </button>
              <button type="button" onClick={() => setSelected(new Set())}
                className="rounded border border-slate-300 px-2 py-1 text-slate-600 hover:bg-slate-50">
                Ninguna
              </button>
            </div>
          </div>
          {results.length === 0 ? (
            <p className="text-sm text-slate-400">No hay habitaciones disponibles para esas fechas.</p>
          ) : (
            <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
              {results.map((room) => {
                const on = selected.has(room.roomId)
                // capacity/guests con el valor "de referencia" (más
                // barato) hasta que se sepa cuántos van; una vez elegida
                // la habitación, se usa el tipo EFECTIVO para esa
                // cantidad de huéspedes (DEFECT 2).
                const referenceCapacity = room.suitableTypes[0]?.maxOccupancy ?? 1
                const guests = guestsByRoom[room.roomId] ?? referenceCapacity
                const type = effectiveRoomType(room, guests)
                const capacity = type?.maxOccupancy ?? 1
                const overCapacity = on && guests > capacity
                const fitting = fittingRoomTypes(room.suitableTypes, guests)
                const occupants = occupantsByRoom[room.roomId] ?? []
                const countWarning = on ? occupantCountWarning(guests, occupants.length) : null
                return (
                  <div key={room.roomId}
                    className={`rounded border p-2 text-sm ${
                      on ? 'border-blue-500 bg-blue-50' : 'border-slate-300'
                    }`}>
                    <div className="flex items-center gap-2">
                      <button type="button" onClick={() => toggle(room.roomId)}
                        className="flex flex-1 items-start gap-2 text-left">
                        <input type="checkbox" checked={on} readOnly className="mt-1" />
                        <span>
                          <span className="font-bold">Hab. {room.roomNumber}</span>
                          <span className="block text-xs text-slate-500">
                            {type ? `${type.name} · hasta ${capacity} · ${type.basePriceBs} Bs` : 'Sin tipo'}
                          </span>
                        </span>
                      </button>
                      {on && (
                        <label className="shrink-0 text-right text-xs text-slate-500">
                          Personas
                          <input type="number" min={1} value={guests}
                            onChange={(e) =>
                              setGuestsByRoom((g) => ({
                                ...g,
                                [room.roomId]: Math.max(1, Number(e.target.value)),
                              }))
                            }
                            className={`mt-1 block w-16 rounded border p-1 text-center text-sm ${
                              overCapacity ? 'border-amber-400 bg-amber-50' : 'border-slate-300'
                            }`} />
                        </label>
                      )}
                    </div>
                    {on && (
                      // Precio pactado de ESTA habitación (sdd/per-room-
                      // rate-in-bulk): reemplaza el viejo campo "Tarifa"
                      // a nivel de toda la reserva -- cada habitación
                      // tiene su propio precio, opcional. Vacío = precio
                      // de lista de esta habitación (placeholder).
                      <label className="mt-2 block text-xs text-slate-500">
                        Precio pactado (Bs/noche, opcional)
                        <input
                          type="number"
                          min={0}
                          placeholder={String(type?.basePriceBs ?? '')}
                          value={priceByRoom[room.roomId] ?? ''}
                          onChange={(e) =>
                            setPriceByRoom((p) => ({ ...p, [room.roomId]: e.target.value }))
                          }
                          className="mt-1 w-full rounded border border-slate-300 p-1 text-xs"
                        />
                      </label>
                    )}
                    {/* DEFECT 2: más de una ficha de tipo alcanza para
                        esta cantidad de huéspedes (ej. Simple 1px vs.
                        Matrimonial 2px sobre la misma habitación física)
                        — dejamos elegir, mostrando el precio de cada
                        una, en vez de tomar la más barata a ciegas. */}
                    {on && fitting.length > 1 && (
                      <label className="mt-2 block text-xs text-slate-500">
                        Tipo/tarifa
                        <select
                          value={type?.id ?? ''}
                          onChange={(e) =>
                            setRoomTypeByRoom((r) => ({ ...r, [room.roomId]: e.target.value }))
                          }
                          className="mt-1 w-full rounded border border-slate-300 p-1 text-xs"
                        >
                          {fitting.map((t) => (
                            <option key={t.id} value={t.id}>
                              {t.name} · hasta {t.maxOccupancy} · {t.basePriceBs} Bs
                            </option>
                          ))}
                        </select>
                      </label>
                    )}
                    {on && (
                      <div className="mt-2 space-y-2 border-t border-slate-200 pt-2">
                        <div className="flex items-center justify-between">
                          <span className="text-xs font-medium text-slate-500">
                            Cargar huéspedes (opcional) — el primero es el titular
                          </span>
                          <button type="button" onClick={() => addOccupant(room.roomId)}
                            className="text-xs font-medium text-brand-700 hover:underline">
                            + Agregar huésped
                          </button>
                        </div>
                        {occupants.map((o, i) => (
                          <div key={i} className="flex items-center gap-1">
                            <span className="w-4 shrink-0 text-xs text-slate-400">
                              {i === 0 ? 'T' : i + 1}
                            </span>
                            <input placeholder="Nombre" value={o.firstName}
                              onChange={(e) => updateOccupant(room.roomId, i, { firstName: e.target.value })}
                              className="w-1/3 rounded border border-slate-300 p-1 text-xs" />
                            <input placeholder="Apellido" value={o.lastName}
                              onChange={(e) => updateOccupant(room.roomId, i, { lastName: e.target.value })}
                              className="w-1/3 rounded border border-slate-300 p-1 text-xs" />
                            <input placeholder="Doc. (opcional)" value={o.document ?? ''}
                              onChange={(e) => updateOccupant(room.roomId, i, { document: e.target.value })}
                              className="w-1/4 rounded border border-slate-300 p-1 text-xs" />
                            <button type="button" onClick={() => removeOccupant(room.roomId, i)}
                              className="shrink-0 text-xs text-slate-400 hover:text-red-600">
                              Quitar
                            </button>
                          </div>
                        ))}
                        {occupants.length === 0 && (
                          <p className="text-xs text-slate-400">
                            Sin huéspedes precargados: el titular se registra en el check-in.
                          </p>
                        )}
                        {countWarning && (
                          <p className="rounded bg-amber-50 p-1 text-xs text-amber-800">
                            {countWarning}
                          </p>
                        )}
                        {overCapacity && (
                          <div className="space-y-1 rounded border border-amber-300 bg-amber-50 p-2">
                            <p className="text-xs font-medium text-amber-800">
                              Supera la capacidad ({capacity}). Indicá un motivo para exceder el
                              límite — sin motivo esta habitación no se creará.
                            </p>
                            <input
                              placeholder="Motivo (ej. cuna adicional)"
                              value={occupancyReasonByRoom[room.roomId] ?? ''}
                              onChange={(e) =>
                                setOccupancyReasonByRoom((r) => ({
                                  ...r,
                                  [room.roomId]: e.target.value,
                                }))
                              }
                              className="w-full rounded border border-slate-300 p-1 text-xs"
                            />
                          </div>
                        )}
                      </div>
                    )}
                  </div>
                )
              })}
            </div>
          )}
          {[...selected].some((id) => {
            const room = results?.find((r) => r.roomId === id)
            if (!room) return false
            const guests = guestsByRoom[id] ?? 1
            return guests > (effectiveRoomType(room, guests)?.maxOccupancy ?? capacityOf(id))
          }) && (
            <p className="mt-2 rounded bg-amber-50 p-2 text-xs text-amber-800">
              Hay habitaciones por encima de su capacidad: se asume cama extra.
            </p>
          )}
        </section>
      )}

      {/* Paso 3: contacto del grupo */}
      {results && results.length > 0 && (
        <section className="rounded border border-slate-200 p-4">
          <h2 className="mb-3 font-semibold text-slate-700">3 · Contacto del grupo</h2>
          <p className="mb-3 text-xs text-slate-500">
            El organizador es el contacto del grupo (a quién avisar), no un
            huésped: si también se hospeda, cargalo como huésped en alguna
            habitación en el paso 2.
          </p>
          <div className="space-y-3">
            <div className="flex gap-2">
              <input placeholder="Nombre" value={firstName} onChange={(e) => setFirstName(e.target.value)}
                className="w-1/2 rounded border border-slate-300 p-2" />
              <input placeholder="Apellido" value={lastName} onChange={(e) => setLastName(e.target.value)}
                className="w-1/2 rounded border border-slate-300 p-2" />
            </div>
            <div className="flex gap-2">
              <input placeholder="Celular" value={phone} onChange={(e) => setPhone(e.target.value)}
                className="w-1/2 rounded border border-slate-300 p-2" />
              <input type="email" placeholder="Correo" value={email} onChange={(e) => setEmail(e.target.value)}
                className="w-1/2 rounded border border-slate-300 p-2" />
            </div>
            <label className="block text-sm">
              <span className="text-slate-600">Canal de la reserva</span>
              <select value={method} onChange={(e) => setMethod(e.target.value)}
                className="mt-1 w-full rounded border border-slate-300 p-2">
                {METHODS.map((m) => (
                  <option key={m.value} value={m.value}>{m.label}</option>
                ))}
              </select>
            </label>
            {anyRoomPriceDeviates && (
              <label className="block text-sm">
                <span className="text-slate-600">Motivo del precio pactado</span>
                <input placeholder="Motivo del descuento o precio negociado" value={priceReason}
                  onChange={(e) => setPriceReason(e.target.value)}
                  className="mt-1 w-full rounded border border-slate-300 p-2" />
              </label>
            )}
            <p className="text-xs text-slate-500">
              El precio pactado (si lo ponés) se carga por habitación en el paso 2. El
              perfil de cada huésped se completa en el check-in.
            </p>
            {canManagePayerMode(role) && (
              <div className="space-y-3 rounded border border-slate-200 p-3">
                <label className="block text-sm">
                  <span className="text-slate-600">Modalidad de pago</span>
                  <select
                    value={payerMode}
                    onChange={(e) => setPayerMode(e.target.value as 'each_stay' | 'client')}
                    className="mt-1 w-full rounded border border-slate-300 p-2"
                  >
                    <option value="each_stay">Cada habitación paga la suya</option>
                    <option value="client">Institución/agencia paga el paquete</option>
                  </select>
                </label>
                {payerMode === 'client' && (
                  <>
                    <label className="block text-sm">
                      <span className="text-slate-600">Modalidad de tarifa</span>
                      <select
                        value={rateMode}
                        onChange={(e) => setRateMode(e.target.value as 'room' | 'person')}
                        className="mt-1 w-full rounded border border-slate-300 p-2"
                      >
                        <option value="room">Tarifa de lista/editable</option>
                        <option value="person">Precio pactado por persona/noche</option>
                      </select>
                    </label>
                    {rateMode === 'person' && (
                      <label className="block text-sm">
                        <span className="text-slate-600">
                          Precio pactado por persona/noche (Bs)
                        </span>
                        <input
                          type="number"
                          min={0}
                          value={agreedUnitPriceBs}
                          onChange={(e) => setAgreedUnitPriceBs(e.target.value)}
                          className="mt-1 w-full rounded border border-slate-300 p-2"
                        />
                      </label>
                    )}
                    <div className="space-y-2 rounded border border-slate-200 p-3">
                      <p className="text-sm font-medium text-slate-700">Enlazar a cuenta</p>
                      <div className="flex gap-4 text-sm">
                        <label className="flex items-center gap-1">
                          <input
                            type="radio"
                            name="link-mode"
                            checked={linkMode === 'existing'}
                            onChange={() => setLinkMode('existing')}
                          />
                          Existente
                        </label>
                        <label className="flex items-center gap-1">
                          <input
                            type="radio"
                            name="link-mode"
                            checked={linkMode === 'new'}
                            onChange={() => setLinkMode('new')}
                          />
                          Crear
                        </label>
                      </div>
                      {linkMode === 'existing' && (
                        <label className="block text-sm">
                          <span className="text-slate-600">Cuenta por cobrar</span>
                          <select
                            value={receivableAccountId}
                            onChange={(e) => setReceivableAccountId(e.target.value)}
                            className="mt-1 w-full rounded border border-slate-300 p-2"
                          >
                            <option value="">Seleccioná una cuenta</option>
                            {accounts.map((a) => (
                              <option key={a.id} value={a.id}>
                                {a.name}
                              </option>
                            ))}
                          </select>
                        </label>
                      )}
                      {linkMode === 'new' && (
                        <div className="space-y-2">
                          <label className="block text-sm">
                            <span className="text-slate-600">Nombre de la cuenta</span>
                            <input
                              value={newAccountName}
                              onChange={(e) => setNewAccountName(e.target.value)}
                              className="mt-1 w-full rounded border border-slate-300 p-2"
                            />
                          </label>
                          {similarAccountName && (
                            <p className="rounded bg-amber-50 p-2 text-xs text-amber-800">
                              Ya existe una cuenta con un nombre parecido: "{similarAccountName}".
                              Podés continuar si son distintas.
                            </p>
                          )}
                          <label className="block text-sm">
                            <span className="text-slate-600">Tipo</span>
                            <select
                              value={newAccountKind}
                              onChange={(e) =>
                                setNewAccountKind(e.target.value as ReceivableAccountKind)
                              }
                              className="mt-1 w-full rounded border border-slate-300 p-2"
                            >
                              <option value="empresa">Empresa</option>
                              <option value="agencia">Agencia</option>
                              <option value="persona">Persona</option>
                            </select>
                          </label>
                          <input
                            placeholder="Contacto (opcional)"
                            value={newAccountContact}
                            onChange={(e) => setNewAccountContact(e.target.value)}
                            className="w-full rounded border border-slate-300 p-2 text-sm"
                          />
                          <input
                            placeholder="Notas (opcional)"
                            value={newAccountNotes}
                            onChange={(e) => setNewAccountNotes(e.target.value)}
                            className="w-full rounded border border-slate-300 p-2 text-sm"
                          />
                        </div>
                      )}
                    </div>
                    <div className="space-y-2">
                      {[...selected].map((roomId) => (
                        <div key={roomId} className="rounded border border-slate-200 p-2 text-sm">
                          <p className="mb-1 font-medium text-slate-600">
                            Hab. {roomNumberOf(roomId)}
                          </p>
                          {rateMode === 'person' && (
                            // DEFECT 1: MISMA fuente de verdad que "Personas"
                            // del paso 2 (guestsByRoom) — antes este campo
                            // tenía su propio estado (contractGuestsByRoom)
                            // que se enviaba al crear, mientras que el
                            // aviso de sobre-ocupación y el motivo miraban
                            // guestsByRoom: podían desincronizarse y la RPC
                            // terminaba pidiendo un motivo que la pantalla
                            // nunca ofreció.
                            <label className="block text-xs">
                              <span className="text-slate-500">Personas (contrato)</span>
                              <input
                                type="number"
                                min={1}
                                value={guestsByRoom[roomId] ?? 1}
                                onChange={(e) =>
                                  setGuestsByRoom((g) => ({
                                    ...g,
                                    [roomId]: Math.max(1, Number(e.target.value)),
                                  }))
                                }
                                className="mt-1 w-full rounded border border-slate-300 p-1"
                              />
                            </label>
                          )}
                          <label className="mt-1 flex items-center gap-2 text-xs text-slate-600">
                            <input
                              type="checkbox"
                              checked={courtesyByRoom[roomId] ?? false}
                              onChange={(e) =>
                                setCourtesyByRoom((c) => ({ ...c, [roomId]: e.target.checked }))
                              }
                            />
                            Cortesía (no se puede revertir después)
                          </label>
                          {courtesyByRoom[roomId] && (
                            <input
                              placeholder="Motivo de la cortesía (obligatorio)"
                              value={courtesyReasonByRoom[roomId] ?? ''}
                              onChange={(e) =>
                                setCourtesyReasonByRoom((r) => ({
                                  ...r,
                                  [roomId]: e.target.value,
                                }))
                              }
                              className="mt-1 w-full rounded border border-slate-300 p-1 text-xs"
                            />
                          )}
                        </div>
                      ))}
                    </div>
                    {contractPreview !== null && (
                      <p className="rounded bg-slate-50 p-2 text-sm font-medium text-slate-700">
                        Total del contrato: {contractPreview} Bs
                      </p>
                    )}
                  </>
                )}
              </div>
            )}
            <button type="button" disabled={busy || selected.size === 0} onClick={handleCreate}
              className="w-full rounded bg-green-600 py-2 font-medium text-white hover:bg-green-700 disabled:opacity-50">
              {busy ? 'Creando…' : `Crear ${selected.size} reserva(s)`}
            </button>
          </div>
        </section>
      )}
    </div>
  )
}
