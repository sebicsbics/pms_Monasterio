import { useState } from 'react'
import { Search } from 'lucide-react'
import { lookupGuestByDocument } from '../../services/guests'
import { guestPrefill, type GuestPrefill } from '../../domain/guests/guestProfile'

// Campo de documento / pasaporte con búsqueda en la base.
//
// El documento es la llave del huésped (guests.passport_number, único).
// Un huésped que vuelve ya está cargado: volver a tipear su ficha entera
// es trabajo perdido y, peor, una fuente de fichas duplicadas mal
// escritas. El botón trae lo que ya sabemos y el recepcionista completa
// SOLO lo que cambia en esta estadía.
//
// Los campos circunstanciales del viaje (procedencia, motivo, transporte)
// nunca se precargan: los devuelve la RPC a propósito y se piden siempre.
export function DocumentLookupField({
  value,
  onChange,
  onFound,
  disabled = false,
  placeholder = 'Documento / Pasaporte',
  className = 'w-full rounded border border-slate-300 p-2 text-sm',
}: {
  value: string
  onChange: (document: string) => void
  onFound: (prefill: GuestPrefill) => void
  disabled?: boolean
  placeholder?: string
  className?: string
}) {
  const [busy, setBusy] = useState(false)
  const [status, setStatus] = useState<string | null>(null)
  const [notFound, setNotFound] = useState(false)

  async function search() {
    const doc = value.trim()
    if (!doc) {
      setNotFound(false)
      setStatus('Escribí el documento para buscarlo')
      return
    }
    setBusy(true)
    setStatus(null)
    try {
      const match = await lookupGuestByDocument(doc)
      if (!match) {
        setNotFound(true)
        setStatus('Huésped nuevo: no está en la base. Cargá sus datos.')
        return
      }
      onFound(guestPrefill(match))
      setNotFound(false)
      setStatus(
        `Huésped encontrado: ${match.firstName} ${match.lastName}. ` +
          'Revisá los datos y completá los del viaje.',
      )
    } catch (e) {
      setNotFound(false)
      setStatus((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div>
      <div className="flex gap-2">
        <input
          placeholder={placeholder}
          value={value}
          onChange={(e) => {
            onChange(e.target.value)
            setStatus(null)
            setNotFound(false)
          }}
          // Enter busca en vez de mandar el formulario: es lo que hace la
          // mano del recepcionista después de tipear el documento.
          onKeyDown={(e) => {
            if (e.key === 'Enter') {
              e.preventDefault()
              void search()
            }
          }}
          className={className}
        />
        <button
          type="button"
          onClick={() => void search()}
          disabled={disabled || busy}
          title="Buscar huésped por documento"
          className="inline-flex shrink-0 items-center gap-1 rounded border border-slate-300
            px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50"
        >
          <Search size={14} />
          {busy ? 'Buscando…' : 'Buscar'}
        </button>
      </div>
      {status && (
        <p className={`mt-1 text-xs ${notFound ? 'text-slate-500' : 'text-brand-700'}`}>
          {status}
        </p>
      )}
    </div>
  )
}
