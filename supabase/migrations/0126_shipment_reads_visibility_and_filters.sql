-- ============================================================================
-- 0126: Shipping Integrity Patch 5.1 (5/10): customer_shipping_charge is NOT
-- profit-secret, has_actual_carrier_cost operational flag, real filter
-- lookups for viewer-only actors, expanded list_shipments() filters
-- ============================================================================
-- Migrations 0001-0125 are unmodified.
--
-- Item 10 — the ORIGINAL Phase 5 spec (Section 26) was explicit that a
-- shipments.view-only actor (no sales.view_profit) sees the customer
-- shipping charge — only carrier COST/net-shipping-profit figures are
-- hidden. get_shipment()/list_shipments() (0119) instead folded customer_
-- shipping_charge/effective_customer_shipping_charge into the SAME
-- profit-gated bundle as expected/actual carrier cost — a real regression
-- against the spec. Fixed here: customer_shipping_charge, effective_
-- customer_shipping_charge, and the Customer Return Shipping Fee snapshot
-- fields (0125 — themselves customer-facing revenue data, never a carrier
-- cost) all move to the ALWAYS-visible base object/columns. Still gated
-- behind sales.view_profit: carrier_rate_version_id, expected_carrier_cost
-- (+is_manual/+reason), actual_carrier_cost, net_shipping_expected, net_
-- shipping_actual, cod_expected_amount, and the full financial_events
-- ledger (every one of these is either a real Carrier Cost or a derived
-- Shipping Profit figure).
--
-- Item 23 — a shipments.manage_cost actor without sales.view_profit
-- previously had no way to tell "no actual cost recorded yet" (call
-- record_shipment_actual_cost) from "an actual cost already exists but I
-- can''t see it" (call correct_shipment_actual_cost instead) — both looked
-- identical (actual_carrier_cost simply absent). Fixed with a new
-- ALWAYS-visible has_actual_carrier_cost boolean — an operational fact
-- (does a record exist), never the amount itself.
--
-- Item 11 — /shipments only ever had shipments_carrier_lookups()/
-- shipments_zone_lookups() (0120), both gated on shipments.create — so a
-- shipments.view-only actor (e.g. accountant role, Section 25) could read
-- list_shipments() over the RPC directly but the /shipments PAGE itself
-- failed loading its own filters (a real permission/UX bug — see the
-- src/app/(app)/shipments/page.tsx fix in this same delivery). Fixed with
-- two new VIEW-scoped lookups (shipments_filter_carrier_lookups()/
-- shipments_filter_zone_lookups()), gated on shipments.view, that also
-- surface a disabled carrier/zone if a VISIBLE historical shipment still
-- references it (so the actor can filter their history even after Master
-- Data is later disabled) — the existing shipments_carrier_lookups()/
-- shipments_zone_lookups() (active-only, shipments.create-gated) are left
-- completely untouched for /shipments/new.
--
-- Item 12 — list_shipments() never exposed order_number/return_number as
-- TEXT search filters (only exact sales_order_id/sales_return_id uuid
-- matches), never distinguished the PROCESSING store (shipments.store_id,
-- already p_store_id) from the ORIGINAL SALE''s store (sales_orders.
-- store_id — can differ, e.g. a return shipment processed at a different
-- branch than the original sale), and had no cod_collection_state filter.
-- All four added here.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- PART A — get_shipment().
-- ---------------------------------------------------------------------------
create or replace function public.get_shipment(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_shipment record;
  v_can_view_profit boolean;
  v_order_number text;
  v_return_number text;
  v_store_name text;
  v_original_sale_store_id uuid;
  v_original_sale_store_name text;
  v_carrier_code text;
  v_carrier_name text;
  v_zone_code text;
  v_zone_name text;
  v_status_timeline jsonb;
  v_financial_events jsonb;
  v_effective_charge numeric;
  v_has_actual_cost boolean;
begin
  if v_actor is null or not public.has_permission('shipments.view') then
    raise exception 'ليست لديك صلاحية عرض الشحنات' using errcode = 'P0001';
  end if;

  select s.* into v_shipment from public.shipments s where s.id = p_id;

  if v_shipment.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_shipment.store_id) then
    raise exception 'الشحنة غير موجودة أو غير متاحة لك' using errcode = 'P0001';
  end if;

  v_can_view_profit := public.has_permission('sales.view_profit');
  v_has_actual_cost := v_shipment.actual_carrier_cost is not null;

  select so.order_number, so.store_id into v_order_number, v_original_sale_store_id from public.sales_orders so where so.id = v_shipment.sales_order_id;
  select sr.return_number into v_return_number from public.sales_returns sr where sr.id = v_shipment.sales_return_id;
  select st.name_ar into v_store_name from public.stores st where st.id = v_shipment.store_id;
  select st.name_ar into v_original_sale_store_name from public.stores st where st.id = v_original_sale_store_id;
  select c.code, c.name_ar into v_carrier_code, v_carrier_name from public.shipping_carriers c where c.id = v_shipment.carrier_id;
  select z.code, z.name_ar into v_zone_code, v_zone_name from public.shipping_zones z where z.id = v_shipment.shipping_zone_id;

  -- Append-only status timeline (Section 13) — never profit-sensitive.
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', e.id, 'status', e.status, 'event_business_date', e.event_business_date, 'event_at', e.event_at,
      'notes', e.notes, 'is_correction', e.is_correction, 'external_reference', e.external_reference,
      'actor', e.actor, 'created_at', e.created_at
    )
    order by e.created_at
  ), '[]'::jsonb) into v_status_timeline
  from public.shipment_status_events e
  where e.shipment_id = v_shipment.id;

  -- Item 10 — effective_customer_shipping_charge is ALWAYS computed
  -- (needed for the always-visible base object below), regardless of
  -- sales.view_profit — only the financial_events LEDGER itself (the full
  -- correction history, which also includes actual-cost entries) stays
  -- profit-gated.
  select fe.amount into v_effective_charge
  from public.shipment_financial_events fe
  where fe.shipment_id = v_shipment.id and fe.event_type = 'customer_charge_correction'
  order by fe.created_at desc limit 1;

  v_effective_charge := coalesce(v_effective_charge, v_shipment.customer_shipping_charge);

  if v_can_view_profit then
    -- Append-only financial correction ledger (Section 19/20/33) — the
    -- FULL history (record + every correction), oldest first.
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'id', fe.id, 'event_type', fe.event_type, 'amount', fe.amount::text, 'business_date', fe.business_date,
        'reference', fe.reference, 'reason', fe.reason, 'actor', fe.actor, 'created_at', fe.created_at
      )
      order by fe.created_at
    ), '[]'::jsonb) into v_financial_events
    from public.shipment_financial_events fe
    where fe.shipment_id = v_shipment.id;
  end if;

  return jsonb_build_object(
    'id', v_shipment.id, 'shipment_number', v_shipment.shipment_number,
    'sales_order_id', v_shipment.sales_order_id, 'order_number', v_order_number,
    'sales_return_id', v_shipment.sales_return_id, 'return_number', v_return_number,
    'store_id', v_shipment.store_id, 'store_name', v_store_name,
    'original_sale_store_id', v_original_sale_store_id, 'original_sale_store_name', v_original_sale_store_name,
    'carrier_id', v_shipment.carrier_id, 'carrier_code', v_carrier_code, 'carrier_name', v_carrier_name,
    'shipping_zone_id', v_shipment.shipping_zone_id, 'zone_code', v_zone_code, 'zone_name', v_zone_name,
    'direction', v_shipment.direction, 'fulfillment_type', v_shipment.fulfillment_type,
    'tracking_number', v_shipment.tracking_number, 'external_reference', v_shipment.external_reference,
    'customer_name', v_shipment.customer_name_snapshot, 'customer_phone', v_shipment.customer_phone_snapshot,
    'recipient_address', v_shipment.recipient_address_snapshot, 'shipment_date', v_shipment.shipment_date,
    'is_cod', v_shipment.is_cod, 'cod_collection_state', v_shipment.cod_collection_state,
    'current_status', v_shipment.current_status, 'notes', v_shipment.notes,
    'row_version', v_shipment.row_version,
    'created_by', v_shipment.created_by, 'updated_by', v_shipment.updated_by,
    'created_at', v_shipment.created_at, 'updated_at', v_shipment.updated_at,
    'status_timeline', v_status_timeline,
    -- Item 10 — customer-facing money, NEVER profit-gated (spec Section 26).
    'customer_shipping_charge', v_shipment.customer_shipping_charge::text,
    'effective_customer_shipping_charge', v_effective_charge::text,
    -- Item 8/9 — Customer Return Shipping Fee snapshot (0125): same class
    -- of customer-facing revenue data as customer_shipping_charge itself,
    -- never a carrier cost — kept ungated for the same reason.
    'customer_return_shipping_fee_version_id', v_shipment.customer_return_shipping_fee_version_id,
    'customer_return_shipping_fee_standard_amount', v_shipment.customer_return_shipping_fee_standard_amount::text,
    'customer_return_shipping_charge_is_override', v_shipment.customer_return_shipping_charge_is_override,
    'customer_return_shipping_charge_override_reason', v_shipment.customer_return_shipping_charge_override_reason,
    -- Item 23 — operational fact only (does a recorded actual cost exist),
    -- never the amount — safe without sales.view_profit so the UI can
    -- decide "Record first cost" vs "Correct existing cost".
    'has_actual_carrier_cost', v_has_actual_cost
  )
  || case when v_can_view_profit then jsonb_build_object(
    'carrier_rate_version_id', v_shipment.carrier_rate_version_id,
    'expected_carrier_cost', v_shipment.expected_carrier_cost::text,
    'expected_carrier_cost_is_manual', v_shipment.expected_carrier_cost_is_manual,
    'expected_carrier_cost_manual_reason', v_shipment.expected_carrier_cost_manual_reason,
    'actual_carrier_cost', v_shipment.actual_carrier_cost::text,
    'net_shipping_expected', v_shipment.net_shipping_expected::text,
    'net_shipping_actual', v_shipment.net_shipping_actual::text,
    'cod_expected_amount', v_shipment.cod_expected_amount::text,
    'financial_events', v_financial_events
  ) else '{}'::jsonb end;
