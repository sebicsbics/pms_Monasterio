# PMS Hotel Monasterio

Sistema de gestión hotelera (Property Management System) construido a medida para
el Hotel Monasterio. **En producción**, operando 36 habitaciones y usado a diario
por recepción, contaduría y administración.

No es un CRUD de demostración: gestiona dinero real, arqueos de caja por turno,
registro turístico obligatorio y el estado operativo de un hotel que no puede
parar.

---

## Tabla de contenidos

- [Qué resuelve](#qué-resuelve)
- [El sistema en números](#el-sistema-en-números)
- [Módulos](#módulos)
- [Decisiones de diseño](#decisiones-de-diseño)
- [Modelo de seguridad](#modelo-de-seguridad)
- [Arquitectura](#arquitectura)
- [Stack](#stack)
- [Puesta en marcha](#puesta-en-marcha)
- [Base de datos](#base-de-datos)
- [Tests](#tests)
- [Despliegue](#despliegue)

---

## Qué resuelve

Un hotel chico opera con planillas, cuadernos y memoria. Eso funciona hasta que
alguien pregunta *cuánto se cobró ayer por QR*, *quién dejó la caja descuadrada*
o *en qué habitación durmió el huésped las primeras tres noches*. Este PMS
reemplaza ese conjunto de papeles por un sistema que:

- registra **cada peso** que entra y por qué medio, con su comprobante;
- deja **rastro auditable** de toda corrección: quién, cuándo y por qué;
- cumple el **registro turístico** boliviano (ficha completa de cada huésped);
- y expone la operación del día en una sola pantalla.

---

## El sistema en números

| | |
|---|---|
| Habitaciones gestionadas | 36 (13 tipos, incluidas duales) |
| Tablas / vistas | 47 / 15 |
| Funciones de base de datos | 66 |
| Políticas RLS | 95 |
| Migraciones versionadas | 82 |
| Tests automatizados | 184 |
| Código de aplicación | ~16.000 líneas TS/TSX |
| Código de base de datos | ~19.000 líneas SQL |

---

## Módulos

**Operación diaria**

- **Tablero de habitaciones** — estado en vivo por piso y patio; check-in walk-in,
  folio, consumos, cambio de habitación, extensión de estadía y check-out.
- **Llegadas** — reservas del día, check-in multi-huésped, reprogramación y
  cancelación.
- **In-house** — huéspedes hospedados en este momento.
- **Reservas** — individuales y en grupo (bulk), con búsqueda de disponibilidad.
- **Disponibilidad** — grilla por fechas con selección por arrastre para reservar
  un bloque.
- **Pase de información** — bitácora de novedades entre turnos, con búsqueda.

**Dinero**

- **Caja chica** — apertura y cierre por turno, movimientos, arqueo con
  diferencia y justificación. Efectivo separado de QR, depósito y tarjeta.
- **Anticipos** — adelantos de huésped, con corrección auditada.
- **Cuentas por cobrar** — facturación a empresas y agencias.
- **Eventos** — salones, con pagos parciales.
- **Descuentos** — cola de aprobación para rebajas mayores al 20%.

**Soporte**

- **Housekeeping** — asignación diaria de limpieza y seguimiento.
- **Mantenimiento** — tickets, repuestos, planes preventivos y métricas.
- **Inventario** — productos, stock, ingresos de mercadería y minibar.
- **Tareas** — tablero Kanban de relevo entre turnos.
- **Fichaje** — asistencia del personal, con corrección por administrador.
- **Analítica** — ocupación, ingresos y ADR.

---

## Decisiones de diseño

Las partes interesantes del proyecto no son las pantallas, son estas cuatro.

### 1. La estadía es una serie de tramos, no un escalar

El modelo obvio guarda `total_amount_bs` en la reserva. Eso no puede expresar
*"3 noches en la 101 a 350 + 2 noches en la 205 a 500"*, que es exactamente lo
que hay que registrar cuando un huésped cambia de habitación a mitad de estadía.

`stay_segments` guarda un tramo por *(habitación, tarifa, rango de fechas)*.
`total_amount_bs` **no se eliminó**: pasó a mantenerse como la suma de los
tramos, con el invariante impuesto en la base. Así el detalle nuevo no obligó a
reescribir el check-out, el folio ni la analítica, y las reservas históricas sin
tramos siguen funcionando.

El mismo modelo resolvió gratis la extensión y el recorte de noches.

### 2. Autorización fail-closed

Toda escritura pasa por una función `SECURITY DEFINER` con un guard de rol
explícito. Un rol nuevo **no se agrega** a esas listas, así que queda rechazado
por defecto: no hay que enumerar lo que no puede hacer.

Este criterio surgió de una auditoría que encontró tres agujeros reales, todos
por lo contrario — permisos otorgados por omisión:

| Problema | Consecuencia |
|---|---|
| `setup_employee` sin guard de rol | Cualquier usuario autenticado se ascendía a `root` |
| Guard ubicado dentro de un `if` | Check-in sin ningún control de rol |
| Rol tomado del metadata del cliente en el registro | Cualquiera en internet se creaba una cuenta `root` |

Los tres se verificaron **explotándolos** contra la base en transacciones
revertidas antes de corregirlos, y se re-verificaron después.

### 3. El respaldo del cobro es parte del cobro

Un pago por QR exige la foto del comprobante; uno con tarjeta, el código de
referencia. La regla vive en un solo lugar (`assert_payment_proof`) y se exige en
la base, no en el formulario: una validación de frontend la esquiva cualquiera
con las devtools abiertas.

El pago mixto se parte en **dos** movimientos de caja —uno en efectivo y uno
electrónico— porque son plata que entra por canales distintos: el primero va al
cajón y cuenta para el arqueo, el segundo no.

### 4. Un período contable cerrado no se reescribe

Al corregir un anticipo, si el movimiento original está en un turno todavía
abierto se anula ahí. Si el turno ya se cerró, queda intacto y el ajuste se
registra como contraasiento en la caja de hoy. Es la regla contable estándar, y
evita que el arqueo que alguien firmó ayer cambie hoy.

---

## Modelo de seguridad

Seis roles, con el principio de menor privilegio:

| Rol | Alcance |
|---|---|
| `root` | Administración total |
| `reception_admin` | Recepción + aprobación de descuentos y corrección de anticipos |
| `reception` | Operación diaria: check-in, check-out, caja, consumos |
| `accountant` | Contaduría: analítica, arqueos, inventario, legajos |
| `owner` | **Solo lectura.** Ve toda la operación, no modifica nada |
| `pending` | Cuenta recién registrada, sin acceso hasta que root le asigne rol |

Defensa en capas:

1. **RLS** en todas las tablas (95 políticas, ninguna tabla sin protección).
2. **Guards de rol** en cada función de escritura.
3. **UI** que oculta lo que el rol no puede hacer — comodidad, no seguridad.

El rol `owner` existe porque el dueño quería revisar los datos sin riesgo de
modificarlos por error. Construirlo obligó a cerrar 16 tablas que habían quedado
con políticas permisivas de la fase de desarrollo: sin eso, "solo lectura" habría
sido una etiqueta sin respaldo.

---

## Arquitectura

Separación en capas, con el dominio libre de dependencias:

```
src/
├── domain/       Reglas de negocio puras. Sin React ni Supabase.
│                 Es lo que se testea: aritmética de tramos, validación
│                 de desgloses, reglas de respaldo, grupos de roles.
├── services/     Acceso a datos. Traduce entre el shape de la base
│                 (snake_case) y el del dominio (camelCase).
├── features/     Vistas por módulo. Container-presentational.
├── components/   UI compartida (Button, Card, Badge, PageHeader…).
├── shared/       Utilidades y datos transversales.
└── lib/          Helpers puros (formato de fechas, etc.).
```

Que el dominio no importe React ni Supabase es lo que permite testear las reglas
de negocio sin montar el árbol de componentes ni levantar una base.

La lógica que toca dinero vive en **PostgreSQL**, no en el cliente: funciones
`SECURITY DEFINER` transaccionales. El frontend no puede dejar una operación a
medias ni saltearse una validación.

---

## Stack

| Capa | Tecnología |
|---|---|
| Frontend | React 19, TypeScript, Vite 8 |
| Estilos | Tailwind CSS 4 |
| Backend | Supabase (PostgreSQL 17) |
| Auth | Supabase Auth, login por nombre de usuario |
| Gráficos | Recharts |
| Tests | Vitest + Testing Library |
| Lint | oxlint |

---

## Puesta en marcha

**Requisitos:** Node 22+, una cuenta de Supabase.

```bash
git clone git@github.com:sebicsbics/pms_Monasterio.git
cd pms_Monasterio
npm install
```

Creá un archivo `.env.local` en la raíz:

```bash
VITE_SUPABASE_URL=https://tu-proyecto.supabase.co
VITE_SUPABASE_ANON_KEY=tu-anon-key
```

Ambas salen de **Supabase → Project Settings → API**. La `anon key` es pública
por diseño: lo que protege los datos es la RLS. **Nunca** pongas la
`service_role` en el frontend — viajaría en el bundle del navegador.

### Opción A — entorno local completo (recomendada)

Necesitás Docker. Levanta Postgres, Auth y Storage en tu máquina, aplica las 82
migraciones y carga datos de prueba:

```bash
npx supabase start
npx supabase db reset     # migraciones + seed
npm run dev
```

Apuntá `.env.local` a la URL y la `anon key` que imprime `supabase start`.

El seed deja el sistema **usable de entrada**: un usuario por rol (contraseña
`local1234`), 8 huéspedes ficticios, 3 estadías en curso, llegadas pendientes,
un turno de caja abierto con movimientos y bitácora de relevo.

| Usuario | Rol |
|---|---|
| `root` | Administrador |
| `admin` | Recepción admin |
| `recepcion` | Recepción |
| `contadora` | Contaduría |
| `duenio` | Propietario (solo lectura) |

`db reset` reconstruye el esquema desde cero, así que también sirve de prueba:
si una migración dependiera de un estado que sólo existe en producción, falla acá.

### Opción B — contra un proyecto de Supabase

```bash
npx supabase link --project-ref <tu-project-ref>
npx supabase db push     # aplica las 82 migraciones
npm run dev
```

> El primer usuario se crea desde el dashboard de Supabase. Su perfil nace con
> rol `pending` (sin acceso): asignale `root` desde el editor SQL para empezar.

---

## Base de datos

El esquema completo vive en `supabase/migrations/`, versionado y ordenado por
timestamp. Cada migración documenta **por qué** existe, no solo qué hace.

```bash
npx supabase db push      # aplicar pendientes
npx supabase migration list
```

Dos reglas aprendidas a los golpes, documentadas en el propio SQL:

- **Nunca crear usuarios de auth por SQL directo.** Deja columnas de token en
  `NULL` y GoTrue falla con un error genérico de credenciales.
- **Al agregar un parámetro a una RPC hay que dropear la firma anterior.** Con
  dos firmas vivas, la llamada por nombre de PostgREST queda ambigua y falla en
  runtime.

---

## Tests

```bash
npm test          # 184 tests
npm run lint
npm run build
```

Los tests cubren el **dominio** y los **contratos con la base**: la aritmética de
tramos, el desglose de pagos mixtos, las reglas de respaldo, los grupos de roles y
el payload exacto que se manda a cada RPC.

Ese último grupo nació de un bug real: un reemplazo de texto sin límite de
ocurrencias borró un parámetro de una llamada RPC. TypeScript no lo vio —el
payload de `supabase.rpc()` es un objeto sin tipar— y el error apareció recién en
producción. Ahora hay un test que afirma el payload completo, y se verificó que
falla al quitar la clave.

El entorno local (`npx supabase db reset`) es la otra red de seguridad: replica
las 82 migraciones desde cero y valida que el esquema sea reconstruible.

**Límite conocido:** la lógica en plpgsql no tiene tests automatizados. Se
verifica con transacciones revertidas contra la base real. Migrar eso a pgTAP es
el siguiente paso natural.

---

## Despliegue

Frontend estático (Netlify o Amplify, configuración incluida) y backend en
Supabase. Detalle completo en [`DEPLOY.md`](./DEPLOY.md).

```bash
npm run build     # genera dist/
```

---

## Licencia

Software propietario desarrollado para el Hotel Monasterio.
