import { useCallback, useEffect, useState } from 'react'
import type { Employee } from '../../domain/employees/employee'
import { fetchEmployees, createEmployee } from '../../services/employees'

export function EmployeesView() {
  const [employees, setEmployees] = useState<Employee[]>([])
  const [error, setError] = useState<string | null>(null)

  const [firstName, setFirstName] = useState('')
  const [lastName, setLastName] = useState('')
  const [email, setEmail] = useState('')
  const [jobTitle, setJobTitle] = useState('')
  const [hireDate, setHireDate] = useState('')
  const [salary, setSalary] = useState('')
  const [busy, setBusy] = useState(false)

  const reload = useCallback(() => {
    return fetchEmployees()
      .then(setEmployees)
      .catch((e: Error) => setError(e.message))
  }, [])

  useEffect(() => {
    void reload()
  }, [reload])

  async function handleCreate() {
    if (!firstName.trim() || !lastName.trim() || !jobTitle.trim()) {
      setError('Nombre, apellido y cargo son obligatorios')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await createEmployee({
        firstName: firstName.trim(),
        lastName: lastName.trim(),
        email: email.trim(),
        jobTitle: jobTitle.trim(),
        hireDate,
        salary: Number(salary) || 0,
      })
      setFirstName('')
      setLastName('')
      setEmail('')
      setJobTitle('')
      setHireDate('')
      setSalary('')
      await reload()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="mx-auto max-w-5xl p-6">
      <h1 className="mb-4 text-2xl font-bold text-slate-800">Empleados</h1>

      {error && (
        <p className="mb-4 rounded bg-red-50 p-2 text-sm text-red-700">{error}</p>
      )}

      {/* Alta */}
      <div className="mb-6 rounded border border-slate-200 p-4">
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
        <button
          type="button"
          disabled={busy}
          onClick={handleCreate}
          className="mt-3 rounded bg-slate-700 px-4 py-2 text-sm font-medium text-white hover:bg-slate-800 disabled:opacity-50"
        >
          Agregar empleado
        </button>
      </div>

      {/* Lista */}
      <div className="overflow-x-auto rounded border border-slate-200">
        <table className="w-full text-left text-sm">
          <thead className="bg-slate-100 text-slate-600">
            <tr>
              <th className="p-3">Empleado</th>
              <th className="p-3">Cargo</th>
              <th className="p-3">Fecha de contratación</th>
              <th className="p-3 text-right">Sueldo (Bs)</th>
              <th className="p-3">Estado</th>
            </tr>
          </thead>
          <tbody>
            {employees.map((e) => (
              <tr key={e.personId} className="border-t border-slate-100">
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
              </tr>
            ))}
            {employees.length === 0 && (
              <tr>
                <td colSpan={5} className="p-4 text-center text-slate-400">
                  Sin empleados aún.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  )
}
