-- CHEF DANNY V3 — Supabase
-- Ejecuta este archivo completo en Supabase > SQL Editor.
create extension if not exists pgcrypto;

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  category text not null default 'General',
  name text not null,
  description text default '',
  price numeric(12,2) not null check(price >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.tables (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number bigint generated always as identity unique,
  public_token uuid not null default gen_random_uuid() unique,
  customer_name text not null,
  customer_phone text default '',
  order_type text not null default 'Para llevar',
  table_name text default '',
  address text default '',
  notes text default '',
  total numeric(12,2) not null default 0,
  order_status text not null default 'Pendiente' check(order_status in ('Pendiente','En preparación','Listo','Entregado','Cancelado')),
  invoice_status text not null default 'Pendiente' check(invoice_status in ('Pendiente','Pagada','Cancelada')),
  payment_method text not null default 'Pendiente',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_name text not null,
  unit_price numeric(12,2) not null check(unit_price >= 0),
  qty integer not null check(qty > 0)
);

insert into public.products(category,name,description,price) values
('Pinchos','Pincho de pollo','Pincho de pollo a la parrilla',3.50),
('Pinchos','Pincho de carne','Pincho de carne a la parrilla',3.50),
('Pinchos','Pincho de cerdo','Pincho de cerdo a la parrilla',3.50),
('Pinchos','Pincho mixto','Combinación de carnes',5.00),
('Pinchos','Pincho de 1 metro','Mixto: pollo, carne, cerdo, camarón y chorizo',15.00)
on conflict do nothing;

insert into public.tables(name) values ('Mesa 1'),('Mesa 2'),('Mesa 3'),('Mesa 4'),('Mesa 5'),('Mesa 6'),('Mesa 7'),('Mesa 8'),('Mesa 9'),('Mesa 10') on conflict do nothing;

alter table public.products enable row level security;
alter table public.tables enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;

-- Menú público: solo productos activos.
drop policy if exists "public read active products" on public.products;
create policy "public read active products" on public.products for select to anon,authenticated using (active=true or auth.role()='authenticated');

-- Mesas públicas para seleccionar mesa.
drop policy if exists "public read active tables" on public.tables;
create policy "public read active tables" on public.tables for select to anon,authenticated using (active=true or auth.role()='authenticated');

-- Administradores autenticados pueden administrar productos, mesas y pedidos.
drop policy if exists "admins manage products" on public.products;
create policy "admins manage products" on public.products for all to authenticated using (true) with check (true);
drop policy if exists "admins manage tables" on public.tables;
create policy "admins manage tables" on public.tables for all to authenticated using (true) with check (true);
drop policy if exists "admins read orders" on public.orders;
create policy "admins read orders" on public.orders for select to authenticated using (true);
drop policy if exists "admins update orders" on public.orders;
create policy "admins update orders" on public.orders for update to authenticated using (true) with check (true);
drop policy if exists "admins read order items" on public.order_items;
create policy "admins read order items" on public.order_items for select to authenticated using (true);

-- Crear pedido desde el menú público. Los precios se toman de la base de datos, no del celular.
create or replace function public.create_order(
  p_customer_name text,
  p_customer_phone text,
  p_order_type text,
  p_table_name text,
  p_address text,
  p_notes text,
  p_items jsonb
) returns jsonb
language plpgsql security definer set search_path=public
as $$
declare
  v_order_id uuid; v_token uuid; v_total numeric(12,2); v_item jsonb; v_product products%rowtype; v_qty int;
begin
  if coalesce(trim(p_customer_name),'')='' then raise exception 'El nombre es obligatorio'; end if;
  insert into orders(customer_name,customer_phone,order_type,table_name,address,notes)
  values(p_customer_name,coalesce(p_customer_phone,''),coalesce(p_order_type,'Para llevar'),coalesce(p_table_name,''),coalesce(p_address,''),coalesce(p_notes,''))
  returning id,public_token into v_order_id,v_token;

  v_total:=0;
  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty:=greatest(1,(v_item->>'qty')::int);
    select * into v_product from products where id=(v_item->>'product_id')::uuid and active=true;
    if not found then raise exception 'Producto no disponible'; end if;
    insert into order_items(order_id,product_id,product_name,unit_price,qty) values(v_order_id,v_product.id,v_product.name,v_product.price,v_qty);
    v_total:=v_total+(v_product.price*v_qty);
  end loop;
  update orders set total=v_total,updated_at=now() where id=v_order_id;
  return jsonb_build_object('id',v_order_id,'order_number',(select order_number from orders where id=v_order_id),'public_token',v_token,'total',v_total);
end $$;

-- Vista pública de una cuenta usando token secreto; no expone todas las órdenes.
create or replace function public.get_public_order(p_token uuid) returns jsonb
language sql security definer set search_path=public
as $$
select jsonb_build_object(
 'id',o.id,'order_number',o.order_number,'public_token',o.public_token,'customer_name',o.customer_name,
 'order_type',o.order_type,'table_name',o.table_name,'total',o.total,'invoice_status',o.invoice_status,
 'order_status',o.order_status,'created_at',o.created_at,
 'items',coalesce((select jsonb_agg(jsonb_build_object('product_name',i.product_name,'unit_price',i.unit_price,'qty',i.qty) order by i.id) from order_items i where i.order_id=o.id),'[]'::jsonb)
) from orders o where o.public_token=p_token;
$$;

create or replace function public.set_order_status(p_order_id uuid,p_status text) returns void
language plpgsql security definer set search_path=public as $$
begin
 if auth.role() <> 'authenticated' then raise exception 'No autorizado'; end if;
 if p_status not in ('Pendiente','En preparación','Listo','Entregado','Cancelado') then raise exception 'Estado inválido'; end if;
 update orders set order_status=p_status,updated_at=now() where id=p_order_id;
end $$;

create or replace function public.set_invoice_status(p_order_id uuid,p_status text) returns void
language plpgsql security definer set search_path=public as $$
begin
 if auth.role() <> 'authenticated' then raise exception 'No autorizado'; end if;
 if p_status not in ('Pendiente','Pagada','Cancelada') then raise exception 'Estado inválido'; end if;
 update orders set invoice_status=p_status,updated_at=now() where id=p_order_id;
end $$;

grant execute on function public.create_order(text,text,text,text,text,text,jsonb) to anon,authenticated;
grant execute on function public.get_public_order(uuid) to anon,authenticated;
grant execute on function public.set_order_status(uuid,text) to authenticated;
grant execute on function public.set_invoice_status(uuid,text) to authenticated;

do $$ begin
  alter publication supabase_realtime add table public.orders;
exception when duplicate_object then null; end $$;
