import { useEffect, useRef, useState } from 'react'
import { Camera } from 'lucide-react'
import { fetchMyProfile, uploadAvatar, type MyProfile } from '../../services/profile'
import { ROLE_LABEL } from '../../domain/auth/profile'
import { Badge, Card, PageHeader } from '../../components/ui'

function Field({ label, value }: { label: string; value: string | null }) {
  return (
    <div>
      <p className="text-xs font-medium uppercase tracking-wide text-slate-400">{label}</p>
      <p className="text-sm text-slate-800">{value || '—'}</p>
    </div>
  )
}

function initials(p: MyProfile): string {
  const a = p.firstName?.[0] ?? p.fullName?.[0] ?? p.username?.[0] ?? '?'
  const b = p.lastName?.[0] ?? ''
  return (a + b).toUpperCase()
}

export function MyProfileView({ userId }: { userId: string }) {
  const [profile, setProfile] = useState<MyProfile | null>(null)
  const [avatar, setAvatar] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [uploading, setUploading] = useState(false)
  const fileRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    fetchMyProfile()
      .then((p) => {
        setProfile(p)
        setAvatar(p.avatarUrl)
      })
      .catch((e: Error) => setError(e.message))
      .finally(() => setLoading(false))
  }, [])

  async function handleFile(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    if (!file) return
    if (!file.type.startsWith('image/')) {
      setError('El archivo debe ser una imagen')
      return
    }
    setUploading(true)
    setError(null)
    try {
      setAvatar(await uploadAvatar(userId, file))
    } catch (err) {
      setError((err as Error).message)
    } finally {
      setUploading(false)
    }
  }

  if (loading) return <p className="p-8 text-slate-500">Cargando perfil…</p>
  if (error && !profile) {
    return (
      <div className="mx-auto max-w-3xl p-6">
        <p className="rounded bg-red-50 p-3 text-sm text-red-700">Error: {error}</p>
      </div>
    )
  }
  if (!profile) return null

  const displayName =
    [profile.firstName, profile.lastName].filter(Boolean).join(' ') ||
    profile.fullName ||
    profile.username ||
    'Usuario'

  return (
    <div className="mx-auto max-w-3xl p-6">
      <PageHeader title="Mi perfil" />

      {error && <p className="mb-4 rounded bg-red-50 p-2 text-sm text-red-700">{error}</p>}

      {/* Cabecera: foto + identidad */}
      <Card className="mb-6 flex items-center gap-5 p-6">
        <div className="relative">
          {avatar ? (
            <img
              src={avatar}
              alt="Foto de perfil"
              className="h-24 w-24 rounded-full object-cover ring-2 ring-slate-100"
            />
          ) : (
            <div className="flex h-24 w-24 items-center justify-center rounded-full bg-slate-200 text-2xl font-bold text-slate-500">
              {initials(profile)}
            </div>
          )}
          <button
            type="button"
            disabled={uploading}
            onClick={() => fileRef.current?.click()}
            aria-label="Cambiar foto"
            className="absolute -bottom-1 -right-1 rounded-full bg-brand-700 p-1.5 text-white shadow hover:bg-brand-800 disabled:opacity-50"
          >
            <Camera size={14} />
          </button>
          <input
            ref={fileRef}
            type="file"
            accept="image/*"
            className="hidden"
            onChange={handleFile}
          />
        </div>
        <div>
          <p className="text-xl font-bold text-slate-800">{displayName}</p>
          {profile.username && <p className="text-sm text-slate-500">@{profile.username}</p>}
          {profile.role && (
            <span className="mt-1 inline-block">
              <Badge tone="brand">{ROLE_LABEL[profile.role]}</Badge>
            </span>
          )}
        </div>
      </Card>

      {/* Datos personales */}
      <Card className="mb-6 p-6">
        <h2 className="mb-4 font-semibold text-slate-700">Información personal</h2>
        <div className="grid grid-cols-2 gap-4 sm:grid-cols-3">
          <Field label="Nombre" value={profile.firstName} />
          <Field label="Apellido" value={profile.lastName} />
          <Field label="Correo" value={profile.email} />
          <Field label="Nacimiento" value={profile.birthDate} />
          {profile.isEmployee && (
            <>
              <Field label="Cargo" value={profile.jobTitle} />
              <Field label="Ingreso" value={profile.hireDate} />
            </>
          )}
        </div>
        {!profile.isEmployee && (
          <p className="mt-4 text-xs text-slate-400">
            Tu usuario todavía no está vinculado a un registro de empleado.
          </p>
        )}
      </Card>

      {/* Futuro: solicitudes de vacaciones / bajas */}
      <div className="flex items-center justify-between rounded-xl border border-dashed border-slate-300 bg-slate-50 p-6">
        <div>
          <h2 className="font-semibold text-slate-600">Solicitudes de vacaciones y bajas</h2>
          <p className="text-sm text-slate-400">
            Pedí días libres o reportá una baja desde acá. Próximamente.
          </p>
        </div>
        <Badge tone="neutral">Próximamente</Badge>
      </div>
    </div>
  )
}
