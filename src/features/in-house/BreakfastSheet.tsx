import { useRef } from 'react'
import { Button, PrintButton } from '../../components/ui'
import { splitIntoColumns, type BreakfastRoom } from '../../domain/stays/breakfast'
import { ASSIGNMENT_KIND_LABEL } from '../../domain/housekeeping/assignment'

// Cuántas filas entran cómodas en una columna de A4 con esta tipografía.
// Pasado ese punto la hoja se parte en dos columnas en vez de encoger la
// letra: el papel tiene ancho de sobra y la legibilidad no se negocia.
const ROWS_PER_COLUMN = 30

// Hoja de desayuno: la lista que recepción arma de noche y le pasa a las
// camareras a la mañana. Va en un modal con su propio botón de imprimir
// (el global imprimiría el tablero de atrás, no esta hoja).
//
// Es una hoja de trabajo en papel, así que manda el papel: casilla amplia
// para tickear a mano, filas separadas por bordes y sin colores de fondo
// que se coman el tóner.
export function BreakfastSheet({
  rooms,
  date,
  onClose,
}: {
  rooms: BreakfastRoom[]
  date: string
  onClose: () => void
}) {
  const sheetRef = useRef<HTMLDivElement>(null)
  const totalGuests = rooms.reduce((n, r) => n + r.guests.length, 0)
  const columns = splitIntoColumns(rooms, ROWS_PER_COLUMN)

  return (
    <div className="fixed inset-0 z-20 flex items-start justify-center overflow-y-auto bg-black/30 p-4">
      <div
        className={`w-full rounded-lg bg-white p-6 shadow-lg ${
          columns.length > 1 ? 'max-w-5xl' : 'max-w-3xl'
        }`}
      >
        <div className="no-print mb-4 flex items-center justify-between gap-3">
          <h2 className="text-lg font-semibold text-slate-800">Lista de desayuno</h2>
          <div className="flex gap-2">
            <PrintButton targetRef={sheetRef} title={`Desayuno ${date}`} fitToPage />
            <Button variant="secondary" onClick={onClose}>
              Cerrar
            </Button>
          </div>
        </div>

        <div ref={sheetRef}>
          <header className="mb-4 border-b border-slate-300 pb-2">
            <h1 className="text-xl font-bold text-slate-900">
              Desayuno — Hotel Monasterio
            </h1>
            <p className="text-sm text-slate-600">
              {date} · {rooms.length} habitación{rooms.length === 1 ? '' : 'es'} ·{' '}
              {totalGuests} huésped{totalGuests === 1 ? '' : 'es'}
            </p>
          </header>

          {rooms.length === 0 ? (
            <p className="text-slate-500">No hay huéspedes hospedados.</p>
          ) : (
            <div className={columns.length > 1 ? 'flex gap-6' : ''}>
              {columns.map((column, i) => (
                <BreakfastColumn key={i} rooms={column} />
              ))}
            </div>
          )}

          <p className="mt-4 text-xs text-slate-500">
            Atención de desayuno hasta las 10:00. A las 09:00, llamar a las
            habitaciones sin tickear para avisarles.
          </p>
          <p className="mt-1 text-xs text-slate-500">
            Limpieza = sigue el mismo huésped · Habilitar = se va el huésped,
            se prepara para el próximo.
          </p>
        </div>
      </div>
    </div>
  )
}

// Una columna de la hoja: la tabla con sus habitaciones. Una fila por
// huésped, con su propia casilla, para tickear a cada persona que baja.
// El número de habitación se escribe una sola vez (rowspan) y el borde
// grueso marca dónde termina la habitación.
function BreakfastColumn({ rooms }: { rooms: BreakfastRoom[] }) {
  return (
    <table className="w-full border-collapse text-left text-sm">
      <thead>
        <tr className="border-b-2 border-slate-400 text-slate-700">
          <th className="w-12 py-2 pr-2">Hab.</th>
          <th className="py-2 pr-2">Huéspedes</th>
          <th className="w-32 py-2 pr-2">Nacionalidad</th>
          <th className="w-20 py-2 pr-2">Limpieza</th>
          <th className="w-14 py-2 text-center">Bajó</th>
        </tr>
      </thead>
      {rooms.map((room) => (
        <tbody key={room.reservationId} className="border-b-2 border-slate-400">
          {room.guests.map((g, i) => (
            <tr key={g.name} className="border-b border-slate-200">
              {i === 0 && (
                <td
                  rowSpan={room.guests.length}
                  className="py-1.5 pr-2 align-top text-base font-bold"
                >
                  {room.roomNumber}
                </td>
              )}
              <td className="py-1.5 pr-2">{g.name}</td>
              <td className="py-1.5 pr-2 text-slate-600">{g.nationality}</td>
              {/* El trabajo de housekeeping es de la habitación, no de
                  cada huésped: se escribe una vez, igual que el número. */}
              {i === 0 && (
                <td
                  rowSpan={room.guests.length}
                  className="py-1.5 pr-2 align-top font-semibold text-slate-700"
                >
                  {room.cleaningKind ? ASSIGNMENT_KIND_LABEL[room.cleaningKind] : '—'}
                </td>
              )}
              <td className="py-1.5 text-center">
                <span className="inline-block h-5 w-5 border-2 border-slate-500" />
              </td>
            </tr>
          ))}
        </tbody>
      ))}
    </table>
  )
}
