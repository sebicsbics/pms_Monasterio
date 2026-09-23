import { useState } from 'react'
import { PageHeader } from '../../components/ui'
import { HousekeepingBoardView } from './HousekeepingBoardView'
import { HousekeepingHistoryView } from './HousekeepingHistoryView'

type Sub = 'board' | 'history'

// Housekeeping: tablero del día (default) + historial de limpieza por
// habitación (change: housekeeping-assignment-notes). Mismo patrón de
// sub-tabs que InventoryView.
export function HousekeepingView() {
  const [sub, setSub] = useState<Sub>('board')

  const tabs: { id: Sub; label: string }[] = [
    { id: 'board', label: 'Tablero del día' },
    { id: 'history', label: 'Historial' },
  ]

  return (
    <div className="mx-auto max-w-5xl p-6">
      <PageHeader title="Housekeeping" />

      <div className="mb-6 flex gap-2 border-b border-slate-200">
        {tabs.map((t) => (
          <button
            key={t.id}
            type="button"
            onClick={() => setSub(t.id)}
            className={`-mb-px px-3 py-2 text-sm font-medium ${
              sub === t.id
                ? 'border-b-2 border-brand-600 text-brand-700'
                : 'text-slate-500 hover:text-slate-700'
            }`}
          >
            {t.label}
          </button>
        ))}
      </div>

      {sub === 'board' && <HousekeepingBoardView />}
      {sub === 'history' && <HousekeepingHistoryView />}
    </div>
  )
}
