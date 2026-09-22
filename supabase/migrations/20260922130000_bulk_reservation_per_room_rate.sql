-- Reescritura de SOLO EL CUERPO de create_bulk_reservation (misma firma de
-- 18 parámetros, sin DROP): el precio pactado dejaba de ser una propiedad
-- de la habitación y pasaba a serlo de la RESERVA COMPLETA -- p_rate_bs
-- (booking-level) se comparaba contra v_rate (el precio de LISTA de cada
-- tipo de CADA habitación dentro del loop), así que un solo valor
-- ingresado en el alta se aplicaba a TODAS las habitaciones del grupo por
-- igual, aplanando precios distintos (ej. habitación 6 a 480 y habitación
-- 7 a 350 quedaban ambas en 400 si se tipeaba 400 una sola vez) y
-- registrando una auditoría de "cambio de tarifa" en cada una aunque el
-- precio nuevo coincidiera con el de lista de sólo una de ellas. Defecto
-- real encontrado en sandbox (change: per-room-rate-in-bulk).
--
-- Fix: el precio pactado ahora viaja DENTRO de cada elemento de p_rooms
-- (`rate_bs`, opcional) -- una propiedad de la ESTADÍA de esa habitación,
-- no de la reserva grupal. p_rate_bs se CONSERVA en la firma como
-- FALLBACK: se usa únicamente para las habitaciones que NO traen su
-- propio `rate_bs` en el jsonb. El precio por habitación siempre gana
-- sobre el fallback. p_reason sigue siendo ÚNICO para toda el alta
-- (decisión de usuario, sdd/per-room-rate-in-bulk): se pide UNA sola vez
-- y se graba tal cual en la auditoría (rate_overrides/rate_discount_
-- requests) de CADA habitación cuyo precio efectivo difiera de su propio
-- precio de lista -- no se pide un motivo separado por habitación.
--
-- Resolución del precio efectivo por habitación (ANTES del bloque
-- exception, junto con v_room_number, porque participa tanto del total
-- inicial como del bloque de auditoría más abajo):
--   v_room_rate_bs := coalesce((elem->>'rate_bs')::numeric, p_rate_bs, v_rate)
-- Nota: v_rate (precio de lista del tipo elegido para ESA habitación) se
-- conoce recién después del select a room_type_options/room_types, así
-- que v_room_rate_bs se calcula ahí mismo, no antes.
--
-- Resto del cuerpo SIN CAMBIOS de lógica: mismas validaciones, mismo gate
-- de rol, misma atomicidad `raise;` para payer_mode='client', mismo
-- candado de sobre-ocupación, mismos helpers de auditoría
-- (apply_rate_change / _apply_rate_change_direct), sólo que ahora
-- comparan contra v_room_rate_bs en vez de contra el parámetro
-- booking-level p_rate_bs.
create or replace function public.create_bulk_reservation(
  p_rooms jsonb, p_first_name text, p_last_name text, p_phone text, p_email text,
  p_check_in date, p_check_out date, p_method text, p_rate_bs numeric default null::numeric,
  p_reason text default null::text, p_payer_mode text default 'each_stay'::text,
  p_rate_mode text default 'room'::text, p_agreed_unit_price_bs numeric default null::numeric,
  p_receivable_account_id uuid default null::uuid, p_new_account_name text default null::text,
  p_new_account_kind text default null::text, p_new_account_contact text default null::text,
  p_new_account_notes text default null::text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_person_id uuid; v_booking_id uuid; v_nights int;
  v_created jsonb := '[]'::jsonb; v_failed jsonb := '[]'::jsonb;
  elem jsonb; v_room_id uuid; v_room_type_id uuid; v_guests int; v_rate numeric(10,2);
  v_max_occ int; v_occ_reason text; v_reservation_id uuid; v_occupants jsonb; occ jsonb;
  v_doc text; v_occ_person uuid; v_is_first boolean;
  v_account_id uuid; v_is_courtesy boolean; v_courtesy_reason text; v_contract_total numeric(10,2);
  v_room_number text; v_room_rate_bs numeric(10,2);
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
    -- (R10.4). Con el `raise;` de este slice, si una habitación falla
    -- DESPUÉS, esta cuenta (nueva o existente) también queda revertida
    -- junto con todo lo demás -- ver escenario (a)/(d) del test.
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
    -- ESTA iteración. v_room_number se resuelve acá también, ANTES del
    -- begin, para que TODO raise exception de esta vuelta (incluso los
    -- de payer_mode='client', que se re-lanzan tal cual con `raise;` y
    -- abortan la llamada completa) pueda nombrar la habitación real en
    -- vez de su UUID interno.
    v_room_id      := (elem->>'room_id')::uuid;
    v_room_type_id := (elem->>'room_type_id')::uuid;
    select room_number into v_room_number from public.rooms where id = v_room_id;
    begin
      -- FIX (sdd/group-billing/review-booking-11): v_is_courtesy/
      -- v_courtesy_reason se calculan ACÁ DENTRO del begin (no antes,
      -- como en un intento previo) -- el cast `(elem->>'is_courtesy')::
      -- boolean` es NUEVO en este slice y puede lanzar 22P02 para un
      -- valor mal formado (ej. 'not-a-bool'). Si ese cast corriera
      -- ANTES del begin, abortaría TODA la llamada (incluyendo bookings
      -- each_stay, que nunca deberían verse afectadas por un dato mal
      -- formado en un campo que ni siquiera usan) en vez de quedar
      -- contenido en el bloque exception de esta iteración.
      v_is_courtesy  := coalesce((elem->>'is_courtesy')::boolean, false);
      v_courtesy_reason := nullif(trim(elem->>'courtesy_reason'), '');

      if v_is_courtesy and p_payer_mode <> 'client' then
        raise exception 'La cortesía al crear sólo aplica a reservas institucionales (habitación %)',
          coalesce(v_room_number, v_room_id::text);
      end if;
      if v_is_courtesy and v_courtesy_reason is null then
        raise exception 'La cortesía requiere un motivo (habitación %)', coalesce(v_room_number, v_room_id::text);
      end if;

      -- (e) Headcount: en modo persona (client, no cortesía) es
      -- obligatorio y explícito -- sin coalesce a 1 (R2.5). En
      -- cualquier otro caso (room mode, each_stay, o cortesía) se
      -- mantiene EXACTAMENTE el comportamiento de hoy (coalesce a 1).
      if p_payer_mode = 'client' and p_rate_mode = 'person' and not v_is_courtesy then
        v_guests := (elem->>'num_guests')::int;
        if v_guests is null then
          raise exception 'Indicá la cantidad de huéspedes de la habitación % (tarifa por persona)',
            coalesce(v_room_number, v_room_id::text);
        end if;
      else
        v_guests := coalesce((elem->>'num_guests')::int, 1);
      end if;

      if v_guests < 1 then
        raise exception 'La habitación % necesita al menos 1 persona', coalesce(v_room_number, v_room_id::text);
      end if;
      if v_guests > 20 then
        raise exception 'Ocupación implausible en la habitación % (% personas)',
          coalesce(v_room_number, v_room_id::text), v_guests;
      end if;

      select rt.base_price_bs, rt.max_occupancy into v_rate, v_max_occ
      from public.room_type_options o
      join public.room_types rt on rt.id = o.room_type_id
      where o.room_id = v_room_id and o.room_type_id = v_room_type_id;

      if v_rate is null then
        raise exception 'El tipo seleccionado no corresponde a la habitación %',
          coalesce(v_room_number, v_room_id::text);
      end if;

      -- Precio efectivo de ESTA habitación (sdd/per-room-rate-in-bulk):
      -- el que trae el propio elemento de p_rooms gana; si no trae
      -- ninguno, cae al fallback booking-level p_rate_bs (compatibilidad
      -- con llamadas que todavía no migraron a precio por habitación);
      -- si tampoco hay fallback, es el precio de lista de esta
      -- habitación (v_rate) -- o sea, sin cambio de tarifa.
      v_room_rate_bs := coalesce((elem->>'rate_bs')::numeric, p_rate_bs, v_rate);

      if v_max_occ is not null and v_guests > v_max_occ then
        v_occ_reason := nullif(trim(elem->>'occupancy_reason'), '');
        if v_occ_reason is null then
          raise exception
            'La habitación % admite % huésped(es); estás registrando %. Indique un motivo para exceder el límite.',
            coalesce(v_room_number, v_room_id::text), v_max_occ, v_guests;
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
        raise exception 'La habitación % ya no está disponible para esas fechas',
          coalesce(v_room_number, v_room_id::text);
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

      -- Cambio de tarifa en modo habitación: SIN CAMBIOS de forma para
      -- each_stay (misma llamada a apply_rate_change de siempre); en
      -- modo persona no aplica (el precio ya es el pactado). Para
      -- client+room con precio distinto al de LISTA DE ESTA HABITACIÓN
      -- se aplica DIRECTO y se audita -- nunca genera una
      -- rate_discount_requests pendiente (decisión #339: sólo
      -- root/reception_admin llegan hasta acá). sdd/per-room-rate-in-
      -- bulk: compara contra v_room_rate_bs (precio de ESTA habitación,
      -- ya resuelto arriba con su propio rate_bs o el fallback
      -- booking-level), NO contra el parámetro booking-level crudo --
      -- eso es justamente lo que aplanaba precios distintos de
      -- habitaciones distintas al mismo valor. p_reason sigue siendo el
      -- ÚNICO motivo para toda el alta (decisión de usuario): se graba
      -- tal cual en la auditoría de CADA habitación que difiera.
      if p_rate_mode <> 'person' and v_room_rate_bs <> v_rate then
        if p_reason is null or char_length(trim(p_reason)) = 0 then
          raise exception 'La justificación es obligatoria para cambiar la tarifa';
        end if;
        if v_room_rate_bs <= 0 then
          raise exception 'La tarifa debe ser un monto positivo';
        end if;
        if p_payer_mode = 'client' then
          perform public._apply_rate_change_direct(
            v_reservation_id, v_room_type_id, v_rate, v_nights, v_room_rate_bs, p_reason
          );
        else
          perform public.apply_rate_change(
            v_reservation_id, v_room_type_id, v_rate, v_nights, v_room_rate_bs, p_reason
          );
        end if;
      end if;

      v_created := v_created || to_jsonb(v_reservation_id::text);
    exception when others then
      -- Slice 2b -- atomicidad (feat/booking-12-contract-bulk-
      -- atomicity): una reserva institucional (payer_mode='client') es
      -- TODO O NADA. Relanzar la excepción ORIGINAL (mismo SQLSTATE,
      -- mismo mensaje) hace que aborte la sentencia completa que invocó
      -- a esta función, revirtiendo la booking, la cuenta por cobrar
      -- recién creada (si la hubo), las habitaciones ya creadas en
      -- vueltas anteriores de este mismo loop, sus
      -- people/guests/reservation_guests/stay_segments, y cualquier
      -- rate_overrides/rate_discount_requests/booking_balances de este
      -- intento. p_payer_mode ya está garantizado no-nulo acá (validado
      -- INCONDICIONALMENTE antes del loop). Para each_stay el
      -- comportamiento best-effort de siempre se mantiene SIN CAMBIOS.
      if p_payer_mode = 'client' then
        raise;
      end if;
      v_failed := v_failed || jsonb_build_object('room_id', v_room_id, 'error', sqlerrm);
    end;
  end loop;

  -- (f) contract_agreed: al final, sobre TODA la booking (una sola vez,
  -- sólo si se creó al menos una habitación). Suma directa sobre
  -- booking_id (no sobre v_created) -- las habitaciones fallidas nunca
  -- persisten (savepoint implícito del bloque exception), así que da el
  -- mismo resultado; misma forma que create_reservation
  -- (feat/booking-10), para no duplicar lógica entre ambos slices. Para
  -- 'client', llegar hasta acá implica que TODAS las habitaciones se
  -- crearon (ver nota de "edge caso" al comienzo del archivo) -- nunca
  -- hay un contract_agreed parcial para 'client' desde este slice.
  if p_payer_mode = 'client' and jsonb_array_length(v_created) > 0 then
    select coalesce(sum(total_amount_bs), 0) into v_contract_total
    from public.reservations where booking_id = v_booking_id;
    insert into public.booking_balances (booking_id, event_type, amount_bs, notes)
    values (v_booking_id, 'contract_agreed', v_contract_total, 'Contrato al crear el grupo');
  end if;

  return jsonb_build_object('created', v_created, 'failed', v_failed);
end;
$function$;
