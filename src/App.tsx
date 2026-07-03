import { useCallback, useEffect, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase } from './services/supabase'
import { getProfile, signOut } from './services/auth'
import type { Profile, UserRole } from './domain/auth/profile'
import { ROLE_LABEL } from './domain/auth/profile'
import { Login } from './features/auth/Login'
import { ChangePassword } from './features/auth/ChangePassword'
import { RoomBoard } from './features/room-board/RoomBoard'
import { ArrivalsList } from './features/arrivals/ArrivalsList'
import { InHouseList } from './features/in-house/InHouseList'
import { NewReservation } from './features/reservations/NewReservation'
import { InventoryView } from './features/inventory/InventoryView'
import { EmployeesView } from './features/employees/EmployeesView'

type Tab =
  | 'board'
  | 'arrivals'
  | 'inhouse'
  | 'reservation'
  | 'inventory'
  | 'employees'

// Navegación declarativa con los roles que pueden ver cada sección.
// Operativo = recepción; financiero/consulta = contaduría; root ve todo.
// (El futuro módulo de empleados iría con roles: ['root', 'accountant'].)
const OPERATIONS: UserRole[] = ['root', 'reception']
const SHARED: UserRole[] = ['root', 'accountant', 'reception']
const FINANCE: UserRole[] = ['root', 'accountant']
const TABS: { id: Tab; label: string; roles: UserRole[] }[] = [
  { id: 'board', label: 'Tablero', roles: SHARED },
  { id: 'arrivals', label: 'Llegadas', roles: OPERATIONS },
  { id: 'inhouse', label: 'In-house', roles: SHARED },
  { id: 'reservation', label: 'Nueva reserva', roles: OPERATIONS },
  { id: 'inventory', label: 'Inventario', roles: SHARED },
  { id: 'employees', label: 'Empleados', roles: FINANCE },
]

function App() {
  const [session, setSession] = useState<Session | null>(null)
  const [profile, setProfile] = useState<Profile | null>(null)
  const [authLoading, setAuthLoading] = useState(true)
  const [tab, setTab] = useState<Tab>('board')

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session)
      setAuthLoading(false)
    })
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) =>
      setSession(s),
    )
    return () => sub.subscription.unsubscribe()
  }, [])

  const reloadProfile = useCallback(() => {
    if (session?.user) {
      getProfile(session.user.id)
        .then(setProfile)
        .catch(() => setProfile(null))
    } else {
      setProfile(null)
    }
  }, [session])

  useEffect(() => {
    reloadProfile()
  }, [reloadProfile])

  if (authLoading) {
    return <p className="p-8 text-slate-500">Cargando…</p>
  }
  if (!session) {
    return <Login />
  }
  if (!profile) {
    return <p className="p-8 text-slate-500">Cargando perfil…</p>
  }
  if (profile.mustChangePassword) {
    return <ChangePassword onDone={reloadProfile} />
  }

  const role = profile?.role
  const visibleTabs = TABS.filter((t) => role && t.roles.includes(role))
  const activeTab = visibleTabs.some((t) => t.id === tab)
    ? tab
    : visibleTabs[0]?.id

  return (
    <div className="min-h-screen bg-slate-100">
      <nav className="flex flex-wrap items-center gap-2 border-b border-slate-200 bg-white px-6 py-3">
        {visibleTabs.map((t) => (
          <button
            key={t.id}
            type="button"
            onClick={() => setTab(t.id)}
            className={`rounded px-3 py-1.5 text-sm font-medium ${
              activeTab === t.id
                ? 'bg-slate-800 text-white'
                : 'text-slate-600 hover:bg-slate-100'
            }`}
          >
            {t.label}
          </button>
        ))}

        <div className="ml-auto flex items-center gap-3 text-sm text-slate-500">
          <span>
            {session.user.email}
            {role && (
              <span className="ml-2 rounded bg-slate-200 px-2 py-0.5 text-xs text-slate-700">
                {ROLE_LABEL[role]}
              </span>
            )}
          </span>
          <button
            type="button"
            onClick={() => signOut()}
            className="rounded border border-slate-300 px-3 py-1 hover:bg-slate-100"
          >
            Salir
          </button>
        </div>
      </nav>

      {activeTab === 'board' && <RoomBoard />}
      {activeTab === 'arrivals' && <ArrivalsList />}
      {activeTab === 'inhouse' && <InHouseList />}
      {activeTab === 'reservation' && <NewReservation />}
      {activeTab === 'inventory' && <InventoryView />}
      {activeTab === 'employees' && <EmployeesView />}
    </div>
  )
}

export default App
