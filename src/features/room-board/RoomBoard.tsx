import { useCallback, useEffect, useState } from 'react'
import { PageHeader } from '../../components/ui'
import { fetchRooms } from '../../services/rooms'
import type { Room, RoomOperationalStatus } from '../../domain/rooms/room'
import { isDualRoom } from '../../domain/rooms/room'
import { RoomPanel } from './RoomPanel'
import type { UserRole } from '../../domain/auth/profile'

// Estilos y etiqueta por estado operativo. Un solo lugar de verdad.
const STATUS_STYLES: Record<
  RoomOperationalStatus,
  { label: string; card: string; dot: string }
> = {
  available: {
    label: 'Disponible',
    card: 'bg-green-50 border-green-400',
    dot: 'bg-green-500',
  },
  occupied: {
    label: 'Ocupada',
    card: 'bg-blue-50 border-blue-400',
    dot: 'bg-blue-500',
  },
  dirty: {
    label: 'Por limpiar',
    card: 'bg-amber-50 border-amber-400',
    dot: 'bg-amber-500',
  },
  maintenance: {
    label: 'Mantenimiento',
    card: 'bg-red-50 border-red-400',
    dot: 'bg-red-500',
  },
}

function RoomCard({ room, onClick }: { room: Room; onClick: () => void }) {
  const style = STATUS_STYLES[room.operationalStatus]
  return (
    <button
      type="button"
      onClick={onClick}
      className={`rounded-lg border p-3 text-left shadow-sm transition hover:ring-2 hover:ring-slate-400 ${style.card}`}
    >
      <div className="flex items-center justify-between">
        <span className="text-lg font-bold text-slate-800">
          {room.roomNumber}
        </span>
        <span className={`h-3 w-3 rounded-full ${style.dot}`} />
      </div>
      <p className="mt-1 truncate text-xs text-slate-600">
        {room.defaultType?.name ?? 'Sin tipo'}
      </p>
      {isDualRoom(room) && (
        <span className="mt-1 inline-block rounded bg-slate-200 px-1.5 py-0.5 text-[10px] font-medium text-slate-600">
          dual
        </span>
      )}
    </button>
  )
}

function Legend() {
  return (
    <div className="mb-6 flex flex-wrap gap-4">
      {(Object.keys(STATUS_STYLES) as RoomOperationalStatus[]).map((s) => (
        <div key={s} className="flex items-center gap-2">
          <span className={`h-3 w-3 rounded-full ${STATUS_STYLES[s].dot}`} />
          <span className="text-sm text-slate-600">
            {STATUS_STYLES[s].label}
          </span>
        </div>
      ))}
    </div>
  )
}

// Agrupa por piso y, dentro de cada piso, por patio (zona).
function groupByFloorAndZone(rooms: Room[]) {
  const byFloor = new Map<number, Map<string, Room[]>>()
  for (const room of rooms) {
    const zone = room.zone ?? 'Sin zona'
    if (!byFloor.has(room.floor)) byFloor.set(room.floor, new Map())
    const zones = byFloor.get(room.floor)!
    if (!zones.has(zone)) zones.set(zone, [])
    zones.get(zone)!.push(room)
  }
  return byFloor
}

export function RoomBoard({ role }: { role?: UserRole | null }) {
  const [rooms, setRooms] = useState<Room[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [selectedId, setSelectedId] = useState<string | null>(null)

  const reload = useCallback(() => {
    return fetchRooms()
      .then(setRooms)
      .catch((e: Error) => setError(e.message))
  }, [])

  useEffect(() => {
    reload().finally(() => setLoading(false))
  }, [reload])

  if (loading) {
    return <p className="p-8 text-slate-500">Cargando habitaciones…</p>
  }
  if (error) {
    return <p className="p-8 text-red-600">Error: {error}</p>
  }

  const grouped = groupByFloorAndZone(rooms)
  const floors = [...grouped.keys()].sort((a, b) => a - b)
  const selectedRoom = rooms.find((r) => r.id === selectedId) ?? null

  return (
    <div className="mx-auto max-w-6xl p-6">
      <PageHeader
        title="Tablero de habitaciones"
        subtitle={`${rooms.length} habitaciones · Hotel Monasterio`}
      />

      <Legend />

      {floors.map((floor) => (
        <section key={floor} className="mb-8">
          <h2 className="mb-3 border-b border-slate-200 pb-1 text-lg font-semibold text-slate-700">
            Piso {floor}
          </h2>
          {[...grouped.get(floor)!.entries()].map(([zone, zoneRooms]) => (
            <div key={zone} className="mb-4">
              <h3 className="mb-2 text-sm font-medium text-slate-500">{zone}</h3>
              <div className="grid grid-cols-3 gap-3 sm:grid-cols-5 md:grid-cols-8">
                {zoneRooms.map((room) => (
                  <RoomCard
                    key={room.id}
                    room={room}
                    onClick={() => setSelectedId(room.id)}
                  />
                ))}
              </div>
            </div>
          ))}
        </section>
      ))}

      {selectedRoom && (
        <RoomPanel
          room={selectedRoom}
          role={role}
          onClose={() => setSelectedId(null)}
          onDone={() => {
            void reload()
            setSelectedId(null)
          }}
        />
      )}
    </div>
  )
}
