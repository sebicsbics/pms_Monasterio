import { lazy, Suspense, useCallback, useEffect, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  BarChart3,
  BedDouble,
  CalendarPlus,
  Clock,
  DoorOpen,
  KeyRound,
  LayoutGrid,
  ListChecks,
  LogOut,
  Menu,
  Package,
  PartyPopper,
  Percent,
  User,
  Users,
  Wallet,
  Wrench,
  type LucideIcon,
} from 'lucide-react'
import { supabase } from './services/supabase'
import { getProfile, signOut } from './services/auth'
import type { Profile, UserRole } from './domain/auth/profile'
import { ROLE_LABEL } from './domain/auth/profile'
import { ANTICIPOS_ADMIN, DISCOUNT_APPROVAL, FINANCE, HOUSEKEEPING, OPERATIONS, SHARED } from './domain/auth/roleGroups'
import { Login } from './features/auth/Login'
import { ChangePassword } from './features/auth/ChangePassword'
import { RoomBoard } from './features/room-board/RoomBoard'
import { ArrivalsList } from './features/arrivals/ArrivalsList'
import { InHouseList } from './features/in-house/InHouseList'
import { NewReservation } from './features/reservations/NewReservation'
import { InventoryView } from './features/inventory/InventoryView'
import { EmployeesView } from './features/employees/EmployeesView'
import { TasksView } from './features/tasks/TasksView'
import { MaintenanceView } from './features/maintenance/MaintenanceView'
import { AccessLogView } from './features/attendance/AccessLogView'
import { FichajeView } from './features/attendance/FichajeView'
import { MyProfileView } from './features/profile/MyProfileView'
import { CajaView } from './features/cash/CajaView'
import { EventsView } from './features/events/EventsView'
import { HousekeepingBoardView } from './features/housekeeping/HousekeepingBoardView'
import { DiscountApprovalQueueView } from './features/reception/DiscountApprovalQueueView'
import { RecordAnticipoView } from './features/anticipos/RecordAnticipoView'
import { AnticipoAdminView } from './features/anticipos/AnticipoAdminView'

// Analítica carga Recharts (pesado): se trae solo al abrir el tab (lazy).
const Dashboard = lazy(() =>
  import('./features/analytics/Dashboard').then((m) => ({ default: m.Dashboard })),
)

type Tab =
  | 'board' | 'arrivals' | 'inhouse' | 'reservation' | 'inventory'
  | 'employees' | 'tasks' | 'housekeeping' | 'maintenance' | 'fichaje' | 'profile'
  | 'access' | 'dashboard' | 'caja' | 'events' | 'discounts' | 'anticipos' | 'anticipos-admin'


type Group = 'Operación' | 'Personal' | 'Gestión'
const GROUP_ORDER: Group[] = ['Operación', 'Personal', 'Gestión']

// Navegación declarativa: sección, roles, icono y grupo.
const TABS: {
  id: Tab; label: string; roles: UserRole[]; icon: LucideIcon; group: Group
}[] = [
  { id: 'board', label: 'Tablero', roles: SHARED, icon: LayoutGrid, group: 'Operación' },
  { id: 'arrivals', label: 'Llegadas', roles: OPERATIONS, icon: DoorOpen, group: 'Operación' },
  { id: 'inhouse', label: 'In-house', roles: SHARED, icon: BedDouble, group: 'Operación' },
  { id: 'reservation', label: 'Nueva reserva', roles: OPERATIONS, icon: CalendarPlus, group: 'Operación' },
  { id: 'inventory', label: 'Inventario', roles: SHARED, icon: Package, group: 'Operación' },
  { id: 'caja', label: 'Caja chica', roles: SHARED, icon: Wallet, group: 'Operación' },
  { id: 'events', label: 'Eventos', roles: SHARED, icon: PartyPopper, group: 'Operación' },
  { id: 'tasks', label: 'Tareas', roles: OPERATIONS, icon: ListChecks, group: 'Operación' },
  { id: 'housekeeping', label: 'Housekeeping', roles: HOUSEKEEPING, icon: BedDouble, group: 'Operación' },
  { id: 'maintenance', label: 'Mantenimiento', roles: SHARED, icon: Wrench, group: 'Operación' },
  { id: 'fichaje', label: 'Fichaje', roles: SHARED, icon: Clock, group: 'Personal' },
  { id: 'profile', label: 'Mi perfil', roles: SHARED, icon: User, group: 'Personal' },
  { id: 'employees', label: 'Empleados', roles: FINANCE, icon: Users, group: 'Gestión' },
  { id: 'access', label: 'Accesos', roles: FINANCE, icon: KeyRound, group: 'Gestión' },
  { id: 'dashboard', label: 'Analítica', roles: FINANCE, icon: BarChart3, group: 'Gestión' },
  { id: 'discounts', label: 'Descuentos', roles: DISCOUNT_APPROVAL, icon: Percent, group: 'Gestión' },
  { id: 'anticipos', label: 'Anticipos', roles: OPERATIONS, icon: Wallet, group: 'Operación' },
  { id: 'anticipos-admin', label: 'Corregir anticipos', roles: ANTICIPOS_ADMIN, icon: Wallet, group: 'Gestión' },
]

