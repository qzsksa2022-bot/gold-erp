-- ============================================================================
-- 0119: Phase 5 — Shipping Core (7/9): get_shipment(), list_shipments()
-- ============================================================================
-- Migrations 0001-0118 are unmodified. Same access model/profit-redaction
-- shape as get_sales_return()/list_sales_returns() (0111) — gated on
-- shipments.view, scoped via user_visible_store_ids(), every profit-
-- sensitive money field entirely ABSENT from the jsonb (get_shipment) or
-- returned as SQL NULL (list_shipments) unless the actor also holds
-- sales.view_profit. Money always returned as ::text (Section 31 — decimal-
-- safe transport, Decimal.js on the frontend, never Number()/parseFloat()).
--
-- Profit-sensitive fields (Section 30/32 — Shipping Profit, kept entirely
-- separate from Sales Profit, but STILL gated behind the SAME sales.
-- view_profit permission per Section 26's explicit instruction "DB-level
-- Profit Privacy via sales.view_profit"): customer_shipping_charge,
-- expected_carrier_cost(+is_manual/+reason), carrier_rate_version_id,
-- actual_carrier_cost, net_shipping_expected, net_shipping_actual, and the
-- entire financial_events correction ledger. Never gated: shipment_number,
-- carrier/zone identity, status timeline, tracking/COD-state fields (COD
-- amounts ARE money and so ARE gated — see below).
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
  v_carrier_code text;
  v_carrier_name text;
  v_zone_code text;
  v_zone_name text;
  v_status_timeline jsonb;
  v_financial_events jsonb;
  v_effective_charge numeric;
begin
  if v_actor is null or not public.has_permission('shipments.view') then
    raise exception 'ليست لديك صلاحية عرض الشحنات' using errcode = 'P0001';
  end if;

  select s.* into v_shipment from public.shipments s where s.id = p_id;

  if v_shipment.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_shipment.store_id) then
    raise exception 'الشحنة غير موجودة أو غير متاحة لك' using errcode = 'P0001';
  end if;

  v_can_view_profit := public.has_permission('sales.view_profit');

  select so.order_number into v_order_number from public.sales_orders so where so.id = v_shipment.sales_order_id;
  select sr.return_number into v_return_number from public.sales_returns sr where sr.id = v_shipment.sales_return_id;
  select st.name_ar into v_store_name from public.stores st where st.id = v_shipment.store_id;
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

    select fe.amount into v_effective_charge
    from public.shipment_financial_events fe
    where fe.shipment_id = v_shipment.id and fe.event_type = 'customer_charge_correction'
    order by fe.created_at desc limit 1;

    v_effective_charge := coalesce(v_effective_charge, v_shipment.customer_shipping_charge);
  end if;

  return jsonb_build_object(
    'id', v_shipment.id, 'shipment_number', v_shipment.shipment_number,
    'sales_order_id', v_shipment.sales_order_id, 'order_number', v_order_number,
    'sales_return_id', v_shipment.sales_return_id, 'return_number', v_return_number,
    'store_id', v_shipment.store_id, 'store_name', v_store_name,
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
    'status_timeline', v_status_timeline
  )
  || case when v_can_view_profit then jsonb_build_object(
    'customer_shipping_charge', v_shipment.customer_shipping_charge::text,
    'effective_customer_shipping_charge', v_effective_charge::text,
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
  'Phase 5 (Section 37) — full single-shipment read: header + append-only status timeline (never profit-gated) + append-only financial correction ledger and every money/cost/charge field (entirely absent without sales.view_profit). effective_customer_shipping_charge = latest customer_charge_correction amount if any, else the immutable creation snapshot (same derivation as record_shipment_actual_cost()/correct_shipment_actual_cost(), 0118). Scoped via user_visible_store_ids(). SECURITY DEFINER.';

revoke execute on function public.get_shipment(uuid) from public;
grant execute on function public.get_shipment(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- list_shipments() — Section 37/39 (the /shipments list page's data source).
-- ---------------------------------------------------------------------------
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
  p_offset integer default 0
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
    s.carrier_id, c.code, c.name_ar,
    s.shipping_zone_id, z.code, z.name_ar,
    s.direction, s.fulfillment_type,
    s.tracking_number,
    s.customer_name_snapshot, s.customer_phone_snapshot,
    s.shipment_date, s.is_cod, s.cod_collection_state, s.current_status, s.row_version,
    case when v_can_view_profit then s.customer_shipping_charge::text else null end,
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
  order by s.shipment_date desc, s.created_at desc
  limit v_limit offset v_offset;
end;
$$;

comment on function public.list_shipments(date, date, uuid, uuid, uuid, text, text, text, text, uuid, uuid, integer, integer) is
  'Phase 5 (Section 37/39) — the /shipments list page data source. Every money/cost column returned as SQL NULL without sales.view_profit (never a fabricated 0.00 — the frontend must distinguish "redacted" from "genuinely zero"). Scoped via user_visible_store_ids(). SECURITY DEFINER.';

revoke execute on function public.list_shipments(date, date, uuid, uuid, uuid, text, text, text, text, uuid, uuid, integer, integer) from public;
grant execute on function public.list_shipments(date, date, uuid, uuid, uuid, text, text, text, text, uuid, uuid, integer, integer) to authenticated;
