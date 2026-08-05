import { useEffect, useState } from 'react'
import type { AvailableRoom, ReservationMethod } from '../../domain/reservations/availability'
import { RESERVATION_METHODS } from '../../domain/reservations/availability'
import {
  searchAvailableRooms,
  createBulkReservation,
  type BulkReservationResult,
} from '../../services/reservations'

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
export function BulkReservation({ prefill }: { prefill?: BulkReservationPrefill | null }) {
  const [checkIn, setCheckIn] = useState('')
  const [checkOut, setCheckOut] = useState('')
  const [results, setResults] = useState<AvailableRoom[] | null>(null)
  const [selected, setSelected] = useState<Set<string>>(new Set())
  // Personas por habitación (roomId -> cantidad). Se siembra con la
  // capacidad del tipo al seleccionar, pero se puede exceder: cuando el
  // hotel se llena se habilitan camas extras.
  const [guestsByRoom, setGuestsByRoom] = useState<Record<string, number>>({})

  const [firstName, setFirstName] = useState('')
  const [lastName, setLastName] = useState('')
  const [phone, setPhone] = useState('')
  const [email, setEmail] = useState('')
  const [method, setMethod] = useState('phone')
  const [rateBs, setRateBs] = useState('')
  const [rateReason, setRateReason] = useState('')

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

  // Vuelve la pantalla a cero: hasta ahora, elegida una fecha, la única
  // forma de empezar de nuevo era recargar el navegador entero.
  function handleReset() {
    setCheckIn('')
    setCheckOut('')
    setResults(null)
    setSelected(new Set())
    setGuestsByRoom({})
    setFirstName('')
    setLastName('')
    setPhone('')
    setEmail('')
    setMethod('phone')
    setRateBs('')
    setRateReason('')
    setError(null)
    setResult(null)
  }

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
    if (rateBs.trim() && !rateReason.trim()) {
      setError('La justificación es obligatoria si cambiás la tarifa')
      return
    }
    setBusy(true)
    setError(null)
    setResult(null)
    try {
      const res = await createBulkReservation({
        rooms: chosen.map((r) => ({
          roomId: r.roomId,
          roomTypeId: r.suitableTypes[0]?.id ?? '',
          numGuests: guestsByRoom[r.roomId] ?? 1,
        })),
        firstName: firstName.trim(),
        lastName: lastName.trim(),
        phone: phone.trim(),
        email: email.trim(),
        checkIn,
        checkOut,
        method,
        rateBs: rateBs.trim() ? Number(rateBs) : null,
        reason: rateReason.trim() || null,
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
            <p className="mt-1 text-amber-800">
              No se pudieron crear {result.failed.length}: {' '}
              {result.failed.map((f) => `Hab. ${roomNumberOf(f.roomId)}`).join(', ')}{' '}
              (probablemente se ocuparon).
            </p>
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
                const type = room.suitableTypes[0]
                const on = selected.has(room.roomId)
                const capacity = type?.maxOccupancy ?? 1
                const guests = guestsByRoom[room.roomId] ?? capacity
                const overCapacity = on && guests > capacity
                return (
                  <div key={room.roomId}
                    className={`flex items-center gap-2 rounded border p-2 text-sm ${
                      on ? 'border-blue-500 bg-blue-50' : 'border-slate-300'
                    }`}>
                    <button type="button" onClick={() => toggle(room.roomId)}
                      className="flex flex-1 items-start gap-2 text-left">
                      <input type="checkbox" checked={on} readOnly className="mt-1" />
                      <span>
                        <span className="font-bold">Hab. {room.roomNumber}</span>
                        <span className="block text-xs text-slate-500">
                          {type ? `${type.name} · hasta ${capacity}` : 'Sin tipo'}
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
                )
              })}
            </div>
          )}
          {[...selected].some((id) => (guestsByRoom[id] ?? 1) > capacityOf(id)) && (
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
            <div className="flex gap-2">
              <label className="w-1/2 text-sm">
                <span className="text-slate-600">Tarifa (Bs/noche, opcional)</span>
                <input type="number" min={0} placeholder="Precio de lista" value={rateBs}
                  onChange={(e) => setRateBs(e.target.value)}
                  className="mt-1 w-full rounded border border-slate-300 p-2" />
              </label>
              <label className="w-1/2 text-sm">
                <span className="text-slate-600">Justificación (si cambia la tarifa)</span>
                <input placeholder="Motivo del descuento" value={rateReason}
                  onChange={(e) => setRateReason(e.target.value)}
                  className="mt-1 w-full rounded border border-slate-300 p-2" />
              </label>
            </div>
            <p className="text-xs text-slate-500">
              La tarifa (si la ponés) se aplica a todas las habitaciones del grupo. El
              perfil de cada huésped se completa en el check-in.
            </p>
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
