import { useEffect, useState } from 'react'
import { Coffee } from 'lucide-react'
import { fetchBreakfastGuests, fetchInHouse } from '../../services/inhouse'
import type { InHouseStay } from '../../domain/stays/in-house'
import {
  buildBreakfastSheet,
  nextBreakfastDate,
  type BreakfastRoom,
} from '../../domain/stays/breakfast'
import { fetchAssignments, generateAssignments } from '../../services/housekeeping'
import { formatDate } from '../../lib/date'
import { BreakfastSheet } from './BreakfastSheet'

export function InHouseList() {
  const [stays, setStays] = useState<InHouseStay[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [breakfast, setBreakfast] = useState<BreakfastRoom[] | null>(null)
  // La fecha se congela al generar la hoja: si la reimprimen justo cuando
  // cruza el corte de las 10:00, el papel tiene que seguir diciendo el
  // mismo día que el tablero de housekeeping que se generó con él.
  const [breakfastDate, setBreakfastDate] = useState('')
  const [breakfastLoading, setBreakfastLoading] = useState(false)

  // La hoja se pide recién al apretar el botón: es un segundo viaje a la
  // base que solo hace falta en el turno noche, no en cada visita a la
  // pantalla.
  //
  // De paso se GENERA el tablero de housekeeping del día de la hoja. Son
  // el mismo acto operativo: recepción arma de noche lo que las camareras
  // van a usar a la mañana, y la hoja de desayuno es el papel que llevan
  // encima. Generar el tablero por separado se olvidaba, y entonces la
  // columna de limpieza salía vacía.
  //
  // `generate_housekeeping_assignments` es idempotente (INSERT ... ON
  // CONFLICT DO NOTHING): reimprimir la hoja no pisa el trabajo ya
  // marcado como hecho ni la mucama asignada.
  async function generateBreakfast() {
    setBreakfastLoading(true)
    try {
      const date = nextBreakfastDate()
      await generateAssignments(date)
      const [guests, assignments] = await Promise.all([
        fetchBreakfastGuests(),
        fetchAssignments(date),
      ])
      const cleaningByRoomId = new Map(assignments.map((a) => [a.roomId, a.kind]))
      setBreakfast(buildBreakfastSheet(stays, guests, cleaningByRoomId))
      setBreakfastDate(date)
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBreakfastLoading(false)
    }
  }

  useEffect(() => {
    fetchInHouse()
      .then(setStays)
      .catch((e: Error) => setError(e.message))
      .finally(() => setLoading(false))
  }, [])

  if (loading) return <p className="p-8 text-slate-500">Cargando…</p>
  if (error) return <p className="p-8 text-red-600">Error: {error}</p>

  const totalGuests = stays.reduce((sum, s) => sum + s.guestCount, 0)

  return (
    <div className="mx-auto max-w-6xl p-6">
      {/* Justo debajo del botón global de imprimir, que es fijo arriba a
          la derecha. Solo vive en esta pantalla: la hoja se arma con los
          huéspedes hospedados. */}
      <button
        type="button"
        onClick={generateBreakfast}
        disabled={breakfastLoading || stays.length === 0}
        className="no-print fixed right-4 top-14 z-10 inline-flex items-center gap-1.5
          rounded-lg border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium
          text-slate-700 shadow-sm hover:bg-slate-50 disabled:opacity-50"
      >
        <Coffee size={16} />
        {breakfastLoading ? 'Generando…' : 'Generar desayuno + limpieza'}
      </button>

      {breakfast && (
        <BreakfastSheet
          rooms={breakfast}
          date={formatDate(breakfastDate)}
          onClose={() => setBreakfast(null)}
        />
      )}

      <header className="mb-6">
        <h1 className="text-2xl font-bold text-slate-800">
          Huéspedes hospedados (in-house)
        </h1>
        <p className="text-sm text-slate-500">
          {stays.length} habitación{stays.length === 1 ? '' : 'es'} ocupada
          {stays.length === 1 ? '' : 's'}
        </p>
      </header>

      {stays.length === 0 ? (
        <p className="text-slate-400">No hay huéspedes hospedados ahora.</p>
      ) : (
        <div className="overflow-x-auto rounded border border-slate-200">
          <table className="w-full text-left text-sm">
            <thead className="bg-slate-100 text-slate-600">
              <tr>
                <th className="p-3">Hab.</th>
                <th className="p-3">Huésped</th>
                <th className="p-3 text-center">Huéspedes</th>
                <th className="p-3">Tipo</th>
                <th className="p-3">País</th>
                <th className="p-3">Entrada</th>
                <th className="p-3">Salida</th>
                <th className="p-3 text-right">Habitación (Bs)</th>
              </tr>
            </thead>
            <tbody>
              <tr className="border-t border-slate-200 bg-slate-50 font-semibold text-slate-700">
                <td className="p-3" colSpan={2}>
                  Total en el hotel
                </td>
                <td className="p-3 text-center">{totalGuests}</td>
                <td className="p-3" colSpan={5} />
              </tr>
              {stays.map((s) => (
                <tr key={s.reservationId} className="border-t border-slate-100">
                  <td className="p-3 font-semibold">{s.roomNumber}</td>
                  <td className="p-3">
                    {s.firstName} {s.lastName}
                    {s.email && (
                      <span className="block text-xs text-slate-400">
                        {s.email}
                      </span>
                    )}
                  </td>
                  <td className="p-3 text-center">{s.guestCount}</td>
                  <td className="p-3">{s.roomType}</td>
                  <td className="p-3">{s.countryCode ?? '—'}</td>
                  <td className="p-3">{s.checkInDate}</td>
                  <td className="p-3">{s.checkOutDate}</td>
                  <td className="p-3 text-right">{s.roomTotalBs.toFixed(2)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}