end;
$$;

comment on function public.get_shipment(uuid) is
  'Phase 5 (Section 37), corrected by Patch 5.1 (0126): customer_shipping_charge/effective_customer_shipping_charge and the Customer Return Shipping Fee snapshot (0125) are ALWAYS present (spec Section 26 — never profit-secret); has_actual_carrier_cost is an always-visible operational boolean (item 23). Still gated behind sales.view_profit: carrier_rate_version_id, expected/actual_carrier_cost, net_shipping_expected/actual, cod_expected_amount, and the full financial_events ledger. Scoped via user_visible_store_ids(). SECURITY DEFINER.';

revoke execute on function public.get_shipment(uuid) from public;
grant execute on function public.get_shipment(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- PART B — list_shipments(), new signature (DROP + CREATE — project
-- convention when a column list/param list changes materially).
-- ---------------------------------------------------------------------------
drop function if exists public.list_shipments(date, date, uuid, uuid, uuid, text, text, text, text, uuid, uuid, integer, integer);

create or replace function public.list_shipments(
  p_date_from date default null,
  p_date_to date default null,
  p_store_id uuid default null,
  p_carrier_id uuid default null,
  p_shipping_zone_id uuid default null,
  p_direction text default null,
  p_current_status text default null,
  p_shipment_number text default null,
  p_tracking_number text default null,
  p_sales_order_id uuid default null,
  p_sales_return_id uuid default null,
  p_limit integer default 50,
  p_offset integer default 0,
  -- Item 12 — new filters.
  p_order_number text default null,
  p_return_number text default null,
  p_original_sale_store_id uuid default null,
  p_cod_collection_state text default null
)
returns table (
  id uuid,
  shipment_number text,
  sales_order_id uuid,
  order_number text,
  sales_return_id uuid,
  return_number text,
  store_id uuid,
  store_name text,
  original_sale_store_id uuid,
  original_sale_store_name text,
  carrier_id uuid,
  carrier_code text,
  carrier_name text,
  shipping_zone_id uuid,
  zone_code text,
  zone_name text,
  direction text,
  fulfillment_type text,
  tracking_number text,
  customer_name text,
  customer_phone text,
  shipment_date date,
  is_cod boolean,
  cod_collection_state text,
  current_status text,
  row_version bigint,
  customer_shipping_charge text,
  customer_return_shipping_charge_is_override boolean,
  has_actual_carrier_cost boolean,
  expected_carrier_cost text,
  expected_carrier_cost_is_manual boolean,
  actual_carrier_cost text,
  net_shipping_expected text,
  net_shipping_actual text,
  created_at timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_can_view_profit boolean;
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  if v_actor is null or not public.has_permission('shipments.view') then
    raise exception 'ليست لديك صلاحية عرض الشحنات' using errcode = 'P0001';
  end if;

  v_can_view_profit := public.has_permission('sales.view_profit');

  return query
  select
    s.id, s.shipment_number,
    s.sales_order_id, so.order_number,
    s.sales_return_id, sr.return_number,
    s.store_id, st.name_ar,
    so.store_id, ost.name_ar,
    s.carrier_id, c.code, c.name_ar,
    s.shipping_zone_id, z.code, z.name_ar,
    s.direction, s.fulfillment_type,
    s.tracking_number,
    s.customer_name_snapshot, s.customer_phone_snapshot,
    s.shipment_date, s.is_cod, s.cod_collection_state, s.current_status, s.row_version,
    -- Item 10 — customer-facing money, NEVER profit-gated.
    s.customer_shipping_charge::text,
    s.customer_return_shipping_charge_is_override,
    -- Item 23 — operational fact, NEVER profit-gated.
    (s.actual_carrier_cost is not null),
    case when v_can_view_profit then s.expected_carrier_cost::text else null end,
    case when v_can_view_profit then s.expected_carrier_cost_is_manual else null end,
    case when v_can_view_profit then s.actual_carrier_cost::text else null end,
    case when v_can_view_profit then s.net_shipping_expected::text else null end,
    case when v_can_view_profit then s.net_shipping_actual::text else null end,
    s.created_at,
    count(*) over ()::bigint
  from public.shipments s
  join public.sales_orders so on so.id = s.sales_order_id
  left join public.sales_returns sr on sr.id = s.sales_return_id
  left join public.stores st on st.id = s.store_id
  left join public.stores ost on ost.id = so.store_id
  left join public.shipping_carriers c on c.id = s.carrier_id
  left join public.shipping_zones z on z.id = s.shipping_zone_id
  where s.store_id in (select sid from public.user_visible_store_ids(v_actor) sid)
    and (p_date_from is null or s.shipment_date >= p_date_from)
    and (p_date_to is null or s.shipment_date <= p_date_to)
    and (p_store_id is null or s.store_id = p_store_id)
    and (p_carrier_id is null or s.carrier_id = p_carrier_id)
    and (p_shipping_zone_id is null or s.shipping_zone_id = p_shipping_zone_id)
    and (p_direction is null or s.direction = p_direction)
    and (p_current_status is null or s.current_status = p_current_status)
    and (p_shipment_number is null or s.shipment_number ilike '%' || p_shipment_number || '%')
    and (p_tracking_number is null or s.tracking_number ilike '%' || p_tracking_number || '%')
    and (p_sales_order_id is null or s.sales_order_id = p_sales_order_id)
    and (p_sales_return_id is null or s.sales_return_id = p_sales_return_id)
    and (p_order_number is null or so.order_number ilike '%' || p_order_number || '%')
    and (p_return_number is null or sr.return_number ilike '%' || p_return_number || '%')
    and (p_original_sale_store_id is null or so.store_id = p_original_sale_store_id)
    and (p_cod_collection_state is null or s.cod_collection_state = p_cod_collection_state)
  order by s.shipment_date desc, s.created_at desc
  limit v_limit offset v_offset;
end;
$$;

comment on function public.list_shipments(date, date, uuid, uuid, uuid, text, text, text, text, uuid, uuid, integer, integer, text, text, uuid, text) is
  'Phase 5 (Section 37/39), extended by Patch 5.1 (0126): customer_shipping_charge and has_actual_carrier_cost are ALWAYS returned (items 10/23 — never profit-gated); expected/actual_carrier_cost/net_shipping_* remain SQL NULL without sales.view_profit. New filters (item 12): p_order_number/p_return_number (text search), p_original_sale_store_id (the ORIGINAL Sale''s store, distinct from p_store_id which is the PROCESSING store), p_cod_collection_state. Scoped via user_visible_store_ids(). SECURITY DEFINER.';

revoke execute on function public.list_shipments(date, date, uuid, uuid, uuid, text, text, text, text, uuid, uuid, integer, integer, text, text, uuid, text) from public;
grant execute on function public.list_shipments(date, date, uuid, uuid, uuid, text, text, text, text, uuid, uuid, integer, integer, text, text, uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- PART C — item 11: VIEW-scoped filter lookups (never shipments.create,
-- never shipping_rates.view). Includes a disabled carrier/zone if a
-- VISIBLE historical shipment still references it, so /shipments'' own
-- filters can always express a value that actually appears in the list.
-- ---------------------------------------------------------------------------
create or replace function public.shipments_filter_carrier_lookups()
returns table (id uuid, code text, name_ar text, carrier_type text, status text)
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
  select distinct c.id, c.code, c.name_ar, c.carrier_type, c.status
  from public.shipping_carriers c
  where c.status = 'active'
     or exists (
       select 1 from public.shipments s
       where s.carrier_id = c.id and s.store_id in (select sid from public.user_visible_store_ids(v_actor) sid)
     )
  order by c.name_ar;
end;
$$;

comment on function public.shipments_filter_carrier_lookups() is
  'Patch 5.1 item 11 — the /shipments list filter''s carrier picker. Gated on shipments.view ONLY (never shipments.create, never shipping_rates.view) — closes the bug where a shipments.view-only actor could not even load the /shipments page (it called the .create-gated shipments_carrier_lookups(), 0120). Includes a disabled carrier only if a VISIBLE historical shipment still references it, so a filter value that appears in the actual list is always selectable. SECURITY DEFINER.';

revoke execute on function public.shipments_filter_carrier_lookups() from public;
grant execute on function public.shipments_filter_carrier_lookups() to authenticated;

create or replace function public.shipments_filter_zone_lookups()
returns table (id uuid, code text, name_ar text, status text)
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
  select distinct z.id, z.code, z.name_ar, z.status
  from public.shipping_zones z
  where z.status = 'active'
     or exists (
       select 1 from public.shipments s
       where s.shipping_zone_id = z.id and s.store_id in (select sid from public.user_visible_store_ids(v_actor) sid)
     )
  order by z.name_ar;
end;
$$;

comment on function public.shipments_filter_zone_lookups() is
  'Patch 5.1 item 11 — the /shipments list filter''s zone picker. Mirrors shipments_filter_carrier_lookups() exactly. Gated on shipments.view ONLY. SECURITY DEFINER.';

revoke execute on function public.shipments_filter_zone_lookups() from public;
grant execute on function public.shipments_filter_zone_lookups() to authenticated;
