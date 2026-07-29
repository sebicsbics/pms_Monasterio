import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Room } from '../../domain/rooms/room'
import { fetchRooms } from '../../services/rooms'
import { fetchOccupancy } from '../../services/reservations'
import { dateRange, isOccupied, type OccupancySpan } from '../../domain/availability/occupancy'
import { PageHeader } from '../../components/ui'

const TODAY = new Date().toISOString().slice(0, 10)
const WEEKDAYS = ['D', 'L', 'M', 'M', 'J', 'V', 'S']
const MAX_DAYS = 60

function addDays(date: string, days: number): string {
  const d = new Date(`${date}T00:00:00`)
  d.setDate(d.getDate() + days)
  return d.toISOString().slice(0, 10)
}

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

interface Cell {
  r: number
  c: number
}
interface Selection {
  anchor: Cell
  current: Cell
}

export function AvailabilityGrid({
  onReserve,
  onBulkReserve,
}: {
  onReserve?: (checkIn: string, checkOut: string, roomNumber: string) => void
  onBulkReserve?: (checkIn: string, checkOut: string, roomNumbers: string[]) => void
}) {
  const [rooms, setRooms] = useState<Room[]>([])
  const [spans, setSpans] = useState<OccupancySpan[]>([])
  const [from, setFrom] = useState(TODAY)
  const [to, setTo] = useState(addDays(TODAY, 13))
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const [sel, setSel] = useState<Selection | null>(null)
  const [dragging, setDragging] = useState(false)

  useEffect(() => {
    fetchRooms()
      .then((rs) =>
        setRooms([...rs].sort((a, b) => Number(a.roomNumber) - Number(b.roomNumber))),
      )
      .catch((e: Error) => setError(e.message))
  }, [])

  const reload = useCallback(() => {
    setLoading(true)
    setSel(null)
    return fetchOccupancy(from, to)
      .then(setSpans)
      .catch((e: Error) => setError(e.message))
      .finally(() => setLoading(false))
  }, [from, to])

  useEffect(() => {
    void reload()
  }, [reload])

  const allDates = useMemo(() => dateRange(from, to), [from, to])
  const dates = allDates.slice(0, MAX_DAYS)
  const truncated = allDates.length > MAX_DAYS

  // Rectángulo normalizado de la selección actual.
  const rect = useMemo(() => {
    if (!sel) return null
    return {
      rMin: Math.min(sel.anchor.r, sel.current.r),
      rMax: Math.max(sel.anchor.r, sel.current.r),
      cMin: Math.min(sel.anchor.c, sel.current.c),
      cMax: Math.max(sel.anchor.c, sel.current.c),
    }
  }, [sel])

  const inRect = (r: number, c: number) =>
    !!rect && r >= rect.rMin && r <= rect.rMax && c >= rect.cMin && c <= rect.cMax

  // Cierre del arrastre a nivel documento. El criterio es la cantidad de
  // HABITACIONES (filas): una sola habitación → reserva individual (aunque
  // sean varias noches); varias habitaciones → bloque para bulk.
  useEffect(() => {
    if (!dragging) return
    function onUp() {
      setDragging(false)
      if (!rect) return
      if (rect.rMin === rect.rMax) {
        // Una sola habitación → reserva individual con el rango de noches.
        const room = rooms[rect.rMin]
        const selectedDates = dates.slice(rect.cMin, rect.cMax + 1)
        const allFree =
          !!room && selectedDates.length > 0 &&
          selectedDates.every((d) => !isOccupied(spans, room.id, d))
        if (room && allFree) {
          onReserve?.(
            selectedDates[0],
            addDays(selectedDates[selectedDates.length - 1], 1),
            room.roomNumber,
          )
        }
        setSel(null)
      }
      // Varias habitaciones → se mantiene la selección y aparece la barra bulk.
    }
    document.addEventListener('mouseup', onUp)
    return () => document.removeEventListener('mouseup', onUp)
  }, [dragging, rect, rooms, dates, spans, onReserve])

  // Habitaciones del bloque que están libres TODAS las noches del rango.
  const selDates = rect ? dates.slice(rect.cMin, rect.cMax + 1) : []
  const selRooms = rect ? rooms.slice(rect.rMin, rect.rMax + 1) : []
  const qualifying = selRooms.filter((room) =>
    selDates.every((d) => !isOccupied(spans, room.id, d)),
  )
  // La barra de bulk solo aparece con VARIAS habitaciones (varias filas).
  const isBlock = !!rect && rect.rMin !== rect.rMax

  return (
    <div className="mx-auto max-w-full select-none p-6">
      <PageHeader
        title="Disponibilidad"
        subtitle="Verde disponible, amarillo reservado · una habitación (aunque sean varias noches) = reserva individual; varias habitaciones = reserva en grupo"
      />

      <div className="mb-4 flex flex-wrap items-end gap-3">
        <label className="text-xs font-medium text-slate-500">
          Desde
          <input type="date" value={from} max={to} onChange={(e) => setFrom(e.target.value)}
            className="mt-1 block rounded border border-slate-300 p-2 text-sm text-slate-700" />
        </label>
        <label className="text-xs font-medium text-slate-500">
          Hasta
          <input type="date" value={to} min={from} onChange={(e) => setTo(e.target.value)}
            className="mt-1 block rounded border border-slate-300 p-2 text-sm text-slate-700" />
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
          Rango muy amplio: se muestran los primeros {MAX_DAYS} días.
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
                <th key={d}
                  className="min-w-[34px] border-b border-slate-200 bg-slate-100 p-1 font-medium text-slate-600">
                  <DayHeader date={d} />
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rooms.map((room, ri) => (
              <tr key={room.id}>
                <td className="sticky left-0 z-10 border-r border-slate-200 bg-white px-2 py-1 font-semibold text-slate-700">
                  {room.roomNumber}
                </td>
                {dates.map((d, ci) => {
                  const occupied = isOccupied(spans, room.id, d)
                  const selectedCell = inRect(ri, ci)
                  return (
                    <td key={d} className="border border-slate-100 p-0">
                      <div
                        onMouseDown={() => {
                          setSel({ anchor: { r: ri, c: ci }, current: { r: ri, c: ci } })
                          setDragging(true)
                        }}
                        onMouseEnter={() => {
                          if (dragging) setSel((s) => (s ? { ...s, current: { r: ri, c: ci } } : s))
                        }}
                        title={`Hab. ${room.roomNumber} · ${d} · ${occupied ? 'Reservado' : 'Disponible'}`}
                        className={`h-7 w-full cursor-pointer ${
                          occupied ? 'bg-amber-300' : 'bg-green-300'
                        } ${selectedCell ? 'ring-2 ring-inset ring-blue-600' : ''}`}
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

      {/* Barra de acción del bloque seleccionado (solo en selección múltiple). */}
      {isBlock && (
        <div className="mt-4 flex flex-wrap items-center gap-3 rounded border border-blue-200 bg-blue-50 p-3 text-sm">
          <span className="text-slate-700">
            Bloque: <b>{qualifying.length}</b> habitación(es) disponibles ·{' '}
            {selDates[0]} → {addDays(selDates[selDates.length - 1], 1)}
            {selRooms.length - qualifying.length > 0 && (
              <span className="text-amber-700">
                {' '}({selRooms.length - qualifying.length} excluidas por ocupación)
              </span>
            )}
          </span>
          <button
            type="button"
            disabled={qualifying.length === 0}
            onClick={() =>
              onBulkReserve?.(
                selDates[0],
                addDays(selDates[selDates.length - 1], 1),
                qualifying.map((r) => r.roomNumber),
              )
            }
            className="rounded bg-brand-700 px-3 py-1.5 font-medium text-white hover:bg-brand-800 disabled:opacity-50"
          >
            Reservar en grupo
          </button>
          <button
            type="button"
            onClick={() => setSel(null)}
            className="rounded border border-slate-300 px-3 py-1.5 text-slate-600 hover:bg-white"
          >
            Cancelar
          </button>
        </div>
      )}
    </div>
  )
}
