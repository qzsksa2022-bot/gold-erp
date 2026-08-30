-- ============================================================================
-- 0120: Phase 5 — Shipping Core (8/9): narrow lookup RPCs (Section 38)
-- ============================================================================
-- Migrations 0001-0119 are unmodified. Same "narrow, permission-specific
-- lookup, never a Master-Data browse permission" style as returns_operable_
-- store_lookups()/returns_visible_store_lookups()/returns_refund_method_
-- lookups() (0105) and search_sales_orders_for_return()/get_returnable_
-- sales_order() (0112) — every RPC here is gated on the SPECIFIC Shipping
-- permission that actually needs it, never shipping_rates.view/stores.view/
-- sales.view, so a role holding only e.g. shipments.create can run the
-- entire /shipments/new flow without any Master-Data browse grant.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Store pickers — mirror returns_operable_store_lookups()/returns_visible_
-- store_lookups() exactly, gated on the Shipments-equivalent permissions.
-- ---------------------------------------------------------------------------
create or replace function public.shipments_operable_store_lookups()
returns table (id uuid, name_ar text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null or not public.has_permission('shipments.create') then
    raise exception 'ليست لديك صلاحية إنشاء شحنات' using errcode = 'P0001';
  end if;

  return query
  select st.id, st.name_ar
  from public.stores st
  where st.id in (select sid from public.user_operable_store_ids(v_actor) sid)
  order by st.name_ar;
end;
$$;

comment on function public.shipments_operable_store_lookups() is
  'Phase 5 (Section 38) — the OPERABLE-scope store picker for /shipments/new''s processing-store field. Gated on shipments.create, NEVER stores.view. Returns only {id, name_ar}. SECURITY DEFINER.';

revoke execute on function public.shipments_operable_store_lookups() from public;
grant execute on function public.shipments_operable_store_lookups() to authenticated;

create or replace function public.shipments_visible_store_lookups()
returns table (id uuid, name_ar text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null or not public.has_permission('shipments.view') then
    raise exception 'ليست لديك صلاحية عرض الشحنات' using errcode = 'P0001';
  end if;

  return query
  select st.id, st.name_ar
  from public.stores st
  where st.id in (select sid from public.user_visible_store_ids(v_actor) sid)
  order by st.name_ar;
end;
$$;

comment on function public.shipments_visible_store_lookups() is
  'Phase 5 (Section 38) — the VISIBLE-scope store picker for the /shipments list filters (including a store later disabled). Gated on shipments.view, NEVER stores.view. Returns only {id, name_ar}. SECURITY DEFINER.';

revoke execute on function public.shipments_visible_store_lookups() from public;
grant execute on function public.shipments_visible_store_lookups() to authenticated;

-- ---------------------------------------------------------------------------
-- Carrier/zone pickers — Section 38's real fix target: shipping_carriers/
-- shipping_zones RLS (0113) is gated on shipping_rates.view/.manage, which a
-- plain shipments.create-only role does NOT hold. Without a narrow lookup, a
-- shipments.create-only actor would hit the exact same silent-zero-rows trap
-- already fixed once for shipping_carrier_rate_for()/customer_return_
-- shipping_fee_for() (0114/0115) — direct .from("shipping_carriers") selects
-- from the frontend must never be used for the /shipments/new picker.
-- ---------------------------------------------------------------------------
create or replace function public.shipments_carrier_lookups()
returns table (id uuid, code text, name_ar text, carrier_type text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null or not public.has_permission('shipments.create') then
    raise exception 'ليست لديك صلاحية إنشاء شحنات' using errcode = 'P0001';
  end if;

  return query
  select c.id, c.code, c.name_ar, c.carrier_type
  from public.shipping_carriers c
  where c.status = 'active'
  order by c.name_ar;
end;
$$;

comment on function public.shipments_carrier_lookups() is
  'Phase 5 (Section 3/38) — active carrier picker for /shipments/new. Gated on shipments.create, NEVER shipping_rates.view. No carrier-name branching anywhere downstream — code/carrier_type are opaque data the UI renders, never switched on server-side. SECURITY DEFINER.';

revoke execute on function public.shipments_carrier_lookups() from public;
grant execute on function public.shipments_carrier_lookups() to authenticated;

create or replace function public.shipments_zone_lookups()
returns table (id uuid, code text, name_ar text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null or not public.has_permission('shipments.create') then
    raise exception 'ليست لديك صلاحية إنشاء شحنات' using errcode = 'P0001';
  end if;

  return query
  select z.id, z.code, z.name_ar
  from public.shipping_zones z
  where z.status = 'active'
  order by z.name_ar;
end;
$$;

comment on function public.shipments_zone_lookups() is
  'Phase 5 (Section 5/38) — active shipping-zone picker for /shipments/new. Gated on shipments.create, NEVER shipping_rates.view. SECURITY DEFINER.';

revoke execute on function public.shipments_zone_lookups() from public;
grant execute on function public.shipments_zone_lookups() to authenticated;

-- ---------------------------------------------------------------------------
-- search_sales_orders_for_shipment() — the Sale-search step of /shipments/
-- new, same narrow shape as search_sales_orders_for_return() (0112). Gated
-- on shipments.create ONLY, never sales.view.
-- ---------------------------------------------------------------------------
create or replace function public.search_sales_orders_for_shipment(
  p_order_number text default null,
  p_limit integer default 10
)
returns table (
  id uuid,
  order_number text,
  sale_date date,
  store_id uuid,
  store_name text,
  customer_name text,
  customer_phone text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_limit integer := least(greatest(coalesce(p_limit, 10), 1), 50);
  v_trimmed text := nullif(btrim(coalesce(p_order_number, '')), '');
begin
  if v_actor is null or not public.has_permission('shipments.create') then
    raise exception 'ليست لديك صلاحية إنشاء شحنات' using errcode = 'P0001';
  end if;

  if v_trimmed is null then
    return;
  end if;

  return query
  select so.id, so.order_number, so.sale_date, so.store_id, st.name_ar, so.customer_name, so.customer_phone
  from public.sales_orders so
  left join public.stores st on st.id = so.store_id
  where so.store_id in (select sid from public.user_visible_store_ids(v_actor) sid)
    and so.order_number ilike '%' || v_trimmed || '%'
  order by so.sale_date desc, so.order_number desc
  limit v_limit;
end;
$$;

comment on function public.search_sales_orders_for_shipment(text, integer) is
  'Phase 5 (Section 38) — the Sale-search lookup for /shipments/new (outbound shipments), same narrow shape as search_sales_orders_for_return() (0112). Gated on shipments.create ONLY, scoped by user_visible_store_ids(). No profit fields, no other sales_orders column, no route into the Sales module. SECURITY DEFINER.';

revoke execute on function public.search_sales_orders_for_shipment(text, integer) from public;
grant execute on function public.search_sales_orders_for_shipment(text, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- search_sales_returns_for_shipment() — the Return-search step of
-- /shipments/new (return shipments). Only approved/reversed returns are
-- eligible (mirrors create_shipment()'s own validation, 0117) — a Pending
-- or Rejected return can never be attached to a return shipment.
-- ---------------------------------------------------------------------------
create or replace function public.search_sales_returns_for_shipment(
  p_return_number text default null,
  p_sales_order_id uuid default null,
  p_limit integer default 10
)
returns table (
  id uuid,
  return_number text,
  return_date date,
  status text,
  sales_order_id uuid,
  order_number text,
  processed_store_id uuid,
  store_name text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_limit integer := least(greatest(coalesce(p_limit, 10), 1), 50);
  v_trimmed text := nullif(btrim(coalesce(p_return_number, '')), '');
begin
  if v_actor is null or not public.has_permission('shipments.create') then
    raise exception 'ليست لديك صلاحية إنشاء شحنات' using errcode = 'P0001';
  end if;

  if v_trimmed is null and p_sales_order_id is null then
    return;
  end if;

  return query
  select sr.id, sr.return_number, sr.return_date, sr.status, sr.sales_order_id, so.order_number, sr.processed_store_id, st.name_ar
  from public.sales_returns sr
  join public.sales_orders so on so.id = sr.sales_order_id
  left join public.stores st on st.id = sr.processed_store_id
  where sr.processed_store_id in (select sid from public.user_visible_store_ids(v_actor) sid)
    and sr.status in ('approved', 'reversed')
    and (v_trimmed is null or sr.return_number ilike '%' || v_trimmed || '%')
    and (p_sales_order_id is null or sr.sales_order_id = p_sales_order_id)
  order by sr.return_date desc, sr.return_number desc
  limit v_limit;
end;
$$;

comment on function public.search_sales_returns_for_shipment(text, uuid, integer) is
  'Phase 5 (Section 38) — the Return-search lookup for /shipments/new (return shipments). Only status IN (approved, reversed) — matches create_shipment()''s (0117) own eligibility check exactly, so nothing surfaced here can ever fail at submission for status reasons. Gated on shipments.create ONLY, scoped by user_visible_store_ids(). SECURITY DEFINER.';

revoke execute on function public.search_sales_returns_for_shipment(text, uuid, integer) from public;
grant execute on function public.search_sales_returns_for_shipment(text, uuid, integer) to authenticated;