function App() {
  const [session, setSession] = useState<Session | null>(null)
  const [profile, setProfile] = useState<Profile | null>(null)
  const [authLoading, setAuthLoading] = useState(true)
  const [tab, setTab] = useState<Tab>('board')
  const [navOpen, setNavOpen] = useState(false)

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session)
      setAuthLoading(false)
    })
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => setSession(s))
    return () => sub.subscription.unsubscribe()
  }, [])

  const reloadProfile = useCallback(() => {
    if (session?.user) {
      getProfile(session.user.id).then(setProfile).catch(() => setProfile(null))
    } else {
      setProfile(null)
    }
  }, [session])

  useEffect(() => {
    reloadProfile()
  }, [reloadProfile])

  if (authLoading) return <p className="p-8 text-slate-500">Cargando…</p>
  if (!session) return <Login />
  if (!profile) return <p className="p-8 text-slate-500">Cargando perfil…</p>
  if (profile.mustChangePassword) return <ChangePassword onDone={reloadProfile} />

  const role = profile.role
  const visibleTabs = TABS.filter((t) => role && t.roles.includes(role))
  const activeTab = visibleTabs.some((t) => t.id === tab) ? tab : visibleTabs[0]?.id

  function go(id: Tab) {
    setTab(id)
    setNavOpen(false)
  }

  const nav = (
    <nav className="flex h-full flex-col">
      <div className="flex items-center gap-3 px-5 py-5">
        <img src="/brand/logo-mark.png" alt="" className="h-9 w-auto" />
        <div className="leading-tight">
          <p className="text-sm font-bold text-slate-800">Hotel Monasterio</p>
          <p className="text-xs text-slate-400">PMS</p>
        </div>
      </div>

      <div className="flex-1 overflow-y-auto px-3 pb-4">
        {GROUP_ORDER.map((group) => {
          const items = visibleTabs.filter((t) => t.group === group)
          if (items.length === 0) return null
          return (
            <div key={group} className="mb-4">
              <p className="px-3 pb-1 text-xs font-semibold uppercase tracking-wide text-slate-400">
                {group}
              </p>
              {items.map((t) => {
                const Icon = t.icon
                const active = activeTab === t.id
                return (
                  <button
                    key={t.id}
                    type="button"
                    onClick={() => go(t.id)}
                    aria-current={active ? 'page' : undefined}
                    className={`mb-0.5 flex w-full items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium transition-colors ${
                      active
                        ? 'bg-brand-50 text-brand-700'
                        : 'text-slate-600 hover:bg-slate-100'
                    }`}
                  >
                    <Icon size={18} className={active ? 'text-brand-600' : 'text-slate-400'} />
                    {t.label}
                  </button>
                )
              })}
            </div>
          )
        })}
      </div>

      <div className="border-t border-slate-200 p-3">
        <div className="mb-2 px-2">
          <p className="truncate text-sm font-medium text-slate-700">{session.user.email}</p>
          {role && <p className="text-xs text-slate-400">{ROLE_LABEL[role]}</p>}
        </div>
        <button
          type="button"
          onClick={() => signOut()}
          className="flex w-full items-center gap-2 rounded-lg px-3 py-2 text-sm font-medium text-slate-600 hover:bg-slate-100"
        >
          <LogOut size={18} className="text-slate-400" />
          Salir
        </button>
      </div>
    </nav>
  )

  return (
    <div className="min-h-dvh bg-slate-50">
      {/* Sidebar fijo en desktop */}
      <aside className="fixed inset-y-0 left-0 z-40 hidden w-60 border-r border-slate-200 bg-white lg:block">
        {nav}
      </aside>

      {/* Drawer en móvil */}
      {navOpen && (
        <>
          <div
            className="fixed inset-0 z-40 bg-black/40 lg:hidden"
            onClick={() => setNavOpen(false)}
            aria-hidden
          />
          <aside className="fixed inset-y-0 left-0 z-50 w-60 border-r border-slate-200 bg-white lg:hidden">
            {nav}
          </aside>
        </>
      )}

      {/* Topbar móvil */}
      <div className="sticky top-0 z-30 flex items-center gap-3 border-b border-slate-200 bg-white px-4 py-3 lg:hidden">
        <button
          type="button"
          onClick={() => setNavOpen(true)}
          aria-label="Abrir menú"
          className="rounded-lg p-1.5 text-slate-600 hover:bg-slate-100"
        >
          <Menu size={22} />
        </button>
        <span className="font-semibold text-slate-800">
          {visibleTabs.find((t) => t.id === activeTab)?.label ?? 'Hotel Monasterio'}
        </span>
      </div>

      {/* Contenido */}
      <main className="lg:pl-60">
        {activeTab === 'board' && <RoomBoard role={role} />}
        {activeTab === 'arrivals' && <ArrivalsList role={role} />}
        {activeTab === 'inhouse' && <InHouseList />}
        {activeTab === 'reservation' && <NewReservation />}
        {activeTab === 'inventory' && <InventoryView />}
        {activeTab === 'employees' && <EmployeesView role={role} />}
        {activeTab === 'tasks' && <TasksView />}
        {activeTab === 'housekeeping' && <HousekeepingBoardView />}
        {activeTab === 'maintenance' && <MaintenanceView role={role} />}
        {activeTab === 'fichaje' && <FichajeView userId={session.user.id} role={role} />}
        {activeTab === 'profile' && <MyProfileView userId={session.user.id} />}
        {activeTab === 'caja' && <CajaView role={role} />}
        {activeTab === 'events' && <EventsView />}
        {activeTab === 'access' && <AccessLogView />}
        {activeTab === 'discounts' && <DiscountApprovalQueueView role={role} />}
        {activeTab === 'anticipos' && <RecordAnticipoView />}
        {activeTab === 'anticipos-admin' && <AnticipoAdminView role={role} />}
        {activeTab === 'dashboard' && (
          <Suspense fallback={<p className="p-8 text-slate-500">Cargando analíticas…</p>}>
            <Dashboard />
          </Suspense>
        )}
      </main>
    </div>
  )
}

export default App
