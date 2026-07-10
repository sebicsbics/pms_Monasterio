-- =====================================================================
-- Catálogos de referencia: canales de reserva y formas de pago.
-- Fuente: ETL del histórico (etl/output/stg_estadias.csv), valores canónicos.
--
-- Diseño: 'reservation_method' y 'payment_method' en reservations son varchar
-- libres. Estas tablas les dan un vocabulario CONTROLADO. El campo 'empresa'
-- crudo tenía 677 valores mezclando canal + agencia + empresa-convenio; acá se
-- reduce a una TAXONOMÍA de canal (6 tipos). Las empresas/agencias puntuales
-- son una futura entidad 'clientes/cuentas', no un método de reserva.
--
-- Idempotente (on conflict do nothing).
-- =====================================================================

-- ---------- 1) CANALES DE RESERVA (taxonomía) ----------
create table if not exists public.reservation_channels (
  code        varchar(20) primary key,
  label       varchar(60) not null,
  description text,
  is_active   boolean not null default true
);

insert into public.reservation_channels (code, label, description) values
  ('DIRECTO',  'Directo / Particular', 'Huésped que reserva directo o walk-in (PARTICULAR).'),
  ('OTA',      'Agencia online (OTA)', 'Plataformas: Booking, Expedia, Airbnb.'),
  ('AGENCIA',  'Agencia de viajes',    'Operadores turísticos: Takuaral, Tropical Tours, etc.'),
  ('EMPRESA',  'Empresa / Convenio',   'Cuentas corporativas e instituciones: bancos, ONGs, INTI, Helvetas.'),
  ('REFERIDO', 'Referido',             'Recomendación de un contacto o cliente conocido.'),
  ('EVENTO',   'Evento',               'Bloqueos por eventos: noche de bodas, grupos.')
on conflict (code) do nothing;

-- ---------- 2) FORMAS DE PAGO (catálogo canónico) ----------
-- Excluye AIRBNB (es un canal, se coló en la columna de pago en el histórico).
create table if not exists public.payment_methods (
  code      varchar(20) primary key,
  label     varchar(60) not null,
  is_active boolean not null default true
);

insert into public.payment_methods (code, label) values
  ('EFECTIVO',        'Efectivo'),
  ('TARJETA',         'Tarjeta'),
  ('DEPOSITO',        'Depósito bancario'),
  ('TRANSFERENCIA',   'Transferencia'),
  ('QR',              'Pago QR'),
  ('CTAS_POR_COBRAR', 'Cuentas por cobrar'),
  ('MIXTO',           'Pago mixto (combinado)'),
  ('CORTESIA',        'Cortesía / Free'),
  ('INTERCAMBIO',     'Intercambio de servicios'),
  ('OTRO',            'Otro')
on conflict (code) do nothing;

-- ---------- 3) RLS: catálogos de referencia (mismo patrón que room_types) ----------
-- Fase dev: políticas permisivas, consistentes con las otras tablas de referencia
-- (dev_all_rtypes, dev_all_btypes). El flujo web corre como anon y debe leerlas.
alter table public.reservation_channels enable row level security;
alter table public.payment_methods      enable row level security;

create policy "dev_all_channels" on public.reservation_channels for all using (true) with check (true);
create policy "dev_all_payments" on public.payment_methods      for all using (true) with check (true);
