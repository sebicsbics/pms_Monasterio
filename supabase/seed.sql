-- =====================================================================
-- SEED DE DESARROLLO LOCAL
--
-- El CLI corre este archivo automáticamente al final de cada
-- `supabase db reset`. Es SOLO para el stack local: nunca se aplica al
-- proyecto de la nube (`db push` sólo empuja migraciones).
--
-- Las migraciones ya siembran los catálogos: 36 habitaciones, 13 tipos,
-- formas de pago, canales, categorías de producto y de mantenimiento,
-- tipos y áreas de evento. Acá va lo que falta para que el entorno sea
-- USABLE: usuarios con los que entrar, y una foto de un día de operación.
--
-- TODOS LOS DATOS PERSONALES SON FICTICIOS. No se copió nada de
-- producción: son huéspedes inventados con nombres verosímiles.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) USUARIOS — sin esto no se puede ni entrar a la aplicación.
--
-- Contraseña para todos: `local1234`
-- Se ingresa con el USUARIO (no el correo): root, admin, recepcion,
-- contadora, duenio.
--
-- OJO con las columnas de token: van en '' y NUNCA en NULL. GoTrue no
-- puede deserializar NULL→string de Go y devuelve un 500 que la interfaz
-- muestra como "usuario o contraseña incorrectos" — un rato perdido
-- buscando en el lugar equivocado. Los usuarios creados desde el
-- dashboard traen '' por eso.
--
-- Esto es aceptable ACÁ porque es una base descartable. Para el proyecto
-- de la nube, los usuarios se crean desde el dashboard o con
-- auth.admin.createUser.
-- ---------------------------------------------------------------------
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  created_at, updated_at, raw_app_meta_data, raw_user_meta_data,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
select
  u.id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
  u.username || '@local.test',
  crypt('local1234', gen_salt('bf')),
  now(), now(), now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', u.full_name),
  '', '', '', '', '', '', '', ''
from (values
  ('11111111-1111-1111-1111-111111111111'::uuid, 'root',      'Sebastián Root',   'root'),
  ('22222222-2222-2222-2222-222222222222'::uuid, 'admin',     'Rodrigo Admin',    'reception_admin'),
  ('33333333-3333-3333-3333-333333333333'::uuid, 'recepcion', 'Romina Recepción', 'reception'),
  ('44444444-4444-4444-4444-444444444444'::uuid, 'contadora', 'Carla Contaduría', 'accountant'),
  ('55555555-5555-5555-5555-555555555555'::uuid, 'duenio',    'Natividad Dueña',  'owner')
) as u(id, username, full_name, role)
on conflict (id) do nothing;

-- El trigger handle_new_user ya creó los perfiles, siempre con rol
-- `pending` (nunca toma el rol del metadata: lo controlaría el cliente).
-- Root asigna el rol real, que es exactamente el flujo de producción.
update public.profiles p
   set username = u.username,
       full_name = u.full_name,
       role = u.role,
       must_change_password = false
from (values
  ('11111111-1111-1111-1111-111111111111'::uuid, 'root',      'Sebastián Root',   'root'),
  ('22222222-2222-2222-2222-222222222222'::uuid, 'admin',     'Rodrigo Admin',    'reception_admin'),
  ('33333333-3333-3333-3333-333333333333'::uuid, 'recepcion', 'Romina Recepción', 'reception'),
  ('44444444-4444-4444-4444-444444444444'::uuid, 'contadora', 'Carla Contaduría', 'accountant'),
  ('55555555-5555-5555-5555-555555555555'::uuid, 'duenio',    'Natividad Dueña',  'owner')
) as u(id, username, full_name, role)
where p.id = u.id;

