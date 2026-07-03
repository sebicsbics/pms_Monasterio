import { useEffect, useState } from 'react'
import { fetchInHouse } from '../../services/inhouse'
import type { InHouseStay } from '../../domain/stays/in-house'

export function InHouseList() {
  const [stays, setStays] = useState<InHouseStay[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    fetchInHouse()
      .then(setStays)
      .catch((e: Error) => setError(e.message))
      .finally(() => setLoading(false))
  }, [])

  if (loading) return <p className="p-8 text-slate-500">Cargando…</p>
  if (error) return <p className="p-8 text-red-600">Error: {error}</p>

  return (
    <div className="mx-auto max-w-6xl p-6">
      <header className="mb-6">
        <h1 className="text-2xl font-bold text-slate-800">
          Huéspedes hospedados (in-house)
        </h1>
        <p className="text-sm text-slate-500">{stays.length} en el hotel</p>
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
                <th className="p-3">Tipo</th>
                <th className="p-3">País</th>
                <th className="p-3">Entrada</th>
                <th className="p-3">Salida</th>
                <th className="p-3 text-right">Habitación (Bs)</th>
              </tr>
            </thead>
            <tbody>
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
