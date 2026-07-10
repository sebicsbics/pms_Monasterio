import { supabase } from './supabase'

// Filas de las vistas analíticas (public.v_*). Números que Postgres devuelve
// como string en algunos casos se normalizan a number en cada fetch.

export interface RevenueByYear {
  year: number
  estadias: number
  ingresoBs: number
  noches: number
  adrBs: number | null
}
export interface OccupancyByYear {
  year: number
  ocupacionPct: number
}
export interface Seasonality {
  month: number
  estadias: number
  ingresoBs: number
}
export interface ChannelMix {
  channelCode: string
  estadias: number
  ingresoBs: number
  ticketMedioBs: number | null
}
export interface CountryMix {
  country: string
  estadias: number
}
export interface PaymentMix {
  payment: string
  estadias: number
  ingresoBs: number
}
export interface RoomPerformance {
  room: number
  estadias: number
  ingresoBs: number
  adrBs: number | null
}

const num = (v: unknown): number => Number(v ?? 0)
const numOrNull = (v: unknown): number | null => (v == null ? null : Number(v))

async function rows<T>(view: string): Promise<T[]> {
  const { data, error } = await supabase.from(view).select('*')
  if (error) throw new Error(`${view}: ${error.message}`)
  return (data ?? []) as T[]
}

export async function fetchRevenueByYear(): Promise<RevenueByYear[]> {
  const r = await rows<Record<string, unknown>>('v_revenue_by_year')
  return r
    .map((x) => ({
      year: num(x.year),
      estadias: num(x.estadias),
      ingresoBs: num(x.ingreso_bs),
      noches: num(x.noches),
      adrBs: numOrNull(x.adr_bs),
    }))
    .sort((a, b) => a.year - b.year)
}

export async function fetchOccupancyByYear(): Promise<OccupancyByYear[]> {
  const r = await rows<Record<string, unknown>>('v_occupancy_by_year')
  return r
    .map((x) => ({ year: num(x.year), ocupacionPct: num(x.ocupacion_pct) }))
    .sort((a, b) => a.year - b.year)
}

export async function fetchSeasonality(): Promise<Seasonality[]> {
  const r = await rows<Record<string, unknown>>('v_seasonality')
  return r
    .map((x) => ({
      month: num(x.month),
      estadias: num(x.estadias),
      ingresoBs: num(x.ingreso_bs),
    }))
    .sort((a, b) => a.month - b.month)
}

export async function fetchChannelMix(): Promise<ChannelMix[]> {
  const r = await rows<Record<string, unknown>>('v_channel_mix')
  return r
    .map((x) => ({
      channelCode: String(x.channel_code),
      estadias: num(x.estadias),
      ingresoBs: num(x.ingreso_bs),
      ticketMedioBs: numOrNull(x.ticket_medio_bs),
    }))
    .sort((a, b) => b.estadias - a.estadias)
}

export async function fetchCountryMix(limit = 12): Promise<CountryMix[]> {
  const r = await rows<Record<string, unknown>>('v_country_mix')
  return r
    .map((x) => ({ country: String(x.country), estadias: num(x.estadias) }))
    .sort((a, b) => b.estadias - a.estadias)
    .slice(0, limit)
}

export async function fetchPaymentMix(): Promise<PaymentMix[]> {
  const r = await rows<Record<string, unknown>>('v_payment_mix')
  return r
    .map((x) => ({
      payment: String(x.payment),
      estadias: num(x.estadias),
      ingresoBs: num(x.ingreso_bs),
    }))
    .sort((a, b) => b.estadias - a.estadias)
}

export async function fetchRoomPerformance(limit = 12): Promise<RoomPerformance[]> {
  const r = await rows<Record<string, unknown>>('v_room_performance')
  return r
    .map((x) => ({
      room: num(x.room),
      estadias: num(x.estadias),
      ingresoBs: num(x.ingreso_bs),
      adrBs: numOrNull(x.adr_bs),
    }))
    .sort((a, b) => b.ingresoBs - a.ingresoBs)
    .slice(0, limit)
}
