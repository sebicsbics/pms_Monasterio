import { useState } from 'react'
import { RoomBoard } from './features/room-board/RoomBoard'
import { InHouseList } from './features/in-house/InHouseList'
import { NewReservation } from './features/reservations/NewReservation'
import { ArrivalsList } from './features/arrivals/ArrivalsList'

type Tab = 'board' | 'arrivals' | 'inhouse' | 'reservation'

function App() {
  const [tab, setTab] = useState<Tab>('board')

  return (
    <div className="min-h-screen bg-slate-100">
      <nav className="flex gap-2 border-b border-slate-200 bg-white px-6 py-3">
        <button
          type="button"
          onClick={() => setTab('board')}
          className={`rounded px-3 py-1.5 text-sm font-medium ${
            tab === 'board'
              ? 'bg-slate-800 text-white'
              : 'text-slate-600 hover:bg-slate-100'
          }`}
        >
          Tablero
        </button>
        <button
          type="button"
          onClick={() => setTab('arrivals')}
          className={`rounded px-3 py-1.5 text-sm font-medium ${
            tab === 'arrivals'
              ? 'bg-slate-800 text-white'
              : 'text-slate-600 hover:bg-slate-100'
          }`}
        >
          Llegadas
        </button>
        <button
          type="button"
          onClick={() => setTab('inhouse')}
          className={`rounded px-3 py-1.5 text-sm font-medium ${
            tab === 'inhouse'
              ? 'bg-slate-800 text-white'
              : 'text-slate-600 hover:bg-slate-100'
          }`}
        >
          In-house
        </button>
        <button
          type="button"
          onClick={() => setTab('reservation')}
          className={`rounded px-3 py-1.5 text-sm font-medium ${
            tab === 'reservation'
              ? 'bg-slate-800 text-white'
              : 'text-slate-600 hover:bg-slate-100'
          }`}
        >
          Nueva reserva
        </button>
      </nav>

      {tab === 'board' && <RoomBoard />}
      {tab === 'arrivals' && <ArrivalsList />}
      {tab === 'inhouse' && <InHouseList />}
      {tab === 'reservation' && <NewReservation />}
    </div>
  )
}

export default App