-- ---------------------------------------------------------------------
-- 2) PERSONAL — para el fichaje y la asignación de limpieza.
-- ---------------------------------------------------------------------
with nuevas as (
  insert into public.people (first_name, last_name, email)
  values ('Romina', 'Recepción', 'romina@local.test'),
         ('Rodrigo', 'Admin', 'rodrigo@local.test'),
         ('Lucía', 'Mamani', 'lucia@local.test'),
         ('Elena', 'Quispe', 'elena@local.test')
  returning id, first_name
)
insert into public.employees (person_id, job_title, hire_date, salary, user_id)
select n.id,
       case n.first_name when 'Romina' then 'Recepcionista'
                         when 'Rodrigo' then 'Jefe de recepción'
                         else 'Camarera' end,
       current_date - 200,
       case n.first_name when 'Rodrigo' then 4500 else 3200 end,
       case n.first_name when 'Romina'  then '33333333-3333-3333-3333-333333333333'::uuid
                         when 'Rodrigo' then '22222222-2222-2222-2222-222222222222'::uuid
                         else null end
from nuevas n;

-- ---------------------------------------------------------------------
-- 3) INVENTARIO — minibar con stock, para poder cargar consumos.
-- ---------------------------------------------------------------------
insert into public.products (name, category_id, unit, current_stock, min_stock, sale_price_bs)
select p.name, c.id, p.unit, p.stock, p.minimo, p.precio
from (values
  ('Agua mineral 500ml', 'unidad', 48, 12,  8.00),
  ('Gaseosa 500ml',      'unidad', 36, 12, 12.00),
  ('Cerveza nacional',   'unidad', 24,  6, 18.00),
  ('Snack salado',       'unidad', 30, 10, 10.00),
  ('Chocolate',          'unidad', 20,  8, 15.00)
) as p(name, unit, stock, minimo, precio)
cross join lateral (
  select id from public.product_categories order by name limit 1
) c;

-- ---------------------------------------------------------------------
-- 4) HUÉSPEDES — todos ficticios.
-- ---------------------------------------------------------------------
insert into public.people (id, first_name, last_name, email, phone, birth_date) values
  ('a0000001-0000-4000-8000-000000000001', 'Mariana', 'Peredo',   'mariana.p@example.com',  '70011001', '1988-03-14'),
  ('a0000002-0000-4000-8000-000000000002', 'Joaquín', 'Salvatierra','joaquin.s@example.com','70011002', '1979-11-02'),
  ('a0000003-0000-4000-8000-000000000003', 'Camila',  'Arandia',  'camila.a@example.com',   '70011003', '1995-07-21'),
  ('a0000004-0000-4000-8000-000000000004', 'Ignacio', 'Vaca',     'ignacio.v@example.com',  '70011004', '1983-01-30'),
  ('a0000005-0000-4000-8000-000000000005', 'Lorena',  'Chávez',   'lorena.c@example.com',   '70011005', '1991-09-09'),
  ('a0000006-0000-4000-8000-000000000006', 'Tomás',   'Justiniano','tomas.j@example.com',   '70011006', '1975-05-17'),
  ('a0000007-0000-4000-8000-000000000007', 'Valeria', 'Nogales',  'valeria.n@example.com',  '70011007', '1999-12-05'),
  ('a0000008-0000-4000-8000-000000000008', 'Andrés',  'Ribera',   'andres.r@example.com',   '70011008', '1986-08-23');

insert into public.guests (person_id, passport_number, country_code, city, origin_city, travel_purpose, occupation, transport_means)
values
  ('a0000001-0000-4000-8000-000000000001', 'PE1001', 'BOL', 'La Paz',     'Cochabamba', 'Turismo',  'Diseñadora',  'Bus'),
  ('a0000002-0000-4000-8000-000000000002', 'PE1002', 'ARG', 'Salta',      'Salta',      'Negocios', 'Comerciante', 'Avión'),
  ('a0000003-0000-4000-8000-000000000003', 'PE1003', 'BOL', 'Santa Cruz', 'Santa Cruz', 'Turismo',  'Estudiante',  'Bus'),
  ('a0000004-0000-4000-8000-000000000004', 'PE1004', 'BOL', 'Sucre',      'Sucre',      'Negocios', 'Ingeniero',   'Auto'),
  ('a0000005-0000-4000-8000-000000000005', 'PE1005', 'PER', 'Cusco',      'Cusco',      'Turismo',  'Docente',     'Bus'),
  ('a0000006-0000-4000-8000-000000000006', 'PE1006', 'BRA', 'São Paulo',  'São Paulo',  'Turismo',  'Médico',      'Avión'),
  ('a0000007-0000-4000-8000-000000000007', 'PE1007', 'BOL', 'Tarija',     'Tarija',     'Turismo',  'Contadora',   'Auto'),
  ('a0000008-0000-4000-8000-000000000008', 'PE1008', 'CHL', 'Santiago',   'Iquique',    'Negocios', 'Arquitecto',  'Avión');

