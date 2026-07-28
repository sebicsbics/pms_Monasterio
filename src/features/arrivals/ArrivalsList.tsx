import { useCallback, useEffect, useState } from 'react'
import { X } from 'lucide-react'
import type { Arrival } from '../../domain/stays/arrival'
import {
  fetchArrivals,
  checkInFromReservation,
  type CompanionGuest,
} from '../../services/arrivals'
import { overrideReservationRate } from '../../services/checkin'
import { cancelReservation, rescheduleReservation } from '../../services/reservations'
import { COUNTRIES } from '../../shared/data/countries'
import { TRAVEL_PURPOSES } from '../../shared/data/travelPurposes'
import type { UserRole } from '../../domain/auth/profile'
import { canEditRate as canEditRateGate } from '../../domain/auth/rateGates'

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
  onDone: () => void
}) {
  const [document, setDocument] = useState('')
  const [birthDate, setBirthDate] = useState('')
  const [countryCode, setCountryCode] = useState('')
  const [city, setCity] = useState('')
  const [wantsOffers, setWantsOffers] = useState(false)
  const [originCity, setOriginCity] = useState('')
  const [travelPurpose, setTravelPurpose] = useState('')
  const [occupation, setOccupation] = useState('')
  const [transportMeans, setTransportMeans] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  // Acompañantes: perfil completo de los demás huéspedes de la habitación.
  // Se pre-arma una ficha vacía por cada plaza más allá del titular.
  const emptyCompanion = (): CompanionGuest => ({
    firstName: '',
    lastName: '',
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
  function updateCompanion(index: number, patch: Partial<CompanionGuest>) {
    setCompanions((prev) =>
      prev.map((g, i) => (i === index ? { ...g, ...patch } : g)),
    )
  }

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

  const ratePending = rateEditOpen && newRate.trim() !== ''

  async function handleCheckIn() {
    // Validación fail-fast de la tarifa antes de tocar nada, para no dejar
    // el check-in hecho con la tarifa a medias.
    if (ratePending && rateReason.trim() === '') {
      setError('La justificación de la tarifa es obligatoria')
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

      // 2) Check-in del titular + acompañantes.
      await checkInFromReservation(
        arrival.reservationId,
        {
          document: document.trim(),
          birthDate,
          countryCode: countryCode.trim().toUpperCase(),
          city: city.trim(),
          wantsOffers,
          originCity: originCity.trim(),
          travelPurpose: travelPurpose.trim(),
          occupation: occupation.trim(),
          transportMeans: transportMeans.trim(),
        },
        companions,
      )

      // Si quedó un descuento pendiente, avisamos y no cerramos el modal
      // de golpe: que recepción vea el mensaje.
      if (pending) {
        setError(pending)
        setBusy(false)
        return
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

        {canEditRate && (
          <div className="mb-4">
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
          <input
            placeholder="Documento / Pasaporte"
            value={document}
            onChange={(e) => setDocument(e.target.value)}
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

          {companions.length > 0 && (
            <div className="space-y-3 border-t border-slate-200 pt-3">
              <p className="text-xs font-medium text-slate-600">
                Acompañantes ({companions.length}) — perfil completo de cada huésped
              </p>
              {companions.map((g, i) => (
                <div key={i} className="space-y-2 rounded border border-slate-200 p-3">
                  <p className="text-xs font-semibold text-slate-500">Huésped {i + 2}</p>
                  <div className="flex gap-2">
                    <input
                      placeholder="Nombre"
                      value={g.firstName}
                      onChange={(e) => updateCompanion(i, { firstName: e.target.value })}
                      className="w-1/2 rounded border border-slate-300 p-2 text-sm"
                    />
                    <input
                      placeholder="Apellido"
                      value={g.lastName}
                      onChange={(e) => updateCompanion(i, { lastName: e.target.value })}
                      className="w-1/2 rounded border border-slate-300 p-2 text-sm"
                    />
                  </div>
                  <input
                    placeholder="Documento / Pasaporte"
                    value={g.document}
                    onChange={(e) => updateCompanion(i, { document: e.target.value })}
                    className="w-full rounded border border-slate-300 p-2 text-sm"
                  />
                  <div className="flex gap-2">
                    <select
                      value={g.countryCode}
                      onChange={(e) => updateCompanion(i, { countryCode: e.target.value })}
                      className="w-1/2 rounded border border-slate-300 p-2 text-sm"
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
                      value={g.city}
                      onChange={(e) => updateCompanion(i, { city: e.target.value })}
                      className="w-1/2 rounded border border-slate-300 p-2 text-sm"
                    />
                  </div>
                  <label className="block text-xs text-slate-500">
                    Fecha de nacimiento
                    <input
                      type="date"
                      value={g.birthDate}
                      onChange={(e) => updateCompanion(i, { birthDate: e.target.value })}
                      className="mt-1 w-full rounded border border-slate-300 p-2 text-sm"
                    />
                  </label>
                  <input
                    placeholder="Ciudad de procedencia"
                    value={g.originCity}
                    onChange={(e) => updateCompanion(i, { originCity: e.target.value })}
                    className="w-full rounded border border-slate-300 p-2 text-sm"
                  />
                  <select
                    value={g.travelPurpose}
                    onChange={(e) => updateCompanion(i, { travelPurpose: e.target.value })}
                    className="w-full rounded border border-slate-300 p-2 text-sm text-slate-700"
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
                      placeholder="Profesión"
                      value={g.occupation}
                      onChange={(e) => updateCompanion(i, { occupation: e.target.value })}
                      className="w-1/2 rounded border border-slate-300 p-2 text-sm"
                    />
                    <input
                      placeholder="Transporte"
                      value={g.transportMeans}
                      onChange={(e) => updateCompanion(i, { transportMeans: e.target.value })}
                      className="w-1/2 rounded border border-slate-300 p-2 text-sm"
                    />
                  </div>
                </div>
              ))}
            </div>
          )}

          <button
            type="button"
            disabled={busy || (ratePending && !rateReason.trim())}
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
  const [arrivals, setArrivals] = useState<Arrival[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
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

      {arrivals.length === 0 ? (
        <p className="text-slate-400">No hay llegadas pendientes.</p>
      ) : (
        <div className="overflow-x-auto rounded border border-slate-200">
          <table className="w-full text-left text-sm">
            <thead className="bg-slate-100 text-slate-600">
              <tr>
                <th className="p-3">Hab.</th>
                <th className="p-3">Huésped</th>
                <th className="p-3">Contacto</th>
                <th className="p-3">Tipo</th>
                <th className="p-3">Entrada</th>
                <th className="p-3">Salida</th>
                <th className="p-3">Canal</th>
                <th className="p-3"></th>
              </tr>
            </thead>
            <tbody>
              {arrivals.map((a) => (
                <tr key={a.reservationId} className="border-t border-slate-100">
                  <td className="p-3 font-semibold">{a.roomNumber}</td>
                  <td className="p-3">
                    {a.firstName} {a.lastName}
                  </td>
                  <td className="p-3 text-slate-500">
                    {a.phone ?? a.email ?? '—'}
                  </td>
                  <td className="p-3">{a.roomType}</td>
                  <td className="p-3">{a.checkInDate}</td>
                  <td className="p-3">{a.checkOutDate}</td>
                  <td className="p-3">{a.method}</td>
                  <td className="p-3">
                    <div className="flex flex-wrap justify-end gap-1">
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
          onDone={() => {
            void reload()
            setSelected(null)
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
