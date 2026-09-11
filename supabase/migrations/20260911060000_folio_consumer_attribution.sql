-- =====================================================================
-- Atribución de extras/incidentales: quién los consumió y quién los
-- cargó. (change: reservation-booker-vs-guest, PR5, 8/8).
--
-- POR QUÉ
-- Hoy `folio_charges` no registra a QUIÉN se le cargó un consumo (spa,
-- restaurante, minibar) ni QUIÉN de recepción lo cargó. Con huéspedes
-- múltiples por habitación (reservation_guests) y titular/acompañantes
-- ya modelados (PR1-PR4), un cargo sin consumidor no se puede facturar
-- ni auditar por persona.
--
-- consumer_person_id es NULLABLE a nivel de tabla (las filas existentes
-- no se tocan), pero `add_folio_charge`/`add_folio_product_charge` -- las
-- únicas dos RPC que insertan en folio_charges para cargos de recepción --
-- lo EXIGEN de aquí en más: son las que la UI usa para atribuir el
-- consumo a un huésped concreto. `created_by` se completa solo
-- (default auth.uid()), igual que `occupancy_overrides.created_by`.
--
-- La regla "el consumidor debe estar alojado en esa estadía" NO puede
-- ser un CHECK (Postgres no permite subconsultas en CHECK) -- es un
-- BEFORE INSERT OR UPDATE trigger, mismo patrón que
-- reservation_guests_no_overlap (PR3) resolvió con EXCLUDE en vez de
-- CHECK por la misma razón de fondo.
-- =====================================================================

alter table public.folio_charges
  add column consumer_person_id uuid references public.people(id),
  add column created_by uuid references public.profiles(id) default auth.uid();

comment on column public.folio_charges.consumer_person_id is
  'Huésped que consumió el cargo. NULL en filas pre-existentes; obligatorio '
  'para cargos nuevos vía add_folio_charge/add_folio_product_charge, '
  'validado por el trigger folio_charges_consumer_is_occupant.';
comment on column public.folio_charges.created_by is
  'Usuario de recepción/caja que registró el cargo (auth.uid() al insertar).';

-- ---------------------------------------------------------------------
-- 1) Trigger: el consumidor debe ser un ocupante ACTIVO de la estadía
--    del folio (titular vía reservations.guest_id o acompañante vía
--    reservation_guests), y la estadía debe estar en curso.
-- ---------------------------------------------------------------------
create or replace function public.enforce_folio_charge_consumer_is_occupant()
returns trigger
language plpgsql
set search_path = public
as $function$
declare
  v_reservation_id uuid;
  v_status         text;
  v_is_occupant    boolean;
begin
  if new.consumer_person_id is null then
    return new;
  end if;

  select r.id, r.status into v_reservation_id, v_status
  from public.folios f
  join public.reservations r on r.id = f.reservation_id
  where f.id = new.folio_id;

  if v_reservation_id is null or v_status <> 'checked_in' then
    raise exception 'El huésped indicado no está alojado en esta habitación';
  end if;

  select exists (
    select 1 from public.reservations r2
    where r2.id = v_reservation_id and r2.guest_id = new.consumer_person_id
    union all
    select 1 from public.reservation_guests rg
    where rg.reservation_id = v_reservation_id and rg.person_id = new.consumer_person_id
  ) into v_is_occupant;

  if not v_is_occupant then
    raise exception 'El huésped indicado no está alojado en esta habitación';
  end if;

  return new;
end;
$function$;

revoke execute on function public.enforce_folio_charge_consumer_is_occupant() from public, anon;

drop trigger if exists folio_charges_consumer_is_occupant on public.folio_charges;
create trigger folio_charges_consumer_is_occupant
  before insert or update of consumer_person_id, folio_id on public.folio_charges
  for each row execute function public.enforce_folio_charge_consumer_is_occupant();

-- ---------------------------------------------------------------------
-- 2) add_folio_charge: arity change (uuid,text,numeric) ->
--    (uuid,text,numeric,uuid). El consumidor es obligatorio: sin él no
--    se sabe a quién se le cargó el consumo.
-- ---------------------------------------------------------------------
drop function if exists public.add_folio_charge(uuid, text, numeric);

create function public.add_folio_charge(
  p_room_id uuid, p_description text, p_amount numeric, p_consumer_person_id uuid
) returns uuid
language plpgsql security definer set search_path = public
as $function$
declare
  v_folio_id uuid;
  v_charge_id uuid;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin', 'accountant') then
    raise exception 'No autorizado para cargar consumos al folio';
  end if;

  if p_amount is null or p_amount < 0 then
    raise exception 'El monto debe ser mayor o igual a 0';
  end if;
  if nullif(trim(p_description), '') is null then
    raise exception 'La descripción es obligatoria';
  end if;
  if p_consumer_person_id is null then
    raise exception 'Debe indicar el huésped que consume este cargo';
  end if;

  select f.id into v_folio_id
  from public.folios f
  join public.reservations r on r.id = f.reservation_id
  where r.room_id = p_room_id and r.status = 'checked_in'
  order by r.check_in_date desc
  limit 1;

  if v_folio_id is null then
    raise exception 'No hay una estadía activa en esta habitación';
  end if;

  insert into public.folio_charges (folio_id, description, amount_bs, consumer_person_id)
  values (v_folio_id, trim(p_description), p_amount, p_consumer_person_id)
  returning id into v_charge_id;

  return v_charge_id;
end;
$function$;

revoke execute on function public.add_folio_charge(uuid, text, numeric, uuid) from public, anon;
grant execute on function public.add_folio_charge(uuid, text, numeric, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 3) add_folio_product_charge: mismo tratamiento, arity change
--    (uuid,uuid,numeric) -> (uuid,uuid,numeric,uuid).
-- ---------------------------------------------------------------------
drop function if exists public.add_folio_product_charge(uuid, uuid, numeric);