-- ---------------------------------------------------------------------
-- 5) OPERACIÓN — tres huéspedes adentro, tres llegadas y una salida.
--
-- El trigger sync_single_stay_segment crea el tramo de cada reserva sola,
-- así que el folio muestra el desglose correcto sin sembrarlo a mano.
-- ---------------------------------------------------------------------
with hab as (
  select rm.id as room_id, rm.room_number,
         (select o.room_type_id from public.room_type_options o
           where o.room_id = rm.id order by o.room_type_id limit 1) as type_id,
         row_number() over (order by rm.room_number::int) as n
  from public.rooms rm
)
insert into public.reservations (
  guest_id, room_id, room_type_id, check_in_date, check_out_date,
  reservation_method, payment_status, total_amount_bs, status, num_guests
)
select d.guest_id, h.room_id, h.type_id, d.ci, d.co, d.metodo, d.pago, d.total, d.estado, d.pax
from (values
  -- Dentro del hotel
  ('a0000001-0000-4000-8000-000000000001'::uuid, 1, current_date - 2, current_date + 1, 'walk-in',  'pending', 1050.00, 'checked_in', 1),
  ('a0000002-0000-4000-8000-000000000002'::uuid, 2, current_date - 1, current_date + 2, 'phone',    'pending', 1500.00, 'checked_in', 2),
  ('a0000003-0000-4000-8000-000000000003'::uuid, 3, current_date - 3, current_date + 1, 'web',      'pending',  960.00, 'checked_in', 1),
  -- Llegadas pendientes de check-in
  ('a0000004-0000-4000-8000-000000000004'::uuid, 4, current_date,     current_date + 2, 'whatsapp', 'pending',  700.00, 'confirmed',  1),
  ('a0000005-0000-4000-8000-000000000005'::uuid, 5, current_date,     current_date + 3, 'email',    'pending', 1350.00, 'confirmed',  2),
  ('a0000006-0000-4000-8000-000000000006'::uuid, 6, current_date + 1, current_date + 4, 'web',      'pending', 1800.00, 'confirmed',  2),
  -- Ya se fue: sirve para ver el historial y la analítica
  ('a0000007-0000-4000-8000-000000000007'::uuid, 7, current_date - 5, current_date - 2, 'phone',    'paid',     900.00, 'checked_out',1)
) as d(guest_id, n, ci, co, metodo, pago, total, estado, pax)
join hab h on h.n = d.n;

-- Folio de cada estadía activa o cerrada.
insert into public.folios (reservation_id, closed_at)
select r.id, case when r.status = 'checked_out' then now() - interval '2 days' end
from public.reservations r
where r.status in ('checked_in', 'checked_out');

-- Las habitaciones de quienes están adentro quedan ocupadas; la del que
-- se fue, sucia — igual que en la operación real.
update public.rooms set operational_status = 'occupied'
 where id in (select room_id from public.reservations where status = 'checked_in');
update public.rooms set operational_status = 'dirty'
 where id in (select room_id from public.reservations where status = 'checked_out');

-- Un par de consumos cargados al folio.
insert into public.folio_charges (folio_id, description, amount_bs)
select f.id, c.descripcion, c.monto
from public.folios f
join public.reservations r on r.id = f.reservation_id and r.status = 'checked_in'
join lateral (values ('Restaurante', 85.00), ('Minibar', 26.00)) as c(descripcion, monto) on true
where r.guest_id = 'a0000002-0000-4000-8000-000000000002';

