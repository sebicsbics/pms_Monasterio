import { useEffect, useState } from 'react'
import { X } from 'lucide-react'
import type { Room } from '../../domain/rooms/room'
import type { Folio } from '../../domain/folios/folio'
import type { Product } from '../../domain/inventory/product'
import { isSellable } from '../../domain/inventory/product'
import {
  walkInCheckIn,
  checkOutRoom,
  setRoomStatus,
  overrideReservationRate,
} from '../../services/checkin'
import {
  fetchFolio,
  addFolioCharge,
  addFolioProductCharge,
} from '../../services/folio'
import { fetchProducts } from '../../services/inventory'
import { fetchAssignableStaff, createTask } from '../../services/tasks'
import type { AssignableStaff } from '../../domain/tasks/task'
import { fetchPaymentMethods } from '../../services/payments'
import type { PaymentMethod } from '../../domain/payments/paymentMethod'
import { COUNTRIES } from '../../shared/data/countries'
import type { UserRole } from '../../domain/auth/profile'
import { canEditRate as canEditRateGate } from '../../domain/auth/rateGates'
import type { CompanionGuest } from '../../services/arrivals'

interface Props {
  room: Room
  role?: UserRole | null
  onClose: () => void
  onDone: () => void // recargar el tablero tras una acción
}

