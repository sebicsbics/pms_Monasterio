import type { ButtonHTMLAttributes, ReactNode, RefObject } from 'react'
import { Printer } from 'lucide-react'
import { printRegion } from '../lib/print'

// Sistema de componentes base. Un solo lugar de verdad para botones, tarjetas,
// badges y encabezados: consistencia visual + estados accesibles.

type ButtonVariant = 'primary' | 'secondary' | 'ghost' | 'danger'
type ButtonSize = 'sm' | 'md'

const BTN_BASE =
  'inline-flex items-center justify-center gap-2 rounded-lg font-medium ' +
  'transition-colors disabled:opacity-50 disabled:pointer-events-none ' +
  'focus-visible:outline-2 focus-visible:outline-offset-2 cursor-pointer'

const BTN_VARIANT: Record<ButtonVariant, string> = {
  primary: 'bg-brand-700 text-white hover:bg-brand-800',
  secondary: 'border border-slate-300 bg-white text-slate-700 hover:bg-slate-50',
  ghost: 'text-slate-600 hover:bg-slate-100',
  danger: 'border border-red-200 bg-white text-red-600 hover:bg-red-50',
}

const BTN_SIZE: Record<ButtonSize, string> = {
  sm: 'px-2.5 py-1.5 text-sm',
  md: 'px-4 py-2 text-sm',
}

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant
  size?: ButtonSize
  loading?: boolean
}

export function Button({
  variant = 'primary',
  size = 'md',
  loading = false,
  disabled,
  className = '',
  children,
  ...rest
}: ButtonProps) {
  return (
    <button
      type="button"
      disabled={disabled || loading}
      className={`${BTN_BASE} ${BTN_VARIANT[variant]} ${BTN_SIZE[size]} ${className}`}
      {...rest}
    >
      {loading && (
        <span className="h-3.5 w-3.5 animate-spin rounded-full border-2 border-current border-t-transparent" />
      )}
      {children}
    </button>
  )
}

export function Card({
  className = '',
  children,
}: {
  className?: string
  children: ReactNode
}) {
  return (
    <div className={`rounded-xl border border-slate-200 bg-white shadow-sm ${className}`}>
      {children}
    </div>
  )
}

type BadgeTone = 'neutral' | 'brand' | 'success' | 'warning' | 'danger'

const BADGE_TONE: Record<BadgeTone, string> = {
  neutral: 'bg-slate-100 text-slate-600',
  brand: 'bg-brand-50 text-brand-700',
  success: 'bg-green-100 text-green-700',
  warning: 'bg-amber-100 text-amber-700',
  danger: 'bg-red-100 text-red-700',
}

export function Badge({
  tone = 'neutral',
  children,
}: {
  tone?: BadgeTone
  children: ReactNode
}) {
  return (
    <span
      className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium ${BADGE_TONE[tone]}`}
    >
      {children}
    </span>
  )
}

// Botón de impresión reutilizable: imprime (en ventana aislada) el nodo
// referenciado por targetRef. Se oculta a sí mismo en la impresión.
export function PrintButton({
  targetRef,
  title,
  label = 'Imprimir',
  className = '',
}: {
  targetRef: RefObject<HTMLElement | null>
  title?: string
  label?: string
  className?: string
}) {
  return (
    <button
      type="button"
      onClick={() => targetRef.current && printRegion(targetRef.current, title)}
      className={
        'no-print inline-flex items-center gap-1.5 rounded-lg border border-slate-300 ' +
        'bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50 ' +
        className
      }
    >
      <Printer size={16} />
      {label}
    </button>
  )
}

export function PageHeader({
  title,
  subtitle,
  actions,
}: {
  title: string
  subtitle?: string
  actions?: ReactNode
}) {
  return (
    <header className="mb-6 flex flex-wrap items-start justify-between gap-3">
      <div>
        <h1 className="text-2xl font-bold text-slate-900">{title}</h1>
        {subtitle && <p className="mt-0.5 text-sm text-slate-500">{subtitle}</p>}
      </div>
      {actions && <div className="flex items-center gap-2">{actions}</div>}
    </header>
  )
}
