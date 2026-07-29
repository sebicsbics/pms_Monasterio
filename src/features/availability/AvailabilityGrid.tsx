import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Room } from '../../domain/rooms/room'
import { fetchRooms } from '../../services/rooms'
import { fetchOccupancy } from '../../services/reservations'
import { dateRange, isOccupied, type OccupancySpan } from '../../domain/availability/occupancy'
import { PageHeader } from '../../components/ui'

const TODAY = new Date().toISOString().slice(0, 10)
const WEEKDAYS = ['D', 'L', 'M', 'M', 'J', 'V', 'S']
// Tope de columnas para no renderizar una grilla gigante.
const MAX_DAYS = 60

function addDays(date: string, days: number): string {
  const d = new Date(`${date}T00:00:00`)
  d.setDate(d.getDate() + days)
  return d.toISOString().slice(0, 10)
}

// Encabezado compacto de una fecha: letra del día + número.
function DayHeader({ date }: { date: string }) {
  const d = new Date(`${date}T00:00:00`)
  return (
    <div className="leading-tight">
      <div className="text-[10px] text-slate-400">{WEEKDAYS[d.getDay()]}</div>
      <div>{d.getDate()}</div>
      <div className="text-[10px] text-slate-400">
        {String(d.getMonth() + 1).padStart(2, '0')}
      </div>
    </div>
  )
}

export function AvailabilityGrid({
  onReserve,
}: {
  onReserve?: (date: string, roomNumber: string) => void
}) {
  const [rooms, setRooms] = useState<Room[]>([])
  const [spans, setSpans] = useState<OccupancySpan[]>([])
  const [from, setFrom] = useState(TODAY)
  const [to, setTo] = useState(addDays(TODAY, 13))
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    fetchRooms()
      .then((rs) =>
        setRooms([...rs].sort((a, b) => Number(a.roomNumber) - Number(b.roomNumber))),
      )
      .catch((e: Error) => setError(e.message))
  }, [])

  const reload = useCallback(() => {
    setLoading(true)
    return fetchOccupancy(from, to)
      .then(setSpans)
      .catch((e: Error) => setError(e.message))
      .finally(() => setLoading(false))
  }, [from, to])

  useEffect(() => {
    void reload()
  }, [reload])

  // Fechas del rango, con tope de MAX_DAYS columnas.
  const allDates = useMemo(() => dateRange(from, to), [from, to])
  const dates = allDates.slice(0, MAX_DAYS)
  const truncated = allDates.length > MAX_DAYS

  return (
    <div className="mx-auto max-w-full p-6">
      <PageHeader
        title="Disponibilidad"
        subtitle="Ocupación por habitación y fecha — verde disponible, amarillo reservado"
      />

      <div className="mb-4 flex flex-wrap items-end gap-3">
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
        <div className="flex items-center gap-3 pb-1 text-xs text-slate-500">
          <span className="flex items-center gap-1">
            <span className="inline-block h-3 w-3 rounded-sm bg-green-300" /> Disponible
          </span>
          <span className="flex items-center gap-1">
            <span className="inline-block h-3 w-3 rounded-sm bg-amber-300" /> Reservado
          </span>
        </div>
      </div>

      {error && <p className="mb-4 text-red-600">Error: {error}</p>}
      {truncated && (
        <p className="mb-2 text-xs text-amber-700">
          Rango muy amplio: se muestran los primeros {MAX_DAYS} días. Acotá las
          fechas para ver el resto.
        </p>
      )}

      <div className="overflow-x-auto rounded border border-slate-200">
        <table className="border-collapse text-center text-xs">
          <thead>
            <tr>
              <th className="sticky left-0 z-10 border-b border-r border-slate-200 bg-slate-100 p-2 text-slate-600">
                Hab.
              </th>
              {dates.map((d) => (
                <th
                  key={d}
                  className="min-w-[34px] border-b border-slate-200 bg-slate-100 p-1 font-medium text-slate-600"
                >
                  <DayHeader date={d} />
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rooms.map((room) => (
              <tr key={room.id}>
                <td className="sticky left-0 z-10 border-r border-slate-200 bg-white px-2 py-1 font-semibold text-slate-700">
                  {room.roomNumber}
                </td>
                {dates.map((d) => {
                  const occupied = isOccupied(spans, room.id, d)
                  const canReserve = !occupied && !!onReserve
                  return (
                    <td key={d} className="border border-slate-100 p-0">
                      <button
                        type="button"
                        disabled={!canReserve}
                        onClick={() => onReserve?.(d, room.roomNumber)}
                        title={`Hab. ${room.roomNumber} · ${d} · ${
                          occupied ? 'Reservado' : 'Disponible — click para reservar'
                        }`}
                        className={`h-7 w-full disabled:cursor-default ${
                          occupied
                            ? 'bg-amber-300'
                            : 'bg-green-300 hover:bg-green-400 cursor-pointer'
                        }`}
                      />
                    </td>
                  )
                })}
              </tr>
            ))}
            {rooms.length === 0 && (
              <tr>
                <td colSpan={dates.length + 1} className="p-4 text-slate-400">
                  {loading ? 'Cargando…' : 'Sin habitaciones.'}
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  )
}