export function RoomPanel({ room, role, onClose, onDone }: Props) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)

  // Estado del formulario de walk-in
  const [firstName, setFirstName] = useState('')
  const [lastName, setLastName] = useState('')
  const [document, setDocument] = useState('')
  const [email, setEmail] = useState('')
  const [birthDate, setBirthDate] = useState('')
  const [countryCode, setCountryCode] = useState('')
  const [city, setCity] = useState('')
  const [wantsOffers, setWantsOffers] = useState(false)
  const [nights, setNights] = useState(1)
  const [typeId, setTypeId] = useState(room.defaultType?.id ?? '')

  // Acompañantes (perfil completo de los demás huéspedes de la habitación).
  // El walk-in no fija la cantidad de antemano: se agregan a mano, con tope
  // = max_occupancy del tipo elegido menos el titular.
  const emptyCompanion = (): CompanionGuest => ({
    firstName: '',
    lastName: '',
    document: '',
    birthDate: '',
    countryCode: '',
    city: '',
  })
  const [companions, setCompanions] = useState<CompanionGuest[]>([])
  function updateCompanion(index: number, patch: Partial<CompanionGuest>) {
    setCompanions((prev) => prev.map((g, i) => (i === index ? { ...g, ...patch } : g)))
  }

  // Tarifa editable al check-in (root/reception), con justificación
  // obligatoria cuando difiere de la tarifa del tipo elegido — misma
  // regla que "Editar tarifa" post-check-in (ver más abajo).
  const selectedType = room.typeOptions.find((t) => t.id === typeId) ?? room.defaultType
  const defaultRateBs = selectedType?.basePriceBs ?? 0
  const [checkInRate, setCheckInRate] = useState(String(defaultRateBs))
  const [checkInRateReason, setCheckInRateReason] = useState('')
  const canEditCheckInRate = canEditRateGate(role)
  const checkInRateDiffers = Number(checkInRate) !== defaultRateBs

  // Folio (solo si la habitación está ocupada)
  const [folio, setFolio] = useState<Folio | null>(null)
  const [chargeDesc, setChargeDesc] = useState('')
  const [chargeAmount, setChargeAmount] = useState('')
  const [paymentMethod, setPaymentMethod] = useState('EFECTIVO')
  const [paymentMethods, setPaymentMethods] = useState<PaymentMethod[]>([])
  const [receiptFile, setReceiptFile] = useState<File | null>(null)
  const [paymentReference, setPaymentReference] = useState('')

  // Edición de tarifa (root/reception), con justificación obligatoria
  const [rateEditOpen, setRateEditOpen] = useState(false)
  const [newRate, setNewRate] = useState('')
  const [rateReason, setRateReason] = useState('')
  const canEditRate = canEditRateGate(role)

  // Minibar: productos vendibles del inventario
  const [products, setProducts] = useState<Product[]>([])
  const [productId, setProductId] = useState('')
  const [productQty, setProductQty] = useState('1')

  // Asignación de mucama (solo si la habitación está por limpiar)
  const [staff, setStaff] = useState<AssignableStaff[]>([])
  const [staffId, setStaffId] = useState('')

  const isOccupied = room.operationalStatus === 'occupied'
  const isDirty = room.operationalStatus === 'dirty'

  useEffect(() => {
    if (isOccupied) {
      fetchFolio(room.id)
        .then(setFolio)
        .catch((e: Error) => setError(e.message))
      fetchProducts()
        .then((all) => setProducts(all.filter(isSellable)))
        .catch((e: Error) => setError(e.message))
    }
  }, [room.id, isOccupied])

  useEffect(() => {
    setCheckInRate(String(defaultRateBs))
    setCheckInRateReason('')
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [typeId, room.id])

  useEffect(() => {
    if (isDirty) {
      fetchAssignableStaff()
        .then(setStaff)
        .catch((e: Error) => setError(e.message))
    }
  }, [isDirty])

  useEffect(() => {
    if (isOccupied) {
      fetchPaymentMethods()
        .then(setPaymentMethods)
        .catch((e: Error) => setError(e.message))
    }
  }, [isOccupied])

  function handleAssignCleaning() {
    if (!staffId) {
      setError('Elegí a quién asignar la limpieza')
      return
    }
    const assignee = staff.find((s) => s.personId === staffId)?.fullName ?? ''
    run(() =>
      createTask({
        taskType: 'cleaning',
        assignedToName: assignee,
        notes: `Limpieza habitación ${room.roomNumber}`,
      }),
    )
  }

  async function handleAddProduct() {
    const qty = Number(productQty)
    if (!productId || !(qty > 0)) {
      setError('Elegí un producto y una cantidad válida')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await addFolioProductCharge(room.id, productId, qty)
      setProductId('')
      setProductQty('1')
      await reloadFolio()
      setProducts((await fetchProducts()).filter(isSellable))
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  async function reloadFolio() {
    setFolio(await fetchFolio(room.id))
  }

  async function handleAddCharge() {
    const amount = Number(chargeAmount)
    if (!chargeDesc.trim() || !(amount >= 0)) {
      setError('Descripción y monto válido son obligatorios')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await addFolioCharge(room.id, chargeDesc.trim(), amount)
      setChargeDesc('')
      setChargeAmount('')
      await reloadFolio()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  async function handleOverrideRate() {
    if (!folio) return
    const rate = Number(newRate)
    setBusy(true)
    setError(null)
    setMessage(null)
    try {
      const pending = await overrideReservationRate(folio.reservationId, rate, rateReason)
      setMessage(pending ?? 'Tarifa actualizada.')
      setNewRate('')
      setRateReason('')
      setRateEditOpen(false)
      await reloadFolio()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  async function run(action: () => Promise<void | string | null>) {
    setBusy(true)
    setError(null)
    setMessage(null)
    try {
      const result = await action()
      if (typeof result === 'string') setMessage(result)
      onDone()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  function handleCheckIn() {
    if (!firstName.trim() || !lastName.trim()) {
      setError('Nombre y apellido son obligatorios')
      return
    }
    const rate = Number(checkInRate)
    if (canEditCheckInRate && checkInRateDiffers && !checkInRateReason.trim()) {
      setError('La justificación es obligatoria para cambiar la tarifa')
      return
    }
    run(() =>
      walkInCheckIn({
        roomId: room.id,
        roomTypeId: typeId,
        firstName: firstName.trim(),
        lastName: lastName.trim(),
        document: document.trim(),
        email: email.trim(),
        birthDate,
        countryCode: countryCode.trim().toUpperCase(),
        city: city.trim(),
        wantsOffers,
        nights,
        rateBs: canEditCheckInRate && checkInRateDiffers ? rate : null,
        rateReason: canEditCheckInRate && checkInRateDiffers ? checkInRateReason.trim() : null,
        companions,
      }),
    )
  }

  async function handleCheckOut() {
    setBusy(true)
    setError(null)
    try {
      const total = await checkOutRoom(room.id, paymentMethod, {
        receipt: receiptFile,
        paymentReference: paymentReference.trim() || null,
      })
      setMessage(`Check-out realizado. Total cobrado: ${total.toFixed(2)} Bs`)
      setReceiptFile(null)
      setPaymentReference('')
      onDone()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="fixed inset-0 z-10 flex justify-end bg-black/30">
      <aside className="h-full w-full max-w-sm overflow-y-auto bg-white p-6 shadow-xl">
        <div className="mb-4 flex items-center justify-between">
          <h2 className="text-xl font-bold text-slate-800">
            Habitación {room.roomNumber}
          </h2>
          <button
            type="button"
            onClick={onClose}
            aria-label="Cerrar"
            className="text-slate-400 hover:text-slate-700"
          >
            <X size={20} />
          </button>
        </div>

        <p className="mb-4 text-sm text-slate-500">
          Piso {room.floor} · {room.zone} · {room.defaultType?.name}
        </p>

        {error && (
          <p className="mb-3 rounded bg-red-50 p-2 text-sm text-red-700">
            {error}
          </p>
        )}
        {message && (
          <p className="mb-3 rounded bg-green-50 p-2 text-sm text-green-700">
            {message}
          </p>
        )}

        {/* DISPONIBLE → check-in */}
        {room.operationalStatus === 'available' && (
          <div className="space-y-3">
            <h3 className="font-semibold text-slate-700">Check-in (walk-in)</h3>

            {room.typeOptions.length > 1 && (
              <label className="block text-sm">
                <span className="text-slate-600">Vender como</span>
                <select
                  value={typeId}
                  onChange={(e) => setTypeId(e.target.value)}
                  className="mt-1 w-full rounded border border-slate-300 p-2"
                >
                  {room.typeOptions.map((t) => (
                    <option key={t.id} value={t.id}>
                      {t.name} — {t.basePriceBs} Bs
                    </option>
                  ))}
                </select>
              </label>
            )}

            <input
              placeholder="Nombre"
              value={firstName}
              onChange={(e) => setFirstName(e.target.value)}
              className="w-full rounded border border-slate-300 p-2"
            />
            <input
              placeholder="Apellido"
              value={lastName}
              onChange={(e) => setLastName(e.target.value)}
              className="w-full rounded border border-slate-300 p-2"
            />
            <input
              placeholder="Documento / Pasaporte"
              value={document}
              onChange={(e) => setDocument(e.target.value)}
              className="w-full rounded border border-slate-300 p-2"
            />
            <input
              type="email"
              placeholder="Correo (opcional)"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="w-full rounded border border-slate-300 p-2"
            />
            <div className="flex gap-2">
              <select
                value={countryCode}
                onChange={(e) => setCountryCode(e.target.value)}
                className="w-1/2 rounded border border-slate-300 p-2"
              >
                <option value="">País…</option>
                {COUNTRIES.map((c) => (
                  <option key={c.code} value={c.code}>
                    {c.name}
                  </option>
                ))}
              </select>
              <input
                placeholder="Ciudad"
                value={city}
                onChange={(e) => setCity(e.target.value)}
                className="w-1/2 rounded border border-slate-300 p-2"
              />
            </div>
            <label className="block text-sm">
              <span className="text-slate-600">Fecha de nacimiento</span>
              <input
                type="date"
                value={birthDate}
                onChange={(e) => setBirthDate(e.target.value)}
                className="mt-1 w-full rounded border border-slate-300 p-2"
              />
            </label>
            <label className="flex items-center gap-2 text-sm text-slate-600">
              <input
                type="checkbox"
                checked={wantsOffers}
                onChange={(e) => setWantsOffers(e.target.checked)}
              />
              Acepta recibir promociones por correo
            </label>
            <label className="block text-sm">
              <span className="text-slate-600">Noches</span>
              <input
                type="number"
                min={1}
                value={nights}
                onChange={(e) => setNights(Math.max(1, Number(e.target.value)))}
                className="mt-1 w-full rounded border border-slate-300 p-2"
              />
            </label>

            {canEditCheckInRate && (
              <div className="space-y-2 rounded border border-slate-200 p-3">
                <label className="block text-sm">
                  <span className="mb-1 block text-xs font-medium text-slate-500">
                    Tarifa por noche (Bs)
                  </span>
                  <input
                    type="number"
                    min={0}
                    step="0.01"
                    value={checkInRate}
                    onChange={(e) => setCheckInRate(e.target.value)}
                    className="w-full rounded border border-slate-300 p-2 text-sm"
                  />
                </label>
                {checkInRateDiffers && (
                  <label className="block text-sm">
                    <span className="mb-1 block text-xs font-medium text-slate-500">
                      Justificación (obligatoria)
                    </span>
                    <textarea
                      value={checkInRateReason}
                      onChange={(e) => setCheckInRateReason(e.target.value)}
                      placeholder="Ej. Última cuádruple disponible, se vende a precio de matrimonial"
                      className="w-full rounded border border-slate-300 p-2 text-sm"
                      rows={2}
                    />
                  </label>
                )}
              </div>
            )}

            <div className="space-y-3 border-t border-slate-200 pt-3">
              <div className="flex items-center justify-between">
                <span className="text-xs font-medium text-slate-600">
                  Acompañantes {companions.length > 0 && `(${companions.length})`}
                </span>
                {companions.length < (selectedType?.maxOccupancy ?? 1) - 1 && (
                  <button
                    type="button"
                    onClick={() => setCompanions((prev) => [...prev, emptyCompanion()])}
                    className="text-xs font-medium text-brand-700 hover:underline"
                  >
                    + Agregar huésped
                  </button>
                )}
              </div>
              {companions.map((g, i) => (
                <div key={i} className="space-y-2 rounded border border-slate-200 p-3">
                  <div className="flex items-center justify-between">
                    <p className="text-xs font-semibold text-slate-500">Huésped {i + 2}</p>
                    <button
                      type="button"
                      onClick={() => setCompanions((prev) => prev.filter((_, j) => j !== i))}
                      className="text-xs text-slate-400 hover:text-red-600"
                    >
                      Quitar
                    </button>
                  </div>
                  <div className="flex gap-2">
                    <input
                      placeholder="Nombre"
                      value={g.firstName}
                      onChange={(e) => updateCompanion(i, { firstName: e.target.value })}
                      className="w-1/2 rounded border border-slate-300 p-2 text-sm"
                    />
                    <input
                      placeholder="Apellido"
                      value={g.lastName}
                      onChange={(e) => updateCompanion(i, { lastName: e.target.value })}
                      className="w-1/2 rounded border border-slate-300 p-2 text-sm"
                    />
                  </div>
                  <input
                    placeholder="Documento / Pasaporte"
                    value={g.document}
                    onChange={(e) => updateCompanion(i, { document: e.target.value })}
                    className="w-full rounded border border-slate-300 p-2 text-sm"
                  />
                  <div className="flex gap-2">
                    <select
                      value={g.countryCode}
                      onChange={(e) => updateCompanion(i, { countryCode: e.target.value })}
                      className="w-1/2 rounded border border-slate-300 p-2 text-sm"
                    >
                      <option value="">País…</option>
                      {COUNTRIES.map((c) => (
                        <option key={c.code} value={c.code}>
                          {c.name}
                        </option>
                      ))}
                    </select>
                    <input
                      placeholder="Ciudad"
                      value={g.city}
                      onChange={(e) => updateCompanion(i, { city: e.target.value })}
                      className="w-1/2 rounded border border-slate-300 p-2 text-sm"
                    />
                  </div>
                  <label className="block text-xs text-slate-500">
                    Fecha de nacimiento
                    <input
                      type="date"
                      value={g.birthDate}
                      onChange={(e) => updateCompanion(i, { birthDate: e.target.value })}
                      className="mt-1 w-full rounded border border-slate-300 p-2 text-sm"
                    />
                  </label>
                </div>
              ))}
            </div>

            <button
              type="button"
              disabled={
                busy ||
                (canEditCheckInRate && checkInRateDiffers && !checkInRateReason.trim())
              }
              onClick={handleCheckIn}
              className="w-full rounded bg-brand-700 py-2 font-medium text-white hover:bg-brand-800 disabled:opacity-50"
            >
              {busy ? 'Procesando…' : 'Confirmar check-in'}
            </button>

            <button
              type="button"
              disabled={busy}
              onClick={() => run(() => setRoomStatus(room.id, 'maintenance'))}
              className="w-full rounded border border-slate-300 py-2 text-sm text-slate-600 hover:bg-slate-50"
            >
              Poner en mantenimiento
            </button>
          </div>
        )}

        {/* OCUPADA → folio + consumos + check-out */}
        {isOccupied && (
          <div className="space-y-4">
            <div>
              <h3 className="mb-2 font-semibold text-slate-700">Folio</h3>
              {folio ? (
                <div className="rounded border border-slate-200 p-3 text-sm">
                  <div className="flex justify-between text-slate-600">
                    <span>Habitación ({folio.roomType})</span>
                    <span>{folio.roomChargeBs.toFixed(2)} Bs</span>
                  </div>
                  {folio.charges.map((c) => (
                    <div key={c.id} className="flex justify-between text-slate-600">
                      <span>{c.description}</span>
                      <span>{c.amountBs.toFixed(2)} Bs</span>
                    </div>
                  ))}
                  <div className="mt-2 flex justify-between border-t border-slate-200 pt-2 font-bold text-slate-800">
                    <span>Total</span>
                    <span>{folio.totalBs.toFixed(2)} Bs</span>
                  </div>
                </div>
              ) : (
                <p className="text-sm text-slate-400">Cargando folio…</p>
              )}

              {canEditRate && folio && (
                <div className="mt-2">
                  {!rateEditOpen ? (
                    <button
                      type="button"
                      onClick={() => setRateEditOpen(true)}
                      className="text-xs font-medium text-brand-700 hover:underline"
                    >
                      Editar tarifa
                    </button>
                  ) : (
                    <div className="mt-2 space-y-2 rounded border border-slate-200 p-3">
                      <label className="block text-sm">
                        <span className="mb-1 block text-xs font-medium text-slate-500">
                          Nueva tarifa (Bs)
                        </span>
                        <input
                          type="number"
                          min={0}
                          step="0.01"
                          value={newRate}
                          onChange={(e) => setNewRate(e.target.value)}
                          className="w-full rounded border border-slate-300 p-2 text-sm"
                        />
                      </label>
                      <label className="block text-sm">
                        <span className="mb-1 block text-xs font-medium text-slate-500">
                          Justificación (obligatoria)
                        </span>
                        <textarea
                          value={rateReason}
                          onChange={(e) => setRateReason(e.target.value)}
                          placeholder="Ej. Última cuádruple disponible, se vende a precio de matrimonial"
                          className="w-full rounded border border-slate-300 p-2 text-sm"
                          rows={2}
                        />
                      </label>
                      <div className="flex gap-2">
                        <button
                          type="button"
                          disabled={busy || !newRate.trim() || !rateReason.trim()}
                          onClick={handleOverrideRate}
                          className="w-1/2 rounded bg-brand-700 py-2 text-sm font-medium text-white hover:bg-brand-800 disabled:opacity-50"
                        >
                          Guardar tarifa
                        </button>
                        <button
                          type="button"
                          onClick={() => {
                            setRateEditOpen(false)
                            setNewRate('')
                            setRateReason('')
                          }}
                          className="w-1/2 rounded border border-slate-300 py-2 text-sm text-slate-600 hover:bg-slate-50"
                        >
                          Cancelar
                        </button>
                      </div>
                    </div>
                  )}
                </div>
              )}
            </div>

            <div className="space-y-2">
              <h4 className="text-sm font-medium text-slate-600">
                Minibar (descuenta stock)
              </h4>
              <div className="flex gap-2">
                <select
                  value={productId}
                  onChange={(e) => setProductId(e.target.value)}
                  className="w-1/2 rounded border border-slate-300 p-2 text-sm"
                >
                  <option value="">Producto…</option>
                  {products.map((p) => (
                    <option key={p.id} value={p.id}>
                      {p.name} — {p.salePriceBs} Bs (stock {p.currentStock})
                    </option>
                  ))}
                </select>
                <input
                  type="number"
                  min={1}
                  value={productQty}
                  onChange={(e) => setProductQty(e.target.value)}
                  className="w-1/4 rounded border border-slate-300 p-2 text-sm"
                />
                <button
                  type="button"
                  disabled={busy}
                  onClick={handleAddProduct}
                  className="w-1/4 rounded bg-slate-700 text-sm font-medium text-white hover:bg-slate-800 disabled:opacity-50"
                >
                  Cargar
                </button>
              </div>
            </div>

            <div className="space-y-2">
              <h4 className="text-sm font-medium text-slate-600">
                Otro consumo (servicios)
              </h4>
              <input
                placeholder="Descripción (Minibar, Spa…)"
                value={chargeDesc}
                onChange={(e) => setChargeDesc(e.target.value)}
                className="w-full rounded border border-slate-300 p-2"
              />
              <div className="flex gap-2">
                <input
                  type="number"
                  min={0}
                  step="0.01"
                  placeholder="Monto Bs"
                  value={chargeAmount}
                  onChange={(e) => setChargeAmount(e.target.value)}
                  className="w-2/3 rounded border border-slate-300 p-2"
                />
                <button
                  type="button"
                  disabled={busy}
                  onClick={handleAddCharge}
                  className="w-1/3 rounded bg-slate-700 py-2 text-sm font-medium text-white hover:bg-slate-800 disabled:opacity-50"
                >
                  Agregar
                </button>
              </div>
            </div>

            <label className="block text-sm">
              <span className="mb-1 block text-xs font-medium text-slate-500">
                Forma de pago
              </span>
              <select
                value={paymentMethod}
                onChange={(e) => setPaymentMethod(e.target.value)}
                className="w-full rounded border border-slate-300 p-2"
              >
                {paymentMethods.map((m) => (
                  <option key={m.code} value={m.code}>{m.label}</option>
                ))}
              </select>
            </label>
            {paymentMethod === 'EFECTIVO' && (
              <p className="text-xs text-slate-400">
                El efectivo se registra en la caja (debe estar abierta).
              </p>
            )}

            <label className="block text-sm">
              <span className="mb-1 block text-xs font-medium text-slate-500">
                Comprobante (imagen QR, opcional)
              </span>
              <input
                type="file"
                accept="image/*"
                onChange={(e) => setReceiptFile(e.target.files?.[0] ?? null)}
                className="w-full rounded border border-slate-300 p-2 text-sm"
              />
            </label>
            <label className="block text-sm">
              <span className="mb-1 block text-xs font-medium text-slate-500">
                Código de referencia (tarjeta, opcional)
              </span>
              <input
                placeholder="Ej. AB12345"
                value={paymentReference}
                onChange={(e) => setPaymentReference(e.target.value)}
                className="w-full rounded border border-slate-300 p-2 text-sm"
              />
            </label>

            <button
              type="button"
              disabled={busy}
              onClick={handleCheckOut}
              className="w-full rounded bg-amber-600 py-2 font-medium text-white hover:bg-amber-700 disabled:opacity-50"
            >
              {busy ? 'Procesando…' : 'Check-out'}
            </button>
          </div>
        )}

        {/* POR LIMPIAR → asignar mucama + marcar limpia */}
        {isDirty && (
          <div className="space-y-3">
            <div className="space-y-2">
              <h3 className="font-semibold text-slate-700">Asignar limpieza</h3>
              <select
                value={staffId}
                onChange={(e) => setStaffId(e.target.value)}
                className="w-full rounded border border-slate-300 p-2 text-sm"
              >
                <option value="">Elegí una mucama…</option>
                {staff.map((s) => (
                  <option key={s.personId} value={s.personId}>
                    {s.fullName} — {s.jobTitle}
                  </option>
                ))}
              </select>
              <button
                type="button"
                disabled={busy}
                onClick={handleAssignCleaning}
                className="w-full rounded bg-slate-700 py-2 font-medium text-white hover:bg-slate-800 disabled:opacity-50"
              >
                {busy ? 'Procesando…' : 'Asignar mucama'}
              </button>
            </div>

            <button
              type="button"
              disabled={busy}
              onClick={() => run(() => setRoomStatus(room.id, 'available'))}
              className="w-full rounded bg-green-600 py-2 font-medium text-white hover:bg-green-700 disabled:opacity-50"
            >
              Marcar como limpia
            </button>
          </div>
        )}

        {/* MANTENIMIENTO → volver a disponible */}
        {room.operationalStatus === 'maintenance' && (
          <button
            type="button"
            disabled={busy}
            onClick={() => run(() => setRoomStatus(room.id, 'available'))}
            className="w-full rounded bg-green-600 py-2 font-medium text-white hover:bg-green-700 disabled:opacity-50"
          >
            Marcar como disponible
          </button>
        )}
      </aside>
    </div>
  )
}