create function public.add_folio_product_charge(
  p_room_id uuid, p_product_id uuid, p_quantity numeric, p_consumer_person_id uuid
) returns uuid
language plpgsql security definer set search_path = public
as $function$
declare
  v_folio_id  uuid;
  v_stock     numeric;
  v_price     numeric;
  v_name      text;
  v_charge_id uuid;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin', 'accountant') then
    raise exception 'No autorizado para cargar consumos al folio';
  end if;

  if p_quantity is null or p_quantity <= 0 then
    raise exception 'La cantidad debe ser mayor a 0';
  end if;
  if p_consumer_person_id is null then
    raise exception 'Debe indicar el huésped que consume este cargo';
  end if;

  select f.id into v_folio_id
  from public.folios f
  join public.reservations r on r.id = f.reservation_id
  where r.room_id = p_room_id and r.status = 'checked_in'
  order by r.check_in_date desc
  limit 1;
  if v_folio_id is null then
    raise exception 'No hay una estadía activa en esta habitación';
  end if;

  -- Bloqueo del producto para evitar descuentos concurrentes erróneos.
  select current_stock, sale_price_bs, name
  into v_stock, v_price, v_name
  from public.products where id = p_product_id for update;
  if v_stock is null then
    raise exception 'Producto no encontrado';
  end if;
  if v_stock < p_quantity then
    raise exception 'Stock insuficiente de % (disponible: %)', v_name, v_stock;
  end if;

  update public.products
    set current_stock = current_stock - p_quantity
    where id = p_product_id;

  insert into public.folio_charges (folio_id, description, amount_bs, product_id, quantity, consumer_person_id)
  values (
    v_folio_id,
    v_name || ' x' || p_quantity,
    v_price * p_quantity,
    p_product_id,
    p_quantity,
    p_consumer_person_id
  ) returning id into v_charge_id;

  return v_charge_id;
end;
$function$;

revoke execute on function public.add_folio_product_charge(uuid, uuid, numeric, uuid) from public, anon;
grant execute on function public.add_folio_product_charge(uuid, uuid, numeric, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 4) add_guests_to_stay: el cargo por huésped adicional lo sigue
--    generando internamente (perform add_folio_charge), pero ahora debe
--    pasar un consumidor -- se atribuye al TITULAR de la estadía
--    (reservations.guest_id), porque es un cargo de habitación (no de un
--    acompañante puntual) y todo check-in ya exige titular (PR2b).
-- ---------------------------------------------------------------------
create or replace function public.add_guests_to_stay(
  p_room_id            uuid,
  p_companions         jsonb,
  p_extra_charge_bs    numeric default 0,
  p_charge_description text default null,
  p_occupancy_reason   text default null
) returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_companions jsonb := coalesce(p_companions, '[]'::jsonb);
  v_new        int   := jsonb_array_length(v_companions);
  v_reservation uuid;
  v_room_type   uuid;
  v_holder      uuid;
  v_max_occ     int;
  v_current     int;
  v_total       int;
  v_desc        text;
  v_names       text;
  v_reason      text;
begin
  if public.current_user_role() not in ('root', 'reception', 'reception_admin') then
    raise exception 'No autorizado para agregar huéspedes';
  end if;

  if v_new = 0 then
    raise exception 'No hay huéspedes para agregar';
  end if;

  if p_extra_charge_bs is null or p_extra_charge_bs < 0 then
    raise exception 'El incremento debe ser un monto mayor o igual a 0';
  end if;

  select r.id, r.room_type_id, r.guest_id into v_reservation, v_room_type, v_holder
  from public.reservations r
  where r.room_id = p_room_id and r.status = 'checked_in'
  order by r.check_in_date desc
  limit 1;

  if v_reservation is null then
    raise exception 'No hay una estadía activa en esta habitación';
  end if;

  select max_occupancy into v_max_occ
  from public.room_types where id = v_room_type;

  select count(*) into v_current
  from public.stay_guests where reservation_id = v_reservation;

  v_total := v_current + v_new;
  if v_max_occ is not null and v_total > v_max_occ then
    v_reason := nullif(trim(p_occupancy_reason), '');
    if v_reason is null then
      raise exception
        'La habitación admite % huésped(es); estás registrando %. Indique un motivo para exceder el límite.',
        v_max_occ, v_total;
    end if;
    insert into public.occupancy_overrides (
      reservation_id, max_occupancy, resulting_occupancy, reason
    ) values (v_reservation, v_max_occ, v_total, v_reason);
  end if;

  perform public.add_reservation_companions(v_reservation, v_companions);

  update public.reservations
    set num_guests = greatest(coalesce(num_guests, 0), v_total)
    where id = v_reservation;

  if p_extra_charge_bs > 0 then
    v_desc := nullif(trim(coalesce(p_charge_description, '')), '');
    if v_desc is null then
      select string_agg(
               trim(c->>'first_name') || ' ' || trim(c->>'last_name'), ', '
             )
      into v_names
      from jsonb_array_elements(v_companions) as t(c);
      v_desc := 'Huésped adicional: ' || coalesce(v_names, '');
    end if;
    perform public.add_folio_charge(p_room_id, v_desc, p_extra_charge_bs, v_holder);
  end if;

  return v_total;
end;
$$;

revoke execute on function public.add_guests_to_stay(uuid, jsonb, numeric, text, text) from public, anon;
grant execute on function public.add_guests_to_stay(uuid, jsonb, numeric, text, text) to authenticated;
