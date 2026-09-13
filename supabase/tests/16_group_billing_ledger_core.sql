-- =====================================================================
-- Ledger institucional: booking_balances (change: group-billing, Slice 1).
--
-- Las reservas institucionales ("payer_mode='client'", stage 6) necesitan
-- un libro contable append-only e inmutable: el contrato pactado al crear
-- (contract_agreed), los adelantos recibidos (advance_received) y el cierre
-- del grupo (group_closed). NUNCA un "room_settled" ni una reversa: el
-- saldo se calcula siempre restando, jamás editando una fila ya escrita.
-- Esta migración es la base -- el resto del stage 6 (contrato, tarifa
-- congelada, adelantos, cierre automático) se apoya en esta tabla y en
-- net_owed_bs(). Ninguna reserva "each_stay" se ve afectada.
--
-- `receivables` gana `booking_id` (con índice único parcial: a lo sumo una
-- cuenta por cobrar por booking) para que el Slice 5 (cierre de grupo)
-- pueda dejar la deuda pendiente contra el booking completo, no contra una
-- reserva individual.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(26);

-- ---------------------------------------------------------------------
-- 0) Forma del esquema.
-- ---------------------------------------------------------------------
select has_table('public', 'booking_balances', 'la tabla booking_balances existe');
select has_column('public', 'booking_balances', 'booking_id', 'booking_balances.booking_id existe');
select col_not_null('public', 'booking_balances', 'booking_id', 'booking_id es NOT NULL');
select has_column('public', 'booking_balances', 'event_type', 'booking_balances.event_type existe');
select col_not_null('public', 'booking_balances', 'event_type', 'event_type es NOT NULL');
select has_column('public', 'booking_balances', 'amount_bs', 'booking_balances.amount_bs existe');
select col_not_null('public', 'booking_balances', 'amount_bs', 'amount_bs es NOT NULL');
select has_column('public', 'booking_balances', 'reservation_id', 'booking_balances.reservation_id existe');
select has_column('public', 'booking_balances', 'payment_method', 'booking_balances.payment_method existe');
select has_column('public', 'booking_balances', 'cash_movement_id', 'booking_balances.cash_movement_id existe');
select has_column('public', 'booking_balances', 'notes', 'booking_balances.notes existe');
select has_column('public', 'booking_balances', 'created_by', 'booking_balances.created_by existe');
select has_column('public', 'booking_balances', 'created_at', 'booking_balances.created_at existe');
select has_column('public', 'receivables', 'booking_id', 'receivables.booking_id existe (nueva columna de este slice)');

-- ---------------------------------------------------------------------
-- 1) RLS: sólo lectura, ninguna política de escritura.
-- ---------------------------------------------------------------------
select policies_are('public', 'booking_balances', array['booking_balances_read'],
  'booking_balances sólo tiene la política de lectura; no hay insert/update/delete por RLS (sólo RPC/trigger)');

-- ---------------------------------------------------------------------
-- 2) Grants de net_owed_bs: authenticated sí, anon no (V-C).
-- ---------------------------------------------------------------------
select ok(not has_function_privilege('anon', 'public.net_owed_bs(uuid)', 'execute'),
  'anon NO puede ejecutar net_owed_bs');
select ok(has_function_privilege('authenticated', 'public.net_owed_bs(uuid)', 'execute'),
  'authenticated SÍ puede ejecutar net_owed_bs');

-- ---------------------------------------------------------------------
-- 3) Fixtures (como postgres/superusuario, antes de bajar de rol).
-- ---------------------------------------------------------------------
create temp table fixture as
select b.id as booking_id
from public.bookings b
limit 1;

do $$
declare
  v_booking uuid;
  v_account uuid;
  v_contract_id uuid;
begin
  select booking_id into v_booking from fixture;

  -- (a) contract_agreed=3000 solo -> net_owed_bs=3000
  insert into public.booking_balances (booking_id, event_type, amount_bs, notes)
  values (v_booking, 'contract_agreed', 3000, 'Contrato de prueba')
  returning id into v_contract_id;

  insert into public.receivable_accounts (name, kind)
  values ('Fixture Ledger Core', 'empresa')
  returning id into v_account;

  create temp table fixture_ids as
    select v_booking as booking_id, v_account as account_id, v_contract_id as contract_id;
end $$;

select is(
  public.net_owed_bs((select booking_id from fixture_ids)),
  3000::numeric,
  'contract_agreed=3000 solo -> net_owed_bs=3000'
);

-- (b) + advance_received=1000 -> net_owed_bs=2000
insert into public.booking_balances (booking_id, event_type, amount_bs, notes)
select booking_id, 'advance_received', 1000, 'Adelanto de prueba' from fixture_ids;

select is(
  public.net_owed_bs((select booking_id from fixture_ids)),
  2000::numeric,
  'contract_agreed=3000 + advance_received=1000 -> net_owed_bs=2000'
);

-- (c, neg) event_type fuera de la lista permitida -> rechazado por el CHECK.
select throws_matching(
  $$ insert into public.booking_balances (booking_id, event_type, amount_bs)
     select booking_id, 'refund', 100 from fixture_ids $$,
  'violates check constraint',
  'event_type=refund es rechazado por el CHECK (no existe reversa en este ledger)'
);
select throws_matching(
  $$ insert into public.booking_balances (booking_id, event_type, amount_bs)
     select booking_id, 'room_settled', 100 from fixture_ids $$,
  'violates check constraint',
  'event_type=room_settled es rechazado por el CHECK (no existe ese tipo en este ledger)'
);

-- (e, neg) segundo receivable con el mismo booking_id -> rechazado por el índice único parcial.
insert into public.receivables (account_id, booking_id, amount_bs, concept)
select account_id, booking_id, 500, 'Primer receivable del booking' from fixture_ids;

select throws_matching(
  $$ insert into public.receivables (account_id, booking_id, amount_bs, concept)
     select account_id, booking_id, 700, 'Segundo receivable, mismo booking' from fixture_ids $$,
  'duplicate key value violates unique constraint',
  'un segundo receivable para el mismo booking_id es rechazado por el índice único parcial'
);

-- ---------------------------------------------------------------------
-- 4) (d, neg) Sin política de UPDATE/DELETE: authenticated no puede tocar
--    filas ya escritas, ni siquiera con rol root (append-only real).
-- ---------------------------------------------------------------------
grant select on fixture_ids to authenticated;
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
set local role authenticated;
select is(current_user_role(), 'root', 'fixture: sesión autenticada con rol root');

do $$
declare
  v_update_count int;
  v_delete_count int;
begin
  update public.booking_balances set amount_bs = 9999
    where id = (select contract_id from fixture_ids);
  get diagnostics v_update_count = row_count;

  delete from public.booking_balances
    where id = (select contract_id from fixture_ids);
  get diagnostics v_delete_count = row_count;

  create temp table rls_write_attempt as
    select v_update_count as update_count, v_delete_count as delete_count;
end $$;

select is(
  (select update_count from rls_write_attempt),
  0,
  'authenticated (incluso root) no puede actualizar una fila de booking_balances (sin política de UPDATE)'
);
select is(
  (select delete_count from rls_write_attempt),
  0,
  'authenticated (incluso root) no puede borrar una fila de booking_balances (sin política de DELETE)'
);
reset role;

select is(
  (select amount_bs from public.booking_balances where id = (select contract_id from fixture_ids)),
  3000::numeric,
  'la fila contract_agreed original sigue intacta tras los intentos fallidos de UPDATE/DELETE'
);

select * from finish();
rollback;
