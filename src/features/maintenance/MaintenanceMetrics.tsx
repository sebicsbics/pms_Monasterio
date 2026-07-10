import { useEffect, useState } from 'react'
import {
  Bar,
  BarChart,
  CartesianGrid,
  Cell,
  Legend,
  Line,
  LineChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts'
import {
  fetchMtActiveByPriority,
  fetchMtByCategory,
  fetchMtKpis,
  fetchMtResponseByMonth,
  fetchMtSpendByMonth,
  type MtActiveByPriority,
  type MtByCategory,
  type MtKpis,
  type MtResponseByMonth,
  type MtSpendByMonth,
} from '../../services/maintenance'
import { PRIORITY_LABEL, type TicketPriority } from '../../domain/maintenance/ticket'
import { CATEGORICAL, fmtBs, fmtInt, INK } from '../analytics/palette'

const BLUE = CATEGORICAL[0]
const VIOLET = CATEGORICAL[4]
const AXIS = { fill: INK.secondary, fontSize: 12 }
const fmtH = (n: number | null) => (n == null ? '—' : `${n} h`)

const PRIORITY_COLOR: Record<TicketPriority, string> = {
  low: '#9a9992',
  medium: CATEGORICAL[0],
  high: CATEGORICAL[7],
  urgent: CATEGORICAL[5],
}

function Tile({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div className="rounded-lg border border-slate-200 bg-white p-4 shadow-sm">
      <p className="text-xs font-medium uppercase tracking-wide text-slate-500">{label}</p>
      <p className="mt-1 text-2xl font-bold text-slate-800">{value}</p>
      {sub && <p className="text-xs text-slate-400">{sub}</p>}
    </div>
  )
}

function Card({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="rounded-lg border border-slate-200 bg-white p-4 shadow-sm">
      <h3 className="mb-2 text-sm font-semibold text-slate-700">{title}</h3>
      <div className="h-56">
        <ResponsiveContainer width="100%" height="100%">
          {children as React.ReactElement}
        </ResponsiveContainer>
      </div>
    </div>
  )
}

interface TipRow { name: string; value: number; color?: string }
function Tip({ active, payload, label, fmt }: {
  active?: boolean; payload?: TipRow[]; label?: string | number
  fmt: (n: number | null) => string
}) {
  if (!active || !payload?.length) return null
  return (
    <div className="rounded border border-slate-200 bg-white px-3 py-2 text-xs shadow-md">
      {label != null && <p className="mb-1 font-semibold text-slate-700">{label}</p>}
      {payload.map((p) => (
        <p key={p.name} style={{ color: p.color }}>
          {p.name}: <span className="font-medium">{fmt(p.value)}</span>
        </p>
      ))}
    </div>
  )
}

export function MaintenanceMetrics() {
  const [kpis, setKpis] = useState<MtKpis | null>(null)
  const [byMonth, setByMonth] = useState<MtResponseByMonth[]>([])
  const [spend, setSpend] = useState<MtSpendByMonth[]>([])
  const [byCat, setByCat] = useState<MtByCategory[]>([])
  const [byPrio, setByPrio] = useState<MtActiveByPriority[]>([])
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    Promise.all([
      fetchMtKpis(),
      fetchMtResponseByMonth(),
      fetchMtSpendByMonth(),
      fetchMtByCategory(),
      fetchMtActiveByPriority(),
    ])
      .then(([k, m, s, c, p]) => {
        setKpis(k)
        setByMonth(m)
        setSpend(s)
        setByCat(c)
        setByPrio(p.map((x) => ({ ...x, label: PRIORITY_LABEL[x.priority] })))
      })
      .catch((e: Error) => setError(e.message))
      .finally(() => setLoading(false))
  }, [])

  if (error) {
    return (
      <p className="rounded bg-red-50 p-3 text-sm text-red-700">
        Error cargando métricas: {error}. ¿Aplicaste la migración de vistas v_mt_*?
      </p>
    )
  }
  if (loading || !kpis) return <p className="p-8 text-slate-500">Cargando métricas…</p>

  const gastoTotal = spend.reduce((s, m) => s + m.gastoBs, 0)
  const prioData = byPrio as (MtActiveByPriority & { label: string })[]

  return (
    <div>
      <div className="mb-6 grid grid-cols-2 gap-3 md:grid-cols-4">
        <Tile label="Tickets activos" value={fmtInt(kpis.activos)} sub={`${kpis.totalTickets} en total`} />
        <Tile label="Resp. promedio" value={fmtH(kpis.horasRespuestaProm)} sub="reportado → atendido" />
        <Tile label="Resol. promedio" value={fmtH(kpis.horasResolucionProm)} sub="reportado → resuelto" />
        <Tile label="Gasto repuestos" value={fmtBs(gastoTotal)} sub="acumulado" />
      </div>

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
        <Card title="Tiempos de respuesta y resolución por mes (horas)">
          <LineChart data={byMonth} margin={{ top: 8, right: 12, bottom: 0, left: 8 }}>
            <CartesianGrid stroke={INK.grid} vertical={false} />
            <XAxis dataKey="month" tick={AXIS} tickLine={false} axisLine={{ stroke: INK.grid }} />
            <YAxis tick={AXIS} tickLine={false} axisLine={false} width={40} />
            <Tooltip content={<Tip fmt={fmtH} />} />
            <Legend wrapperStyle={{ fontSize: 12 }} />
            <Line dataKey="horasRespuesta" name="Respuesta" stroke={BLUE} strokeWidth={2} dot={{ r: 3 }} connectNulls />
            <Line dataKey="horasResolucion" name="Resolución" stroke={VIOLET} strokeWidth={2} dot={{ r: 3 }} connectNulls />
          </LineChart>
        </Card>

        <Card title="Gasto en repuestos por mes (Bs)">
          <BarChart data={spend} margin={{ top: 8, right: 8, bottom: 0, left: 8 }}>
            <CartesianGrid stroke={INK.grid} vertical={false} />
            <XAxis dataKey="month" tick={AXIS} tickLine={false} axisLine={{ stroke: INK.grid }} />
            <YAxis tick={AXIS} tickLine={false} axisLine={false} width={46} />
            <Tooltip content={<Tip fmt={fmtBs} />} cursor={{ fill: '#0000000a' }} />
            <Bar dataKey="gastoBs" name="Gasto" fill={BLUE} radius={[4, 4, 0, 0]} maxBarSize={38} />
          </BarChart>
        </Card>

        <Card title="Tickets por categoría">
          <BarChart data={byCat} layout="vertical" margin={{ top: 4, right: 12, bottom: 0, left: 8 }}>
            <CartesianGrid stroke={INK.grid} horizontal={false} />
            <XAxis type="number" tick={AXIS} tickLine={false} axisLine={false} />
            <YAxis type="category" dataKey="categoria" tick={AXIS} tickLine={false} axisLine={false} width={130} />
            <Tooltip content={<Tip fmt={fmtInt} />} cursor={{ fill: '#0000000a' }} />
            <Bar dataKey="tickets" name="Tickets" fill={BLUE} radius={[0, 4, 4, 0]} maxBarSize={20} />
          </BarChart>
        </Card>

        <Card title="Tickets activos por prioridad">
          <BarChart data={prioData} margin={{ top: 8, right: 8, bottom: 0, left: 8 }}>
            <CartesianGrid stroke={INK.grid} vertical={false} />
            <XAxis dataKey="label" tick={AXIS} tickLine={false} axisLine={{ stroke: INK.grid }} />
            <YAxis tick={AXIS} tickLine={false} axisLine={false} width={34} allowDecimals={false} />
            <Tooltip content={<Tip fmt={fmtInt} />} cursor={{ fill: '#0000000a' }} />
            <Bar dataKey="tickets" name="Tickets" radius={[4, 4, 0, 0]} maxBarSize={48}>
              {prioData.map((d) => <Cell key={d.priority} fill={PRIORITY_COLOR[d.priority]} />)}
            </Bar>
          </BarChart>
        </Card>
      </div>
    </div>
  )
}
