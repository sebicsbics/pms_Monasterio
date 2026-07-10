import { useCallback, useEffect, useState } from 'react'
import type { Employee, SystemProfile } from '../../domain/employees/employee'
import {
  fetchEmployees,
  createStaffMember,
  fetchSystemProfiles,
  linkEmployeeUser,
  deleteEmployee,
  setEmployeeStatus,
} from '../../services/employees'
import type { UserRole } from '../../domain/auth/profile'
import { Button, Card, PageHeader } from '../../components/ui'

export function EmployeesView({ role }: { role?: UserRole | null }) {
  const [employees, setEmployees] = useState<Employee[]>([])
  const [profiles, setProfiles] = useState<SystemProfile[]>([])
  const [error, setError] = useState<string | null>(null)

  const [firstName, setFirstName] = useState('')
  const [lastName, setLastName] = useState('')
  const [email, setEmail] = useState('')
  const [jobTitle, setJobTitle] = useState('')
  const [hireDate, setHireDate] = useState('')
  const [salary, setSalary] = useState('')
  const [linkUserId, setLinkUserId] = useState('')
  const [linkRole, setLinkRole] = useState('')
  const [busy, setBusy] = useState(false)

  const reload = useCallback(() => {
    return fetchEmployees()
      .then(setEmployees)
      .catch((e: Error) => setError(e.message))
  }, [])

  useEffect(() => {
    void reload()
    fetchSystemProfiles()
      .then(setProfiles)
      .catch((e: Error) => setError(e.message))
  }, [reload])

  // Perfiles ya tomados por otro empleado (no se ofrecen para vincular de nuevo).
  const takenUserIds = new Set(
    employees.map((e) => e.userId).filter((id): id is string => !!id),
  )

  async function link(personId: string, userId: string | null) {
    setError(null)
    try {
      await linkEmployeeUser(personId, userId)
      await reload()
    } catch (e) {
      setError((e as Error).message)
    }
  }

  async function toggleStatus(e: Employee) {
    setError(null)
    try {
      await setEmployeeStatus(e.personId, e.status === 'active' ? 'inactive' : 'active')
      await reload()
    } catch (err) {
      setError((err as Error).message)
    }
  }

  async function remove(e: Employee) {
    if (!window.confirm(`¿Eliminar a ${e.firstName} ${e.lastName} del registro de empleados?`)) {
      return
    }
    setError(null)
    try {
      await deleteEmployee(e.personId)
      await reload()
    } catch (err) {
      setError((err as Error).message)
    }
  }

  async function handleCreate() {
    if (!firstName.trim() || !lastName.trim() || !jobTitle.trim()) {
      setError('Nombre, apellido y cargo son obligatorios')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await createStaffMember({
        firstName: firstName.trim(),
        lastName: lastName.trim(),
        email: email.trim(),
        jobTitle: jobTitle.trim(),
        hireDate,
        salary: Number(salary) || 0,
        userId: linkUserId || null,
        role: linkUserId && linkRole ? linkRole : null,
        username: null,
      })
      setFirstName('')
      setLastName('')
      setEmail('')
      setJobTitle('')
      setHireDate('')
      setSalary('')
      setLinkUserId('')
      setLinkRole('')
      await reload()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="mx-auto max-w-5xl p-6">
      <PageHeader title="Empleados" />

      {error && (
        <p className="mb-4 rounded bg-red-50 p-2 text-sm text-red-700">{error}</p>
      )}

      {/* Alta */}
      <Card className="mb-6 p-4">
        <h3 className="mb-3 font-semibold text-slate-700">Nuevo empleado</h3>
        <div className="grid grid-cols-2 gap-2 sm:grid-cols-6">
          <input
            placeholder="Nombre"
            value={firstName}
            onChange={(e) => setFirstName(e.target.value)}
            className="rounded border border-slate-300 p-2"
          />
          <input
            placeholder="Apellido"
            value={lastName}
            onChange={(e) => setLastName(e.target.value)}
            className="rounded border border-slate-300 p-2"
          />
          <input
            placeholder="Cargo"
            value={jobTitle}
            onChange={(e) => setJobTitle(e.target.value)}
            className="rounded border border-slate-300 p-2"
          />
          <input
            type="email"
            placeholder="Correo"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            className="rounded border border-slate-300 p-2"
          />
          <input
            type="number"
            min={0}
            step="0.01"
            placeholder="Sueldo Bs"
            value={salary}
            onChange={(e) => setSalary(e.target.value)}
            className="rounded border border-slate-300 p-2"
          />
          <label className="text-xs text-slate-500">
            Fecha de contratación
            <input
              type="date"
              value={hireDate}
              onChange={(e) => setHireDate(e.target.value)}
              className="mt-1 w-full rounded border border-slate-300 p-2 text-sm text-slate-800"
            />
          </label>
        </div>
        {/* Vinculación opcional a un usuario del sistema existente */}
        <div className="mt-3 flex flex-wrap items-end gap-2 border-t border-slate-100 pt-3">
          <label className="text-xs text-slate-500">
            Vincular a usuario (opcional)
            <select
              value={linkUserId}
              onChange={(e) => setLinkUserId(e.target.value)}
              className="mt-1 block rounded border border-slate-300 p-2 text-sm text-slate-800"
            >
              <option value="">Sin usuario</option>
              {profiles
                .filter((p) => !takenUserIds.has(p.id))
                .map((p) => (
                  <option key={p.id} value={p.id}>
                    {p.username ? `@${p.username}` : p.fullName ?? p.id.slice(0, 8)} · {p.role}
                  </option>
                ))}
            </select>
          </label>
          {linkUserId && (
            <label className="text-xs text-slate-500">
              Rol (opcional)
              <select
                value={linkRole}
                onChange={(e) => setLinkRole(e.target.value)}
                className="mt-1 block rounded border border-slate-300 p-2 text-sm text-slate-800"
              >
                <option value="">Mantener actual</option>
                <option value="reception">reception</option>
                <option value="accountant">accountant</option>
                <option value="root">root</option>
              </select>
            </label>
          )}
        </div>

        <Button
          disabled={busy}
          loading={busy}
          onClick={handleCreate}
          className="mt-3"
        >
          Agregar empleado
        </Button>
      </Card>

      {/* Lista */}
      <Card className="overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead className="bg-slate-100 text-slate-600">
            <tr>
              <th className="p-3">Empleado</th>
              <th className="p-3">Cargo</th>
              <th className="p-3">Fecha de contratación</th>
              <th className="p-3 text-right">Sueldo (Bs)</th>
              <th className="p-3">Estado</th>
              <th className="p-3">Usuario del sistema</th>
              <th className="p-3 text-right">Acciones</th>
            </tr>
          </thead>
          <tbody>
            {employees.map((e) => (
              <tr
                key={e.personId}
                className={`border-t border-slate-100 ${e.status !== 'active' ? 'opacity-50' : ''}`}
              >
                <td className="p-3 font-medium">
                  {e.firstName} {e.lastName}
                  {e.email && (
                    <span className="block text-xs text-slate-400">
                      {e.email}
                    </span>
                  )}
                </td>
                <td className="p-3">{e.jobTitle}</td>
                <td className="p-3">{e.hireDate}</td>
                <td className="p-3 text-right">
                  {e.salary === null ? '—' : e.salary.toFixed(2)}
                </td>
                <td className="p-3">{e.status}</td>
                <td className="p-3">
                  {e.userId ? (
                    <span className="flex items-center gap-2">
                      <span className="rounded bg-green-100 px-1.5 py-0.5 text-xs font-medium text-green-700">
                        @{e.accountUsername ?? '—'}
                        {e.accountRole && ` · ${e.accountRole}`}
                      </span>
                      <button
                        type="button"
                        onClick={() => link(e.personId, null)}
                        className="text-xs text-slate-400 hover:text-red-600"
                      >
                        desvincular
                      </button>
                    </span>
                  ) : (
                    <select
                      defaultValue=""
                      onChange={(ev) => ev.target.value && link(e.personId, ev.target.value)}
                      className="rounded border border-slate-300 p-1.5 text-xs"
                    >
                      <option value="">Vincular usuario…</option>
                      {profiles
                        .filter((p) => !takenUserIds.has(p.id))
                        .map((p) => (
                          <option key={p.id} value={p.id}>
                            {p.username ? `@${p.username}` : p.fullName ?? p.id.slice(0, 8)} · {p.role}
                          </option>
                        ))}
                    </select>
                  )}
                </td>
                <td className="p-3 text-right">
                  <div className="flex justify-end gap-2">
                    <button
                      type="button"
                      onClick={() => toggleStatus(e)}
                      className="rounded border border-slate-300 px-2 py-1 text-xs text-slate-600 hover:bg-slate-50"
                    >
                      {e.status === 'active' ? 'Desactivar' : 'Reactivar'}
                    </button>
                    {role === 'root' && (
                      <button
                        type="button"
                        onClick={() => remove(e)}
                        className="rounded border border-red-200 px-2 py-1 text-xs text-red-600 hover:bg-red-50"
                      >
                        Eliminar
                      </button>
                    )}
                  </div>
                </td>
              </tr>
            ))}
            {employees.length === 0 && (
              <tr>
                <td colSpan={7} className="p-4 text-center text-slate-400">
                  Sin empleados aún.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </Card>
    </div>
  )
}
