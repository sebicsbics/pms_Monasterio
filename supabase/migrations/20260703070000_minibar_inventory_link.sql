-- =====================================================================
-- Conexión Minibar <-> Inventario.
-- Cargar un producto al folio descuenta stock y cobra el precio de VENTA.
-- =====================================================================

-- Precio de venta al huésped (distinto del costo de compra).
-- Solo los productos con precio de venta > 0 se consideran "vendibles".
alter table public.products
  add column if not exists sale_price_bs numeric(12,2) not null default 0
  check (sale_price_bs >= 0);

-- Trazabilidad: qué producto y cuánto generó un consumo del folio.
alter table public.folio_charges
  add column if not exists product_id uuid references public.products(id);
alter table public.folio_charges
  add column if not exists quantity numeric(12,2);

-- =====================================================================
-- FUNCIÓN: cargar consumo de un producto al folio (ATÓMICA).
-- Valida estadía activa, valida y descuenta stock, cobra precio de venta.
-- =====================================================================
create or replace function public.add_folio_product_charge(
  p_room_id    uuid,
  p_product_id uuid,
  p_quantity   numeric
) returns uuid
language plpgsql
as $$
declare
  v_folio_id  uuid;
  v_stock     numeric;
  v_price     numeric;
  v_name      text;
  v_charge_id uuid;
begin
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'La cantidad debe ser mayor a 0';
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

  insert into public.folio_charges (folio_id, description, amount_bs, product_id, quantity)
  values (
    v_folio_id,
    v_name || ' x' || p_quantity,
    v_price * p_quantity,
    p_product_id,
    p_quantity
  ) returning id into v_charge_id;

  return v_charge_id;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant execute on function public.add_folio_product_charge(uuid,uuid,numeric)
      to anon, authenticated;
  end if;
end$$;
