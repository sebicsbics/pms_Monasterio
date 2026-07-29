import { useEffect, useState } from 'react'
import type { AvailableRoom, ReservationMethod } from '../../domain/reservations/availability'
import { RESERVATION_METHODS } from '../../domain/reservations/availability'
import { searchAvailableRooms, createReservation } from '../../services/reservations'
import { fetchPendingForReservation } from '../../services/rateDiscountRequestsService'
import { BulkReservation } from './BulkReservation'

// Precarga que llega desde la grilla de Disponibilidad: fecha (1 noche) y
// habitación a preseleccionar.
export interface ReservationPrefill {
  checkIn: string
  checkOut: string
  roomNumber: string
}

const METHOD_LABELS: Record<ReservationMethod, string> = {
  phone: 'Llamada',
  whatsapp: 'WhatsApp',
  email: 'Correo',
  web: 'Página web',
  'walk-in': 'Presencial',
}

const METHODS = RESERVATION_METHODS.map((value) => ({ value, label: METHOD_LABELS[value] }))

export function NewReservation({ prefill }: { prefill?: ReservationPrefill | null }) {
  // Paso 1: búsqueda
  const [checkIn, setCheckIn] = useState('')
  const [checkOut, setCheckOut] = useState('')
  const [pax, setPax] = useState(1)
  const [results, setResults] = useState<AvailableRoom[] | null>(null)

  // Paso 2: selección
  const [selected, setSelected] = useState<AvailableRoom | null>(null)
  const [typeId, setTypeId] = useState('')

  // Paso 3: datos mínimos de la reserva
  const [firstName, setFirstName] = useState('')
  const [lastName, setLastName] = useState('')
  const [phone, setPhone] = useState('')
  const [email, setEmail] = useState('')
  const [method, setMethod] = useState('phone')
  const [rateBs, setRateBs] = useState('')
  const [rateReason, setRateReason] = useState('')

  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [success, setSuccess] = useState<string | null>(null)
  const [pendingBanner, setPendingBanner] = useState<string | null>(null)

  // Individual (una habitación) vs grupo (bulk).
  const [mode, setMode] = useState<'individual' | 'group'>('individual')

  async function doSearch(
    ci: string,
    co: string,
    px: number,
  ): Promise<AvailableRoom[] | null> {
    setError(null)
    setSuccess(null)
    setSelected(null)
    if (!ci || !co) {
      setError('Elegí fecha de entrada y salida')
      return null
    }
    if (co <= ci) {
      setError('La salida debe ser posterior a la entrada')
      return null
    }
    setBusy(true)
    try {
      const rooms = await searchAvailableRooms(ci, co, px)
      setResults(rooms)
      return rooms
    } catch (e) {
      setError((e as Error).message)
      return null
    } finally {
      setBusy(false)
    }
  }

  function handleSearch() {
    void doSearch(checkIn, checkOut, pax)
  }

  function selectRoom(room: AvailableRoom) {
    setSelected(room)
    setTypeId(room.suitableTypes[0]?.id ?? '')
    setError(null)
  }

  // Precarga desde Disponibilidad: fija fechas, busca y preselecciona la
  // habitación clickeada (si sigue disponible para esa noche).
  useEffect(() => {
    if (!prefill) return
    setMode('individual')
    setCheckIn(prefill.checkIn)
    setCheckOut(prefill.checkOut)
    setPax(1)
    void doSearch(prefill.checkIn, prefill.checkOut, 1).then((rooms) => {
      const match = rooms?.find((r) => r.roomNumber === prefill.roomNumber)
      if (match) selectRoom(match)
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [prefill])

  async function handleCreate() {
    if (!selected) return
    if (!firstName.trim() || !lastName.trim()) {
      setError('Nombre y apellido son obligatorios')
      return
    }
    if (!phone.trim() && !email.trim()) {
      setError('Cargá al menos un contacto: celular o correo')
      return
    }
    setBusy(true)
    setError(null)
    setPendingBanner(null)
    try {
      const reservationId = await createReservation({
        roomId: selected.roomId,
        roomTypeId: typeId,
        firstName: firstName.trim(),
        lastName: lastName.trim(),
        phone: phone.trim(),
        email: email.trim(),
        checkIn,
        checkOut,
        numGuests: pax,
        method,
        rateBs: rateBs.trim() ? Number(rateBs) : null,
        reason: rateReason.trim() || null,
      })
      setSuccess(
        `Reserva creada para la habitación ${selected.roomNumber} (${checkIn} → ${checkOut}).`,
      )
      // Chequeo liviano: si el descuento pedido superó el 20% y quien
      // creó no es reception_admin, queda una solicitud pendiente y la
      // reserva se facturó a precio de lista mientras tanto.
      const pending = await fetchPendingForReservation(reservationId)
      if (pending) {
        setPendingBanner(
          `Descuento pendiente de aprobación (${pending.computedDiscountPct}%). ` +
            'La reserva se facturó a precio de lista hasta que reception_admin lo apruebe.',
        )
      }
      setResults(null)
      setSelected(null)
      setFirstName('')
      setLastName('')
      setPhone('')
      setEmail('')
      setRateBs('')
      setRateReason('')
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="mx-auto max-w-3xl p-6">
      <h1 className="mb-4 text-2xl font-bold text-slate-800">Nueva reserva</h1>

      <div className="mb-6 inline-flex rounded-lg border border-slate-200 p-1 text-sm">
        <button
          type="button"
          onClick={() => setMode('individual')}
          className={`rounded-md px-3 py-1 font-medium ${
            mode === 'individual' ? 'bg-brand-700 text-white' : 'text-slate-600 hover:bg-slate-50'
          }`}
        >
          Individual
        </button>
        <button
          type="button"
          onClick={() => setMode('group')}
          className={`rounded-md px-3 py-1 font-medium ${
            mode === 'group' ? 'bg-brand-700 text-white' : 'text-slate-600 hover:bg-slate-50'
          }`}
        >
          Grupo (en bulk)
        </button>
      </div>

      {mode === 'group' && <BulkReservation />}

      {mode === 'individual' && (
        <>
      {error && (
        <p className="mb-4 rounded bg-red-50 p-2 text-sm text-red-700">{error}</p>
      )}
      {success && (
        <p className="mb-4 rounded bg-green-50 p-2 text-sm text-green-700">
          {success}
        </p>
      )}
      {pendingBanner && (
        <p className="mb-4 rounded bg-amber-50 p-2 text-sm text-amber-800">
          {pendingBanner}
        </p>
      )}

      {/* Paso 1: fechas y personas */}
      <section className="mb-6 rounded border border-slate-200 p-4">
        <h2 className="mb-3 font-semibold text-slate-700">
          1 · Fechas y personas
        </h2>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-4">
          <label className="text-sm">
            <span className="text-slate-600">Entrada</span>
            <input
              type="date"
              value={checkIn}
              onChange={(e) => setCheckIn(e.target.value)}
              className="mt-1 w-full rounded border border-slate-300 p-2"
            />
          </label>
          <label className="text-sm">
            <span className="text-slate-600">Salida</span>
            <input
              type="date"
              value={checkOut}
              onChange={(e) => setCheckOut(e.target.value)}
              className="mt-1 w-full rounded border border-slate-300 p-2"
            />
          </label>
          <label className="text-sm">
            <span className="text-slate-600">Personas</span>
            <input
              type="number"
              min={1}
              value={pax}
              onChange={(e) => setPax(Math.max(1, Number(e.target.value)))}
              className="mt-1 w-full rounded border border-slate-300 p-2"
            />
          </label>
          <div className="flex items-end">
            <button
              type="button"
              disabled={busy}
              onClick={handleSearch}
              className="w-full rounded bg-brand-700 py-2 font-medium text-white hover:bg-brand-800 disabled:opacity-50"
            >
              Buscar
            </button>
          </div>
        </div>
      </section>

      {/* Paso 2: resultados */}
      {results && (
        <section className="mb-6 rounded border border-slate-200 p-4">
          <h2 className="mb-3 font-semibold text-slate-700">
            2 · Habitaciones disponibles ({results.length})
          </h2>
          {results.length === 0 ? (
            <p className="text-sm text-slate-400">
              No hay habitaciones disponibles para esas fechas y personas.
            </p>
          ) : (
            <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
              {results.map((room) => (
                <button
                  type="button"
                  key={room.roomId}
                  onClick={() => selectRoom(room)}
                  className={`rounded border p-2 text-left text-sm ${
                    selected?.roomId === room.roomId
                      ? 'border-blue-500 bg-blue-50'
                      : 'border-slate-300 hover:bg-slate-50'
                  }`}
                >
                  <span className="font-bold">Hab. {room.roomNumber}</span>
                  <span className="block text-xs text-slate-500">
                    Piso {room.floor} · {room.zone}
                  </span>
                </button>
              ))}
            </div>
          )}
        </section>
      )}

      {/* Paso 3: datos mínimos */}
      {selected && (
        <section className="rounded border border-slate-200 p-4">
          <h2 className="mb-3 font-semibold text-slate-700">
            3 · Datos de la reserva · Habitación {selected.roomNumber}
          </h2>
          <div className="space-y-3">
            <label className="block text-sm">
              <span className="text-slate-600">Tipo / tarifa</span>
              <select
                value={typeId}
                onChange={(e) => setTypeId(e.target.value)}
                className="mt-1 w-full rounded border border-slate-300 p-2"
              >
                {selected.suitableTypes.map((t) => (
                  <option key={t.id} value={t.id}>
                    {t.name} — {t.basePriceBs} Bs/noche (hasta {t.maxOccupancy})
                  </option>
                ))}
              </select>
            </label>
            <label className="block text-sm">
              <span className="text-slate-600">Canal de la reserva</span>
              <select
                value={method}
                onChange={(e) => setMethod(e.target.value)}
                className="mt-1 w-full rounded border border-slate-300 p-2"
              >
                {METHODS.map((m) => (
                  <option key={m.value} value={m.value}>
                    {m.label}
                  </option>
                ))}
              </select>
            </label>
            <div className="flex gap-2">
              <input
                placeholder="Nombre"
                value={firstName}
                onChange={(e) => setFirstName(e.target.value)}
                className="w-1/2 rounded border border-slate-300 p-2"
              />
              <input
                placeholder="Apellido"
                value={lastName}
                onChange={(e) => setLastName(e.target.value)}
                className="w-1/2 rounded border border-slate-300 p-2"
              />
            </div>
            <p className="text-xs text-slate-500">
              Contacto (al menos uno). El resto del perfil se completa en el
              check-in.
            </p>
            <div className="flex gap-2">
              <label className="w-1/2 text-sm">
                <span className="text-slate-600">Tarifa (Bs/noche, opcional)</span>
                <input
                  type="number"
                  min={0}
                  placeholder="Precio de lista"
                  value={rateBs}
                  onChange={(e) => setRateBs(e.target.value)}
                  className="mt-1 w-full rounded border border-slate-300 p-2"
                />
              </label>
              <label className="w-1/2 text-sm">
                <span className="text-slate-600">
                  Justificación (obligatoria si cambia la tarifa)
                </span>
                <input
                  placeholder="Motivo del descuento"
                  value={rateReason}
                  onChange={(e) => setRateReason(e.target.value)}
                  className="mt-1 w-full rounded border border-slate-300 p-2"
                />
              </label>
            </div>
            <div className="flex gap-2">
              <input
                placeholder="Celular"
                value={phone}
                onChange={(e) => setPhone(e.target.value)}
                className="w-1/2 rounded border border-slate-300 p-2"
              />
              <input
                type="email"
                placeholder="Correo"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                className="w-1/2 rounded border border-slate-300 p-2"
              />
            </div>
            <button
              type="button"
              disabled={busy}
              onClick={handleCreate}
              className="w-full rounded bg-green-600 py-2 font-medium text-white hover:bg-green-700 disabled:opacity-50"
            >
              {busy ? 'Creando…' : 'Crear reserva'}
            </button>
          </div>
        </section>
      )}
        </>
      )}
    </div>
  )
}
