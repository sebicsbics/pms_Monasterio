-- =====================================================================
-- Contrato institucional: create_bulk_reservation soporta payer_mode,
-- rate_mode y cortesía por habitación al crear (change: group-billing,
-- stage 6, Slice 2b -- core, branch feat/booking-11-contract-bulk).
--
-- Cambia la aridad de create_bulk_reservation (10 -> 18 parámetros: 8
-- nuevos al final, todos con default = comportamiento actual) -- DROP +
-- CREATE en la misma migración (R2.8), re-grant explícito (V-B), porque
-- un DROP borra los grants existentes.
--
-- V-A (verificado antes de escribir esto): select pg_get_functiondef(
-- 'public.create_bulk_reservation(jsonb,text,text,text,text,date,date,
-- text,numeric,text)'::regprocedure) es byte-idéntico al body que cita
-- el diseño (sdd/group-billing/design-part-2, Slice 2b) -- sin drift
-- desde booking-10. La cortesía/headcount por habitación NO son
-- parámetros nuevos de la función (van dentro de cada elemento de
-- p_rooms: is_courtesy/courtesy_reason/num_guests), a diferencia de
-- create_reservation (Slice 2a2) que sí los llevó como parámetros
-- porque es de una sola habitación. Por esto, a diferencia de
-- feat/booking-10 (que encontró una discrepancia de aridad 22 vs 23
-- real), acá se contó el propio SQL citado por el diseño dos veces
-- (la lista de parámetros del CREATE y la lista de tipos del
-- REVOKE/GRANT) y AMBAS dan 18 -- el "18-arg" del diseño es correcto
-- para este slice, no hay discrepancia que documentar.
--
-- Orden dentro del body (mismo patrón POST-fix de feat/booking-10,
-- sdd/group-billing/review-booking-10 -- se copia la forma YA
-- corregida, no la original con el NULL-trap): (a) validaciones
-- existentes sin tocar; (b) payer_mode/rate_mode con `is null or`
-- explícito e INCONDICIONAL (ambos parámetros terminan en columnas NOT
-- NULL con su propio CHECK de dominio), gate de rol para
-- payer_mode='client' ANTES de llamar a _resolve_receivable_account
-- (SECURITY DEFINER, evade la RLS de receivable_accounts por sí solo --
-- sdd/group-billing/booking-9-fixes #367 punto 4); (c) combos
-- rate_mode/precio a nivel booking (una sola vez, no por habitación);
-- resolución de cuenta UNA vez, ANTES del loop de habitaciones (fuera
-- del bloque exception por-habitación: si falla, aborta TODO el alta,
-- R10.4); (d) insert de bookings con los campos de contrato; (e) loop:
-- cortesía y headcount por habitación (JSON, con coalesce -- NUNCA se
-- exige un valor explícito para is_courtesy porque no es un enum de
-- negocio sin default razonable, igual que create_reservation), total
-- por habitación (cortesía=0 / precio x personas x noches en modo
-- persona / tarifa x noches en modo habitación), cambio de tarifa en
-- modo habitación (client -> _apply_rate_change_direct nunca pending;
-- each_stay -> apply_rate_change sin cambios); (f) al final del loop,
-- UNA fila contract_agreed = suma de total_amount_bs de TODAS las
-- reservas de la booking (misma forma "suma sobre booking_id,
-- reservation_id NULL" que feat/booking-10, para no duplicar lógica).
--
-- IMPORTANTE (comportamiento actual, documentado para feat/booking-12):
-- el bloque exception por-habitación es EL MISMO que ya existía (best-
-- effort: una habitación que falla queda en `failed`, el resto de la
-- booking se sigue creando) -- esta ronda NO agrega un `raise;` para
-- payer_mode='client'. Esto significa que, para una booking 'client'
-- con VARIAS habitaciones donde una falla, la booking en sí y las
-- habitaciones que sí se pudieron crear quedan persistidas (incluyendo
-- una posible receivable_accounts nueva, resuelta ANTES del loop) --
-- no es all-or-nothing todavía. feat/booking-12-contract-bulk-
-- atomicity agrega el `raise;` y sus pruebas de atomicidad; este slice
-- sólo prueba que una booking client de UNA sola habitación con un
-- error de validación (ej. num_guests faltante en modo persona) no deja
-- ninguna reserva creada ni contract_agreed insertado (trivialmente
-- cierto hoy: al ser la única habitación, v_created queda vacío y el
-- chequeo `jsonb_array_length(v_created) > 0` evita el insert de
-- contract_agreed) -- NO prueba el caso multi-habitación con una
-- creada y otra fallida, que es exactamente el gap que booking-12
-- cierra.
-- =====================================================================

drop function if exists public.create_bulk_reservation(
  jsonb, text, text, text, text, date, date, text, numeric, text
);

create or replace function public.create_bulk_reservation(
  p_rooms jsonb, p_first_name text, p_last_name text, p_phone text, p_email text,
  p_check_in date, p_check_out date, p_method text, p_rate_bs numeric default null,
  p_reason text default null,
  p_payer_mode text default 'each_stay', p_rate_mode text default 'room',
  p_agreed_unit_price_bs numeric default null, p_receivable_account_id uuid default null,
  p_new_account_name text default null, p_new_account_kind text default null,
  p_new_account_contact text default null, p_new_account_notes text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_person_id uuid; v_booking_id uuid; v_nights int;
  v_created jsonb := '[]'::jsonb; v_failed jsonb := '[]'::jsonb;
  elem jsonb; v_room_id uuid; v_room_type_id uuid; v_guests int; v_rate numeric(10,2);
  v_max_occ int; v_occ_reason text; v_reservation_id uuid; v_occupants jsonb; occ jsonb;
  v_doc text; v_occ_person uuid; v_is_first boolean;
  v_account_id uuid; v_is_courtesy boolean; v_courtesy_reason text; v_contract_total numeric(10,2);
begin
  -- (a) Validaciones existentes, SIN CAMBIOS.
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado para crear reservas';
  end if;
  if p_check_out <= p_check_in then
    raise exception 'La fecha de salida debe ser posterior a la de entrada';
  end if;
  if nullif(trim(p_phone), '') is null and nullif(trim(p_email), '') is null then
    raise exception 'Se requiere al menos un contacto (celular o correo)';
  end if;
  if jsonb_array_length(coalesce(p_rooms, '[]'::jsonb)) = 0 then
    raise exception 'Seleccioná al menos una habitación';
  end if;

  -- (b) payer_mode/rate_mode (incondicional, `is null or` explícito --
  -- fix sdd/group-billing/review-booking-10, mismo patrón de #368) +
  -- gate de rol para 'client', ANTES de tocar receivable_accounts.
  if p_payer_mode is null or p_payer_mode not in ('client', 'each_stay') then
    raise exception 'Modalidad de pago inválida: %', p_payer_mode;
  end if;
  if p_rate_mode is null or p_rate_mode not in ('room', 'person') then
    raise exception 'Modalidad de tarifa inválida: %', p_rate_mode;
  end if;
  if p_payer_mode = 'client' and public.current_user_role() not in ('root', 'reception_admin') then
    raise exception 'Solo un administrador de recepción puede crear una reserva institucional';
  end if;

  -- (c) Combos rate_mode/precio a nivel booking (una sola vez, no por
  -- habitación). payer_mode y rate_mode ya están garantizados no-nulos
  -- y de dominio válido por los checks de arriba.
  if p_rate_mode = 'person' and p_payer_mode <> 'client' then
    raise exception 'La tarifa por persona sólo aplica a reservas institucionales';
  end if;
  if p_rate_mode = 'person' and coalesce(p_agreed_unit_price_bs, 0) <= 0 then
    raise exception 'Debe indicar un precio pactado por persona positivo';
  end if;

  v_account_id := null;
  if p_payer_mode = 'client' then
    -- Se resuelve UNA vez, ANTES del loop de habitaciones (fuera del
    -- bloque exception por-habitación): si falla, aborta TODO el alta
    -- (R10.4).
    v_account_id := public._resolve_receivable_account(
      p_receivable_account_id, p_new_account_name, p_new_account_kind,
      p_new_account_contact, p_new_account_notes
    );
  end if;

  v_nights := p_check_out - p_check_in;

  if nullif(p_email, '') is not null then
    select id into v_person_id from public.people where email = p_email;
  end if;
  if v_person_id is not null then
    update public.people set first_name = p_first_name, last_name = p_last_name,
      phone = coalesce(nullif(p_phone, ''), phone)
    where id = v_person_id;
  else
    insert into public.people (first_name, last_name, email, phone)
    values (p_first_name, p_last_name, nullif(p_email, ''), nullif(p_phone, ''))
    returning id into v_person_id;
  end if;

  -- (d) Insert de bookings con los campos de contrato. agreed_unit_price_bs
  -- se manda NULL fuera de rate_mode='person' (misma razón que
  -- feat/booking-10: bookings_room_rate_has_no_unit_price ya lo exige,
  -- esto evita depender sólo de ese error genérico).
  insert into public.bookings (
    contact_person_id, payer_mode, rate_mode, agreed_unit_price_bs, receivable_account_id
  ) values (
    v_person_id, p_payer_mode, p_rate_mode,
    case when p_rate_mode = 'person' then p_agreed_unit_price_bs else null end,
    v_account_id
  ) returning id into v_booking_id;

  for elem in select value from jsonb_array_elements(p_rooms) as t(value)
  loop
    -- v_room_id/v_room_type_id se asignan ACÁ, ANTES del begin -- igual
    -- que en el body anterior (20260911050000_occupancy_override_
    -- reason.sql) -- porque el bloque exception los usa para construir
    -- failed[]. Nunca quedan "stale": esta asignación es lo PRIMERO que
    -- corre en cada vuelta del loop, sin importar si la vuelta anterior
    -- lanzó una excepción, así que siempre reflejan la habitación de
    -- ESTA iteración.
    v_room_id      := (elem->>'room_id')::uuid;
    v_room_type_id := (elem->>'room_type_id')::uuid;
    begin
      -- FIX (sdd/group-billing/review-booking-11): v_is_courtesy/
      -- v_courtesy_reason se calculan ACÁ DENTRO del begin (no antes,
      -- como en un intento previo) -- el cast `(elem->>'is_courtesy')::
      -- boolean` es NUEVO en este slice y puede lanzar 22P02 para un
      -- valor mal formado (ej. 'not-a-bool'). Si ese cast corriera
      -- ANTES del begin, abortaría TODA la llamada (incluyendo bookings
      -- each_stay, que nunca deberían verse afectadas por un dato mal
      -- formado en un campo que ni siquiera usan) en vez de quedar
      -- contenido en el best-effort por-habitación de esta iteración.
      v_is_courtesy  := coalesce((elem->>'is_courtesy')::boolean, false);
      v_courtesy_reason := nullif(trim(elem->>'courtesy_reason'), '');

      if v_is_courtesy and p_payer_mode <> 'client' then
        raise exception 'La cortesía al crear sólo aplica a reservas institucionales';
      end if;
      if v_is_courtesy and v_courtesy_reason is null then
        raise exception 'La cortesía requiere un motivo (habitación %)', v_room_id;
      end if;

      -- (e) Headcount: en modo persona (client, no cortesía) es
      -- obligatorio y explícito -- sin coalesce a 1 (R2.5). En
      -- cualquier otro caso (room mode, each_stay, o cortesía) se
      -- mantiene EXACTAMENTE el comportamiento de hoy (coalesce a 1).
      if p_payer_mode = 'client' and p_rate_mode = 'person' and not v_is_courtesy then
        v_guests := (elem->>'num_guests')::int;
        if v_guests is null then
          raise exception 'Indicá la cantidad de huéspedes de la habitación % (tarifa por persona)', v_room_id;
        end if;
      else
        v_guests := coalesce((elem->>'num_guests')::int, 1);
      end if;

      if v_guests < 1 then
        raise exception 'Cada habitación necesita al menos 1 persona';
      end if;
      if v_guests > 20 then
        raise exception 'Ocupación implausible (% personas)', v_guests;
      end if;

      select rt.base_price_bs, rt.max_occupancy into v_rate, v_max_occ
      from public.room_type_options o
      join public.room_types rt on rt.id = o.room_type_id
      where o.room_id = v_room_id and o.room_type_id = v_room_type_id;

      if v_rate is null then
        raise exception 'El tipo seleccionado no corresponde a la habitación';
      end if;

      if v_max_occ is not null and v_guests > v_max_occ then
        v_occ_reason := nullif(trim(elem->>'occupancy_reason'), '');
        if v_occ_reason is null then
          raise exception
            'La habitación admite % huésped(es); estás registrando %. Indique un motivo para exceder el límite.',
            v_max_occ, v_guests;
        end if;
      else
        v_occ_reason := null;
      end if;

      perform 1 from public.rooms where id = v_room_id for update;
      if exists (
        select 1 from public.reservations r
        where r.room_id = v_room_id
          and r.status in ('confirmed', 'checked_in')
          and r.check_in_date < p_check_out
          and p_check_in < r.check_out_date
      ) then
        raise exception 'La habitación ya no está disponible para esas fechas';
      end if;

      insert into public.reservations (
        guest_id, room_id, room_type_id, check_in_date, check_out_date,
        reservation_method, payment_status, total_amount_bs, status, num_guests,
        booking_id, is_courtesy, courtesy_reason
      ) values (
        null, v_room_id, v_room_type_id, p_check_in, p_check_out,
        p_method, 'pending',
        case
          when v_is_courtesy then 0
          when p_payer_mode = 'client' and p_rate_mode = 'person' then p_agreed_unit_price_bs * v_guests * v_nights
          else v_rate * v_nights
        end,
        'confirmed', v_guests, v_booking_id, v_is_courtesy, v_courtesy_reason
      ) returning id into v_reservation_id;

      if v_occ_reason is not null then
        insert into public.occupancy_overrides (
          reservation_id, max_occupancy, resulting_occupancy, reason
        ) values (v_reservation_id, v_max_occ, v_guests, v_occ_reason);
      end if;

      v_occupants := coalesce(elem->'occupants', '[]'::jsonb);
      v_is_first := true;
      for occ in select value from jsonb_array_elements(v_occupants) as t(value)
      loop
        if coalesce(trim(occ->>'first_name'), '') = ''
           or coalesce(trim(occ->>'last_name'), '') = '' then
          raise exception 'Cada huésped requiere nombre y apellido';
        end if;

        v_doc := nullif(trim(occ->>'document'), '');
        v_occ_person := null;
        if v_doc is not null then
          select person_id into v_occ_person
          from public.guests where passport_number = v_doc;
        end if;

        if v_occ_person is not null then
          update public.people set
            first_name = trim(occ->>'first_name'),
            last_name  = trim(occ->>'last_name'),
            birth_date = coalesce(nullif(occ->>'birth_date', '')::date, birth_date)
          where id = v_occ_person;
        else
          insert into public.people (first_name, last_name, birth_date)
          values (
            trim(occ->>'first_name'), trim(occ->>'last_name'),
            nullif(occ->>'birth_date', '')::date
          )
          returning id into v_occ_person;
          insert into public.guests (person_id, passport_number)
          values (v_occ_person, v_doc);
        end if;

        if v_is_first then
          update public.reservations set guest_id = v_occ_person
            where id = v_reservation_id;
          insert into public.reservation_guests (reservation_id, person_id, role, confirmed_at)
          values (v_reservation_id, v_occ_person, 'holder', null)
          on conflict (reservation_id, person_id) do update set role = 'holder';
          v_is_first := false;
        else
          insert into public.reservation_guests (reservation_id, person_id, role, confirmed_at)
          values (v_reservation_id, v_occ_person, 'companion', null)
          on conflict (reservation_id, person_id) do nothing;
        end if;
      end loop;

      -- Cambio de tarifa en modo habitación: SIN CAMBIOS para each_stay
      -- (misma llamada a apply_rate_change de siempre); en modo persona
      -- no aplica (el precio ya es el pactado). Para client+room con
      -- tarifa distinta a la de lista, se aplica DIRECTO y se audita --
      -- nunca genera una rate_discount_requests pendiente (decisión
      -- #339: sólo root/reception_admin llegan hasta acá).
      if p_rate_mode <> 'person' and p_rate_bs is not null and p_rate_bs <> v_rate then
        if p_reason is null or char_length(trim(p_reason)) = 0 then
          raise exception 'La justificación es obligatoria para cambiar la tarifa';
        end if;
        if p_rate_bs <= 0 then
          raise exception 'La tarifa debe ser un monto positivo';
        end if;
        if p_payer_mode = 'client' then
          perform public._apply_rate_change_direct(
            v_reservation_id, v_room_type_id, v_rate, v_nights, p_rate_bs, p_reason
          );
        else
          perform public.apply_rate_change(
            v_reservation_id, v_room_type_id, v_rate, v_nights, p_rate_bs, p_reason
          );
        end if;
      end if;

      v_created := v_created || to_jsonb(v_reservation_id::text);
    exception when others then
      -- Best-effort por habitación, SIN CAMBIOS respecto al body
      -- anterior (para AMBOS payer_mode) -- el all-or-nothing para
      -- 'client' es feat/booking-12-contract-bulk-atomicity, no este
      -- slice (ver nota al comienzo del archivo).
      v_failed := v_failed || jsonb_build_object('room_id', v_room_id, 'error', sqlerrm);
    end;
  end loop;

  -- (f) contract_agreed: al final, sobre TODA la booking (una sola vez,
  -- sólo si se creó al menos una habitación). Suma directa sobre
  -- booking_id (no sobre v_created) -- las habitaciones fallidas nunca
  -- persisten (savepoint implícito del bloque exception), así que da el
  -- mismo resultado; misma forma que create_reservation
  -- (feat/booking-10), para no duplicar lógica entre ambos slices.
  if p_payer_mode = 'client' and jsonb_array_length(v_created) > 0 then
    select coalesce(sum(total_amount_bs), 0) into v_contract_total
    from public.reservations where booking_id = v_booking_id;
    insert into public.booking_balances (booking_id, event_type, amount_bs, notes)
    values (v_booking_id, 'contract_agreed', v_contract_total, 'Contrato al crear el grupo');
  end if;

  return jsonb_build_object('created', v_created, 'failed', v_failed);
end;
$$;

revoke execute on function public.create_bulk_reservation(
  jsonb, text, text, text, text, date, date, text, numeric, text,
  text, text, numeric, uuid, text, text, text, text
) from public, anon;
grant execute on function public.create_bulk_reservation(
  jsonb, text, text, text, text, date, date, text, numeric, text,
  text, text, numeric, uuid, text, text, text, text
) to authenticated;
