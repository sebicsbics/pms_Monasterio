import { useEffect, useState } from 'react'
import {
  Bar,
  BarChart,
  CartesianGrid,
  Cell,
  Line,
  LineChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts'
import {
  fetchChannelMix,
  fetchCountryMix,
  fetchOccupancyByYear,
  fetchPaymentMix,
  fetchRevenueByYear,
  fetchRoomPerformance,
  fetchSeasonality,
  type ChannelMix,
  type CountryMix,
  type OccupancyByYear,
  type PaymentMix,
  type RevenueByYear,
  type RoomPerformance,
  type Seasonality,
} from '../../services/analytics'
import {
  CATEGORICAL,
  CHANNEL_COLOR,
  CHANNEL_LABEL,
  fmtBs,
  fmtInt,
  fmtPct,
  INK,
  MONTHS,
} from './palette'

const BLUE = CATEGORICAL[0]
const AXIS = { fill: INK.secondary, fontSize: 12 }

interface Data {
  revenue: RevenueByYear[]
  occupancy: OccupancyByYear[]
  seasonality: Seasonality[]
  channel: ChannelMix[]
  country: CountryMix[]
  payment: PaymentMix[]
  rooms: RoomPerformance[]
}

function StatTile({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div className="rounded-lg border border-slate-200 bg-white p-4 shadow-sm">
      <p className="text-xs font-medium uppercase tracking-wide text-slate-500">
        {label}
      </p>
      <p className="mt-1 text-2xl font-bold text-slate-800">{value}</p>
      {sub && <p className="text-xs text-slate-400">{sub}</p>}
    </div>
  )
}

function ChartCard({
  title,
  subtitle,
  children,
}: {
  title: string
  subtitle?: string
  children: React.ReactNode
}) {
  return (
    <div className="rounded-lg border border-slate-200 bg-white p-4 shadow-sm">
      <h3 className="text-sm font-semibold text-slate-700">{title}</h3>
      {subtitle && <p className="mb-2 text-xs text-slate-400">{subtitle}</p>}
      <div className="mt-2 h-64">
        <ResponsiveContainer width="100%" height="100%">
          {children as React.ReactElement}
        </ResponsiveContainer>
      </div>
    </div>
  )
}

// Tooltip único para todos los charts: rótulo + filas formateadas.
function Tip({
  active,
  payload,
  label,
  fmt,
}: {
  active?: boolean
  payload?: { name: string; value: number; color?: string }[]
  label?: string | number
  fmt: (n: number | null) => string
}) {
  if (!active || !payload?.length) return null
  return (
    <div className="rounded border border-slate-200 bg-white px-3 py-2 text-xs shadow-md">
      {label != null && <p className="mb-1 font-semibold text-slate-700">{label}</p>}
      {payload.map((p) => (
        <p key={p.name} className="text-slate-600">
          {p.name}: <span className="font-medium">{fmt(p.value)}</span>
        </p>
      ))}
    </div>
  )
}

export function Dashboard() {
  const [data, setData] = useState<Data | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    Promise.all([
      fetchRevenueByYear(),
      fetchOccupancyByYear(),
      fetchSeasonality(),
      fetchChannelMix(),
      fetchCountryMix(),
      fetchPaymentMix(),
      fetchRoomPerformance(),
    ])
      .then(([revenue, occupancy, seasonality, channel, country, payment, rooms]) =>
        setData({ revenue, occupancy, seasonality, channel, country, payment, rooms }),
      )
      .catch((e: Error) => setError(e.message))
  }, [])

  if (error) {
    return (
      <div className="mx-auto max-w-6xl p-6">
        <p className="rounded bg-red-50 p-3 text-sm text-red-700">
          Error cargando analíticas: {error}
        </p>
        <p className="mt-2 text-xs text-slate-500">
          ¿Aplicaste las migraciones de historical_stays y las vistas v_*?
        </p>
      </div>
    )
  }
  if (!data) {
    return <p className="p-8 text-slate-500">Cargando analíticas…</p>
  }

  const totalIngreso = data.revenue.reduce((s, r) => s + r.ingresoBs, 0)
  const totalEstadias = data.revenue.reduce((s, r) => s + r.estadias, 0)
  const totalNoches = data.revenue.reduce((s, r) => s + r.noches, 0)
  const adrGlobal = totalNoches ? totalIngreso / totalNoches : 0
  const ocupProm = data.occupancy.length
    ? data.occupancy.reduce((s, o) => s + o.ocupacionPct, 0) / data.occupancy.length
    : 0

  const channelData = data.channel.map((c) => ({
    ...c,
    label: CHANNEL_LABEL[c.channelCode] ?? c.channelCode,
    fill: CHANNEL_COLOR[c.channelCode] ?? '#9a9992',
  }))

  return (
    <div className="mx-auto max-w-6xl p-6">
      <header className="mb-6">
        <h1 className="text-2xl font-bold text-slate-800">
          Analítica histórica · Hotel Monasterio
        </h1>
        <p className="text-sm text-slate-500">
          {fmtInt(totalEstadias)} estadías procesadas del histórico (2015–2025)
        </p>
      </header>

      {/* Hero numbers */}
      <div className="mb-6 grid grid-cols-2 gap-3 md:grid-cols-4">
        <StatTile label="Ingreso total" value={fmtBs(totalIngreso)} />
        <StatTile label="Estadías" value={fmtInt(totalEstadias)} />
        <StatTile label="ADR promedio" value={fmtBs(adrGlobal)} sub="ingreso / noche" />
        <StatTile label="Ocupación media" value={fmtPct(ocupProm)} sub="sobre 36 hab." />
      </div>

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
        {/* Ingreso por año */}
        <ChartCard title="Ingreso por año" subtitle="Bs">
          <BarChart data={data.revenue} margin={{ top: 8, right: 8, bottom: 0, left: 8 }}>
            <CartesianGrid stroke={INK.grid} vertical={false} />
            <XAxis dataKey="year" tick={AXIS} tickLine={false} axisLine={{ stroke: INK.grid }} />
            <YAxis tick={AXIS} tickLine={false} axisLine={false} width={54}
              tickFormatter={(v) => `${Math.round(v / 1000)}k`} />
            <Tooltip content={<Tip fmt={fmtBs} />} cursor={{ fill: '#0000000a' }} />
            <Bar dataKey="ingresoBs" name="Ingreso" fill={BLUE} radius={[4, 4, 0, 0]} maxBarSize={38} />
          </BarChart>
        </ChartCard>

        {/* ADR por año */}
        <ChartCard title="Tarifa media diaria (ADR) por año" subtitle="Bs / noche">
          <LineChart data={data.revenue} margin={{ top: 8, right: 12, bottom: 0, left: 8 }}>
            <CartesianGrid stroke={INK.grid} vertical={false} />
            <XAxis dataKey="year" tick={AXIS} tickLine={false} axisLine={{ stroke: INK.grid }} />
            <YAxis tick={AXIS} tickLine={false} axisLine={false} width={46} />
            <Tooltip content={<Tip fmt={fmtBs} />} />
            <Line dataKey="adrBs" name="ADR" stroke={BLUE} strokeWidth={2} dot={{ r: 3 }} connectNulls />
          </LineChart>
        </ChartCard>

        {/* Ocupación por año */}
        <ChartCard title="Ocupación por año" subtitle="% sobre 36 habitaciones">
          <LineChart data={data.occupancy} margin={{ top: 8, right: 12, bottom: 0, left: 8 }}>
            <CartesianGrid stroke={INK.grid} vertical={false} />
            <XAxis dataKey="year" tick={AXIS} tickLine={false} axisLine={{ stroke: INK.grid }} />
            <YAxis tick={AXIS} tickLine={false} axisLine={false} width={40}
              tickFormatter={(v) => `${v}%`} />
            <Tooltip content={<Tip fmt={fmtPct} />} />
            <Line dataKey="ocupacionPct" name="Ocupación" stroke={CATEGORICAL[1]}
              strokeWidth={2} dot={{ r: 3 }} />
          </LineChart>
        </ChartCard>

        {/* Estacionalidad */}
        <ChartCard title="Estacionalidad" subtitle="Estadías por mes (todos los años)">
          <BarChart data={data.seasonality} margin={{ top: 8, right: 8, bottom: 0, left: 8 }}>
            <CartesianGrid stroke={INK.grid} vertical={false} />
            <XAxis dataKey="month" tick={AXIS} tickLine={false} axisLine={{ stroke: INK.grid }}
              tickFormatter={(m) => MONTHS[m] ?? m} />
            <YAxis tick={AXIS} tickLine={false} axisLine={false} width={40} />
            <Tooltip content={<Tip fmt={fmtInt} />}
              labelFormatter={(m) => MONTHS[m as number] ?? m} cursor={{ fill: '#0000000a' }} />
            <Bar dataKey="estadias" name="Estadías" fill={BLUE} radius={[4, 4, 0, 0]} maxBarSize={30} />
          </BarChart>
        </ChartCard>

        {/* Mix de canal — color por identidad de canal */}
        <ChartCard title="Mix de canal" subtitle="Estadías por canal de venta">
          <BarChart data={channelData} layout="vertical" margin={{ top: 4, right: 12, bottom: 0, left: 8 }}>
            <CartesianGrid stroke={INK.grid} horizontal={false} />
            <XAxis type="number" tick={AXIS} tickLine={false} axisLine={false} />
            <YAxis type="category" dataKey="label" tick={AXIS} tickLine={false}
              axisLine={false} width={110} />
            <Tooltip content={<Tip fmt={fmtInt} />} cursor={{ fill: '#0000000a' }} />
            <Bar dataKey="estadias" name="Estadías" radius={[0, 4, 4, 0]} maxBarSize={22}>
              {channelData.map((c) => <Cell key={c.channelCode} fill={c.fill} />)}
            </Bar>
          </BarChart>
        </ChartCard>

        {/* Mix de pago */}
        <ChartCard title="Formas de pago" subtitle="Estadías por método">
          <BarChart data={data.payment.slice(0, 8)} layout="vertical"
            margin={{ top: 4, right: 12, bottom: 0, left: 8 }}>
            <CartesianGrid stroke={INK.grid} horizontal={false} />
            <XAxis type="number" tick={AXIS} tickLine={false} axisLine={false} />
            <YAxis type="category" dataKey="payment" tick={AXIS} tickLine={false}
              axisLine={false} width={110} />
            <Tooltip content={<Tip fmt={fmtInt} />} cursor={{ fill: '#0000000a' }} />
            <Bar dataKey="estadias" name="Estadías" fill={BLUE} radius={[0, 4, 4, 0]} maxBarSize={22} />
          </BarChart>
        </ChartCard>

        {/* Origen del huésped */}
        <ChartCard title="Origen del huésped" subtitle="Top países (donde hay dato)">
          <BarChart data={data.country} layout="vertical"
            margin={{ top: 4, right: 12, bottom: 0, left: 8 }}>
            <CartesianGrid stroke={INK.grid} horizontal={false} />
            <XAxis type="number" tick={AXIS} tickLine={false} axisLine={false} />
            <YAxis type="category" dataKey="country" tick={AXIS} tickLine={false}
              axisLine={false} width={110} />
            <Tooltip content={<Tip fmt={fmtInt} />} cursor={{ fill: '#0000000a' }} />
            <Bar dataKey="estadias" name="Estadías" fill={BLUE} radius={[0, 4, 4, 0]} maxBarSize={20} />
          </BarChart>
        </ChartCard>

        {/* Rendimiento por habitación */}
        <ChartCard title="Top habitaciones por ingreso" subtitle="Bs">
          <BarChart data={data.rooms} layout="vertical"
            margin={{ top: 4, right: 12, bottom: 0, left: 8 }}>
            <CartesianGrid stroke={INK.grid} horizontal={false} />
            <XAxis type="number" tick={AXIS} tickLine={false} axisLine={false}
              tickFormatter={(v) => `${Math.round(v / 1000)}k`} />
            <YAxis type="category" dataKey="room" tick={AXIS} tickLine={false}
              axisLine={false} width={48} tickFormatter={(r) => `Hab ${r}`} />
            <Tooltip content={<Tip fmt={fmtBs} />}
              labelFormatter={(r) => `Habitación ${r}`} cursor={{ fill: '#0000000a' }} />
            <Bar dataKey="ingresoBs" name="Ingreso" fill={BLUE} radius={[0, 4, 4, 0]} maxBarSize={20} />
          </BarChart>
        </ChartCard>
      </div>
    </div>
  )
}