-- ---------------------------------------------------------------------
-- 6) CAJA — un turno abierto con movimientos, para el arqueo.
-- ---------------------------------------------------------------------
insert into public.cash_sessions (id, opened_by, opened_at, opening_balance_bs, status)
values ('c0000001-0000-4000-8000-000000000001',
        '33333333-3333-3333-3333-333333333333', now() - interval '6 hours', 500.00, 'open');

insert into public.cash_movements (session_id, kind, category, amount_bs, concept, created_by, payment_method, created_at)
values
  ('c0000001-0000-4000-8000-000000000001', 'income',  'cobro_habitacion', 900.00, 'Check-out Hab. 7',
   '33333333-3333-3333-3333-333333333333', 'EFECTIVO', now() - interval '5 hours'),
  ('c0000001-0000-4000-8000-000000000001', 'income',  'venta_minibar',     26.00, 'Minibar Hab. 2',
   '33333333-3333-3333-3333-333333333333', 'EFECTIVO', now() - interval '4 hours'),
  ('c0000001-0000-4000-8000-000000000001', 'expense', 'compras',          150.00, 'Insumos de limpieza',
   '33333333-3333-3333-3333-333333333333', 'EFECTIVO', now() - interval '3 hours'),
  -- No efectivo: cae en la pestaña "Otros medios" y NO mueve el arqueo.
  ('c0000001-0000-4000-8000-000000000001', 'income',  'cobro_habitacion', 450.00, 'Cobro por QR',
   '33333333-3333-3333-3333-333333333333', 'QR',       now() - interval '2 hours');

-- ---------------------------------------------------------------------
-- 7) RELEVO DE TURNO — bitácora y tareas.
-- ---------------------------------------------------------------------
insert into public.info_notes (content, created_by, created_at) values
  ('Se dejó una campera azul en la Hab. 3, del huésped Camila Arandia.',
   '33333333-3333-3333-3333-333333333333', now() - interval '4 hours'),
  ('El huésped de la Hab. 2 pidió salida tardía hasta las 15:00.',
   '33333333-3333-3333-3333-333333333333', now() - interval '2 hours');

insert into public.tasks (task_type, notes, assigned_to_name, status, created_by) values
  ('cleaning',    'Limpieza profunda Hab. 7 tras el check-out', 'Lucía Mamani', 'pending',
   '33333333-3333-3333-3333-333333333333'),
  ('maintenance', 'Revisar la ducha de la Hab. 3: pierde presión', 'Elena Quispe', 'in_progress',
   '33333333-3333-3333-3333-333333333333');

-- ---------------------------------------------------------------------
-- 8) FICHAJE — un turno abierto y dos cerrados, para ver el historial y
--    poder probar el cierre forzado por root.
-- ---------------------------------------------------------------------
insert into public.time_entries (user_id, clock_in, clock_out) values
  ('33333333-3333-3333-3333-333333333333', now() - interval '6 hours', null),
  ('33333333-3333-3333-3333-333333333333', now() - interval '2 days',  now() - interval '2 days' + interval '8 hours'),
  ('22222222-2222-2222-2222-222222222222', now() - interval '1 day',   now() - interval '1 day' + interval '9 hours');

-- ---------------------------------------------------------------------
-- 9) ANTICIPO — sobre una reserva que todavía no llegó.
-- ---------------------------------------------------------------------
insert into public.anticipos (reservation_id, amount_bs, payment_method, notes, received_by, received_at)
select r.id, 400.00, 'QR', 'Adelanto por WhatsApp',
       '33333333-3333-3333-3333-333333333333', now() - interval '1 day'
from public.reservations r
where r.guest_id = 'a0000006-0000-4000-8000-000000000006';

-- =====================================================================
-- Listo. Entrá con cualquiera de estos usuarios (contraseña local1234):
--
--   root       → administrador, ve y hace todo
--   admin      → recepción admin: + descuentos y corrección de anticipos
--   recepcion  → operación diaria
--   contadora  → analítica, arqueos, inventario, legajos
--   duenio     → SOLO LECTURA: ve todo, no modifica nada
-- =====================================================================
