import { useCallback, useEffect, useState } from 'react'
import { X } from 'lucide-react'
import type { Arrival } from '../../domain/stays/arrival'
import { fetchArrivals, checkInFromReservation } from '../../services/arrivals'
import { COUNTRIES } from '../../shared/data/countries'

const TODAY = new Date().toISOString().slice(0, 10)

function CheckInModal({
  arrival,
  onClose,
  onDone,
}: {
  arrival: Arrival
  onClose: () => void
  onDone: () => void
}) {
  const [document, setDocument] = useState('')
  const [birthDate, setBirthDate] = useState('')
  const [countryCode, setCountryCode] = useState('')
  const [city, setCity] = useState('')
  const [wantsOffers, setWantsOffers] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function handleCheckIn() {
    setBusy(true)
    setError(null)
    try {
      await checkInFromReservation(arrival.reservationId, {
        document: document.trim(),
        birthDate,
        countryCode: countryCode.trim().toUpperCase(),
        city: city.trim(),
        wantsOffers,
      })
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
          <label className="flex items-center gap-2 text-sm text-slate-600">
            <input
              type="checkbox"
              checked={wantsOffers}
              onChange={(e) => setWantsOffers(e.target.checked)}
            />
            Acepta recibir promociones por correo
          </label>
          <button
            type="button"
            disabled={busy}
            onClick={handleCheckIn}
            className="w-full rounded bg-brand-700 py-2 font-medium text-white hover:bg-brand-800 disabled:opacity-50"
          >
            {busy ? 'Procesando…' : 'Confirmar check-in'}
          </button>
        </div>
      </aside>
    </div>
  )
}

export function ArrivalsList() {
  const [arrivals, setArrivals] = useState<Arrival[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [selected, setSelected] = useState<Arrival | null>(null)

  const reload = useCallback(() => {
    return fetchArrivals(TODAY)
      .then(setArrivals)
      .catch((e: Error) => setError(e.message))
  }, [])

  useEffect(() => {
    reload().finally(() => setLoading(false))
  }, [reload])

  if (loading) return <p className="p-8 text-slate-500">Cargando…</p>
  if (error) return <p className="p-8 text-red-600">Error: {error}</p>

  return (
    <div className="mx-auto max-w-6xl p-6">
      <header className="mb-6">
        <h1 className="text-2xl font-bold text-slate-800">Llegadas de hoy</h1>
        <p className="text-sm text-slate-500">
          {arrivals.length} reserva(s) pendiente(s) de check-in
        </p>
      </header>

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
                    <button
                      type="button"
                      onClick={() => setSelected(a)}
                      className="rounded bg-brand-700 px-3 py-1 text-xs font-medium text-white hover:bg-brand-800"
                    >
                      Check-in
                    </button>
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
          onClose={() => setSelected(null)}
          onDone={() => {
            void reload()
            setSelected(null)
          }}
        />
      )}
    </div>
  )
}
