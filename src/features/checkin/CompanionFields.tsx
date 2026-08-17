import type { CompanionGuest } from '../../services/arrivals'
import { COUNTRIES } from '../../shared/data/countries'
import { TRAVEL_PURPOSES } from '../../shared/data/travelPurposes'
import { DocumentLookupField } from './DocumentLookupField'

const INPUT = 'w-full rounded border border-slate-300 p-2 text-sm'

// Campos de un acompañante, compartidos por el check-in de Llegadas y el
// walk-in del tablero. Si está marcado "menor de 14" se ocultan los datos
// de adulto (documento, procedencia, motivo, ocupación, transporte): a los
// menores solo se les pide nombre, apellido y fecha de nacimiento.
export function CompanionFields({
  companion,
  onChange,
}: {
  companion: CompanionGuest
  onChange: (patch: Partial<CompanionGuest>) => void
}) {
  const g = companion
  return (
    <>
      <div className="flex gap-2">
        <input
          placeholder="Nombre"
          value={g.firstName}
          onChange={(e) => onChange({ firstName: e.target.value })}
          className="w-1/2 rounded border border-slate-300 p-2 text-sm"
        />
        <input
          placeholder="Apellido"
          value={g.lastName}
          onChange={(e) => onChange({ lastName: e.target.value })}
          className="w-1/2 rounded border border-slate-300 p-2 text-sm"
        />
      </div>

      <label className="flex items-center gap-2 text-xs text-slate-600">
        <input
          type="checkbox"
          checked={g.isMinor}
          onChange={(e) => onChange({ isMinor: e.target.checked })}
        />
        Menor de 14 años
      </label>

      <label className="block text-xs text-slate-500">
        Fecha de nacimiento
        <input
          type="date"
          value={g.birthDate}
          onChange={(e) => onChange({ birthDate: e.target.value })}
          className="mt-1 w-full rounded border border-slate-300 p-2 text-sm"
        />
      </label>

      {!g.isMinor && (
        <>
          {/* El documento es la llave del huésped: si ya vino antes, se
              trae su ficha en vez de tipearla de nuevo. */}
          <DocumentLookupField
            value={g.document}
            onChange={(document) => onChange({ document })}
            onFound={(p) =>
              onChange({
                firstName: p.firstName,
                lastName: p.lastName,
                birthDate: p.birthDate,
                countryCode: p.countryCode,
                city: p.city,
                occupation: p.occupation,
              })
            }
            className={INPUT}
          />
          <div className="flex gap-2">
            <select
              value={g.countryCode}
              onChange={(e) => onChange({ countryCode: e.target.value })}
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
              placeholder="Ciudad de residencia"
              value={g.city}
              onChange={(e) => onChange({ city: e.target.value })}
              className="w-1/2 rounded border border-slate-300 p-2 text-sm"
            />
          </div>
          <input
            placeholder="Ciudad de procedencia"
            value={g.originCity}
            onChange={(e) => onChange({ originCity: e.target.value })}
            className={INPUT}
          />
          <select
            value={g.travelPurpose}
            onChange={(e) => onChange({ travelPurpose: e.target.value })}
            className={`${INPUT} text-slate-700`}
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
              onChange={(e) => onChange({ occupation: e.target.value })}
              className="w-1/2 rounded border border-slate-300 p-2 text-sm"
            />
            <input
              placeholder="Transporte"
              value={g.transportMeans}
              onChange={(e) => onChange({ transportMeans: e.target.value })}
              className="w-1/2 rounded border border-slate-300 p-2 text-sm"
            />
          </div>
        </>
      )}
    </>
  )
}
