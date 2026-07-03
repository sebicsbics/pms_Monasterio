-- =====================================================================
-- MÓDULO INVENTARIO (bounded context propio).
-- Categorías, productos (con stock), y registro de ingresos (facturados o no).
-- =====================================================================

-- ---------- CATEGORÍAS ----------
create table if not exists public.product_categories (
  id   uuid primary key default gen_random_uuid(),
  name text not null unique
);

-- ---------- PRODUCTOS (catálogo con stock) ----------
create table if not exists public.products (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  category_id   uuid not null references public.product_categories(id),
  unit          text not null default 'unidad', -- unidad, litro, kg, caja...
  current_stock numeric(12,2) not null default 0 check (current_stock >= 0),
  min_stock     numeric(12,2) not null default 0 check (min_stock >= 0),
  created_at    timestamptz not null default now(),
  unique (name, category_id)
);
create index if not exists idx_products_category on public.products (category_id);

-- ---------- INGRESOS DE STOCK (la "factura" o detalle de compra) ----------
create table if not exists public.stock_entries (
  id             uuid primary key default gen_random_uuid(),
  entry_date     date not null default current_date,
  is_invoiced    boolean not null default false,
  invoice_number text,                 -- obligatorio solo si is_invoiced
  supplier       text,
  notes          text,
  created_at     timestamptz not null default now(),
  -- Si es facturado, el número de factura no puede faltar.
  constraint invoice_number_required
    check (not is_invoiced or nullif(trim(invoice_number), '') is not null)
);

-- ---------- RENGLONES DEL INGRESO ----------
create table if not exists public.stock_entry_items (
  id             uuid primary key default gen_random_uuid(),
  stock_entry_id uuid not null references public.stock_entries(id) on delete cascade,
  product_id     uuid not null references public.products(id),
  quantity       numeric(12,2) not null check (quantity > 0),
  unit_price_bs  numeric(12,2) not null check (unit_price_bs >= 0)
);

-- ---------- RLS ----------
alter table public.product_categories enable row level security;
alter table public.products           enable row level security;
alter table public.stock_entries      enable row level security;
alter table public.stock_entry_items  enable row level security;
create policy "dev_all_categories"  on public.product_categories for all using (true) with check (true);
create policy "dev_all_products"    on public.products           for all using (true) with check (true);
create policy "dev_all_entries"     on public.stock_entries      for all using (true) with check (true);
create policy "dev_all_entry_items" on public.stock_entry_items  for all using (true) with check (true);

-- ---------- Categorías iniciales ----------
insert into public.product_categories (name) values
  ('Limpieza'), ('Oficina'), ('Consumibles'), ('Comida'),
  ('Bebidas'), ('Bebidas con alcohol'), ('Azúcar')
on conflict (name) do nothing;

-- =====================================================================
-- FUNCIÓN: registrar un ingreso de stock (ATÓMICA).
-- Cabecera + renglones (jsonb) + incremento de stock, todo o nada.
-- items = [{"productId":"uuid","quantity":5,"unitPrice":12.5}, ...]
-- =====================================================================
create or replace function public.register_stock_entry(
  p_entry_date     date,
  p_is_invoiced    boolean,
  p_invoice_number text,
  p_supplier       text,
  p_notes          text,
  p_items          jsonb
) returns uuid
language plpgsql
as $$
declare
  v_entry_id   uuid;
  v_item       jsonb;
  v_product_id uuid;
  v_qty        numeric;
  v_price      numeric;
begin
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'El ingreso debe tener al menos un producto';
  end if;
  if p_is_invoiced and nullif(trim(p_invoice_number), '') is null then
    raise exception 'Si es facturado, el número de factura es obligatorio';
  end if;

  insert into public.stock_entries (entry_date, is_invoiced, invoice_number, supplier, notes)
  values (
    coalesce(p_entry_date, current_date),
    p_is_invoiced,
    case when p_is_invoiced then nullif(trim(p_invoice_number), '') else null end,
    nullif(trim(p_supplier), ''),
    nullif(trim(p_notes), '')
  ) returning id into v_entry_id;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_product_id := (v_item->>'productId')::uuid;
    v_qty        := (v_item->>'quantity')::numeric;
    v_price      := (v_item->>'unitPrice')::numeric;

    if v_qty is null or v_qty <= 0 then
      raise exception 'Cantidad inválida en un renglón';
    end if;
    if v_price is null or v_price < 0 then
      raise exception 'Precio inválido en un renglón';
    end if;

    insert into public.stock_entry_items (stock_entry_id, product_id, quantity, unit_price_bs)
    values (v_entry_id, v_product_id, v_qty, v_price);

    update public.products
      set current_stock = current_stock + v_qty
      where id = v_product_id;
    if not found then
      raise exception 'Producto no encontrado: %', v_product_id;
    end if;
  end loop;

  return v_entry_id;
end;
$$;

-- ---------- VISTA: productos bajo mínimo (qué reponer) ----------
create or replace view public.low_stock
with (security_invoker = on) as
select p.id, p.name, c.name as category, p.unit, p.current_stock, p.min_stock
from public.products p
join public.product_categories c on c.id = p.category_id
where p.current_stock <= p.min_stock;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant execute on function public.register_stock_entry(date,boolean,text,text,text,jsonb)
      to anon, authenticated;
    grant select on public.low_stock to anon, authenticated;
  end if;
end$$;
