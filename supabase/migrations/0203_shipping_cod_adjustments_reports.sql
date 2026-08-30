-- ============================================================================
-- Phase 8 — Reports, Dashboard & Exports (0203)
-- get_shipping_report(), get_cod_report(), get_adjustments_report()
-- (§29-§32).
-- ============================================================================
-- FREEZE: migrations 0001-0202 untouched. Purely additive.
--
-- get_shipping_report() and get_cod_report() are row-level "Current
-- Effective" reports (§83 basis) over public.shipments -- a shipment's
-- cost/status fields are NOT reversed/chained the way Returns/Adjustments/
-- Settlements are in this schema (no reversal table exists for shipments),
-- so there is no separate approval/undo movement pair to build; the
-- shipment's own stored columns, filtered by its own shipment_date, ARE
-- the period fact (documented explicitly here per §83's own instruction
-- to be explicit whenever the basis could be ambiguous).
--
-- get_adjustments_report() IS a movements ledger (§84/§85), mirroring
-- get_dashboard_summary()'s adj_appr_cte/adj_rev_cte exactly: an 'approved'
-- movement dated adjustment_date (sales_order_adjustments' own columns,
-- immutable once approved per the reject_terminal_mutation trigger) and,
-- when a sales_order_adjustment_reversals row exists, a separate 'reversed'
-- movement dated ITS OWN reversal_business_date using that table's own
-- *_reversal_amount columns AS-IS (confirmed via direct data inspection:
-- these are already correctly signed net-effect amounts, e.g.
-- net_profit_reversal_amount = -58.00 to undo a +58.00 net_adjustment_profit
-- -- unlike sales_returns' legacy net_profit_reversal_amount column, no
-- negation or column-substitution is needed here). Store scope uses the
-- SAME dual-AND cross-store visibility as the Dashboard (§8/§9): both the
-- adjustment's own processing_store_id AND its originating sale's store_id
-- must be in the resolved filter.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- get_shipping_report() (§29): row-level shipment listing, Current
-- Effective basis (§83).
-- ---------------------------------------------------------------------------
create or replace function public.get_shipping_report(
  p_date_from date,
  p_date_to date,
  p_store_ids uuid[] default null,
  p_carrier_id uuid default null,
  p_shipping_zone_id uuid default null,
  p_direction text default null,
  p_current_status text default null,
  p_is_cod boolean default null,
  p_search text default null,
  p_sort text default 'shipment_date_desc',
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_actor uuid := auth.uid();
  v_can_profit boolean;
  v_stores uuid[];
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 500);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_result jsonb;
begin
  if v_actor is null or not public.has_permission('reports.view') or not public.has_permission('shipments.view') then
    raise exception 'ليست لديك صلاحية عرض تقرير الشحن' using errcode = 'P0001';
  end if;
  perform public._report_validate_date_range(p_date_from, p_date_to);
  v_can_profit := public.has_permission('sales.view_profit');
  v_stores := public._report_resolve_store_filter(v_actor, p_store_ids);

  with matched as (
    select sh.id, sh.shipment_number, sh.shipment_date, sh.store_id, s.name_ar as store_name,
      sh.direction, sh.fulfillment_type, sh.current_status, sh.is_cod, sh.tracking_number,
      sh.carrier_name_snapshot, sh.shipping_zone_name_snapshot,
      so.order_number,
      sh.customer_shipping_charge, sh.expected_carrier_cost, sh.actual_carrier_cost,
      sh.net_shipping_expected, sh.net_shipping_actual,
      coalesce(sh.net_shipping_actual, sh.net_shipping_expected) as net_shipping_result
    from public.shipments sh
    join public.sales_orders so on so.id = sh.sales_order_id
    join public.stores s on s.id = sh.store_id
    where sh.shipment_date between p_date_from and p_date_to
      and sh.store_id = any (v_stores)
      and (p_carrier_id is null or sh.carrier_id = p_carrier_id)
      and (p_shipping_zone_id is null or sh.shipping_zone_id = p_shipping_zone_id)
      and (p_direction is null or sh.direction = p_direction)
      and (p_current_status is null or sh.current_status = p_current_status)
      and (p_is_cod is null or sh.is_cod = p_is_cod)
      and (p_search is null or btrim(p_search) = ''
           or sh.shipment_number ilike '%' || btrim(p_search) || '%'
           or sh.tracking_number ilike '%' || btrim(p_search) || '%'
           or so.order_number ilike '%' || btrim(p_search) || '%')
  ),
  summary as (
    select
      count(*) as shipments_count,
      coalesce(sum(customer_shipping_charge), 0) as customer_shipping_charge,
      coalesce(sum(expected_carrier_cost), 0) as expected_carrier_cost,
      coalesce(sum(actual_carrier_cost), 0) as actual_carrier_cost,
      coalesce(sum(net_shipping_result), 0) as net_shipping_result
    from matched
  ),
  paged as (
    select * from matched
    order by
      case when p_sort = 'shipment_date_asc' then shipment_date end asc,
      shipment_date desc, shipment_number desc
    limit v_limit offset v_offset
  )
  select jsonb_build_object(
    'total_count', (select shipments_count from summary),
    'limit', v_limit, 'offset', v_offset,
    'basis', 'current_effective',
    'summary', jsonb_build_object(
      'shipments_count', (select shipments_count from summary),
      'customer_shipping_charge', (select customer_shipping_charge::text from summary)
    ) || (case when v_can_profit then jsonb_build_object(
      'expected_carrier_cost', (select expected_carrier_cost::text from summary),
      'actual_carrier_cost', (select actual_carrier_cost::text from summary),
      'net_shipping_result', (select net_shipping_result::text from summary)
    ) else '{}'::jsonb end),
    'rows', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'shipment_id', paged.id, 'shipment_number', paged.shipment_number, 'shipment_date', paged.shipment_date,
        'store_id', paged.store_id, 'store_name', paged.store_name, 'order_number', paged.order_number,
        'direction', paged.direction, 'fulfillment_type', paged.fulfillment_type, 'current_status', paged.current_status,
        'is_cod', paged.is_cod, 'tracking_number', paged.tracking_number,
        'carrier_name', paged.carrier_name_snapshot, 'shipping_zone_name', paged.shipping_zone_name_snapshot,
        'customer_shipping_charge', paged.customer_shipping_charge::text
      ) || (case when v_can_profit then jsonb_build_object(
        'expected_carrier_cost', paged.expected_carrier_cost::text,
        'actual_carrier_cost', paged.actual_carrier_cost::text,
        'net_shipping_result', paged.net_shipping_result::text
      ) else '{}'::jsonb end) order by paged.shipment_date desc), '[]'::jsonb)
      from paged
    )
  ) into v_result;

  return v_result;
end;
$$;

comment on function public.get_shipping_report(date, date, uuid[], uuid, uuid, text, text, boolean, text, text, integer, integer) is
  'Phase 8 §29/§39/§45/§63/§83 -- row-level Shipping Report, Current Effective basis (shipments have no reversal table). Carrier cost / net_shipping_result require sales.view_profit. Requires reports.view + shipments.view. SECURITY DEFINER.';

revoke execute on function public.get_shipping_report(date, date, uuid[], uuid, uuid, text, text, boolean, text, text, integer, integer) from public;
grant execute on function public.get_shipping_report(date, date, uuid[], uuid, uuid, text, text, boolean, text, text, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- get_cod_report() (§30): row-level COD shipment listing (is_cod = true
-- only), Current Effective basis (§83) -- cod_collection_state is a state
-- machine on the shipment itself, not a reversible ledger in this schema.
-- ---------------------------------------------------------------------------
create or replace function public.get_cod_report(
  p_date_from date,
  p_date_to date,
  p_store_ids uuid[] default null,
  p_cod_collection_state text default null,
  p_search text default null,
  p_sort text default 'shipment_date_desc',
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_actor uuid := auth.uid();
  v_can_profit boolean;
  v_stores uuid[];
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 500);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_result jsonb;
begin
  if v_actor is null or not public.has_permission('reports.view') or not public.has_permission('shipments.view') then
    raise exception 'ليست لديك صلاحية عرض تقرير الدفع عند الاستلام' using errcode = 'P0001';
  end if;
  perform public._report_validate_date_range(p_date_from, p_date_to);
  v_can_profit := public.has_permission('sales.view_profit');
  v_stores := public._report_resolve_store_filter(v_actor, p_store_ids);

  with matched as (
    select sh.id, sh.shipment_number, sh.shipment_date, sh.store_id, s.name_ar as store_name,
      sh.current_status, sh.cod_expected_amount, sh.cod_collection_state,
      so.order_number,
      (select max(ce.business_date) from public.shipment_cod_events ce where ce.shipment_id = sh.id) as last_event_date,
      (select ce.reference from public.shipment_cod_events ce where ce.shipment_id = sh.id order by ce.business_date desc, ce.created_at desc limit 1) as last_event_reference
    from public.shipments sh
    join public.sales_orders so on so.id = sh.sales_order_id
    join public.stores s on s.id = sh.store_id
    where sh.is_cod = true
      and sh.shipment_date between p_date_from and p_date_to
      and sh.store_id = any (v_stores)
      and (p_cod_collection_state is null or sh.cod_collection_state = p_cod_collection_state)
      and (p_search is null or btrim(p_search) = ''
           or sh.shipment_number ilike '%' || btrim(p_search) || '%'
           or so.order_number ilike '%' || btrim(p_search) || '%')
  ),
  summary as (
    select
      count(*) as shipments_count,
      count(*) filter (where cod_collection_state = 'collected') as collected_count,
      count(*) filter (where cod_collection_state = 'not_collected') as not_collected_count,
      count(*) filter (where cod_collection_state in ('expected', 'unknown')) as pending_count,
      coalesce(sum(cod_expected_amount), 0) as cod_expected_amount,
      coalesce(sum(cod_expected_amount) filter (where cod_collection_state = 'collected'), 0) as cod_collected_amount
    from matched
  ),
  paged as (
    select * from matched
    order by
      case when p_sort = 'shipment_date_asc' then shipment_date end asc,
      shipment_date desc, shipment_number desc
    limit v_limit offset v_offset
  )
  select jsonb_build_object(
    'total_count', (select shipments_count from summary),
    'limit', v_limit, 'offset', v_offset,
    'basis', 'current_effective',
    'summary', jsonb_build_object(
      'shipments_count', (select shipments_count from summary),
      'collected_count', (select collected_count from summary),
      'not_collected_count', (select not_collected_count from summary),
      'pending_count', (select pending_count from summary)
    ) || (case when v_can_profit then jsonb_build_object(
      'cod_expected_amount', (select cod_expected_amount::text from summary),
      'cod_collected_amount', (select cod_collected_amount::text from summary)
    ) else '{}'::jsonb end),
    'rows', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'shipment_id', paged.id, 'shipment_number', paged.shipment_number, 'shipment_date', paged.shipment_date,
        'store_id', paged.store_id, 'store_name', paged.store_name, 'order_number', paged.order_number,
        'current_status', paged.current_status, 'cod_collection_state', paged.cod_collection_state,
        'last_event_date', paged.last_event_date, 'last_event_reference', paged.last_event_reference
      ) || (case when v_can_profit then jsonb_build_object(
        'cod_expected_amount', paged.cod_expected_amount::text
      ) else '{}'::jsonb end) order by paged.shipment_date desc), '[]'::jsonb)
      from paged
    )
  ) into v_result;

  return v_result;
end;
$$;

comment on function public.get_cod_report(date, date, uuid[], text, text, text, integer, integer) is
  'Phase 8 §30/§39/§45/§63/§83 -- row-level COD Report over is_cod shipments, Current Effective basis. cod_expected_amount requires sales.view_profit. Requires reports.view + shipments.view. SECURITY DEFINER.';

revoke execute on function public.get_cod_report(date, date, uuid[], text, text, text, integer, integer) from public;
grant execute on function public.get_cod_report(date, date, uuid[], text, text, text, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- get_adjustments_report() (§32): movements-ledger row-level Adjustments
-- Report (§83 basis: "Movements during the Period"), mirroring
-- get_dashboard_summary()'s adj_appr_cte/adj_rev_cte exactly.
-- ---------------------------------------------------------------------------
create or replace function public.get_adjustments_report(
  p_date_from date,
  p_date_to date,
  p_store_ids uuid[] default null,
  p_adjustment_type_id uuid default null,
  p_search text default null,
  p_sort text default 'movement_date_desc',
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_actor uuid := auth.uid();
  v_can_profit boolean;
  v_stores uuid[];
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 500);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_result jsonb;
begin
  if v_actor is null or not public.has_permission('reports.view') or not public.has_permission('adjustments.view') then
    raise exception 'ليست لديك صلاحية عرض تقرير التسويات' using errcode = 'P0001';
  end if;
  perform public._report_validate_date_range(p_date_from, p_date_to);
  v_can_profit := public.has_permission('sales.view_profit');
  v_stores := public._report_resolve_store_filter(v_actor, p_store_ids);

  with movements as (
    -- Approval movements: adjustment_date is the movement's own business
    -- date. sales_order_adjustments' columns are immutable once approved.
    select
      a.id as adjustment_id, a.adjustment_number, a.adjustment_date as movement_date, 'approved'::text as movement_type,
      a.sales_order_id, so.order_number, a.processing_store_id, s.name_ar as store_name,
      a.adjustment_type_id, a.adjustment_type_name_ar_snapshot as adjustment_type_label,
      a.customer_charge as customer_charge_effect, a.direct_cost as direct_cost_effect,
      a.payment_fee_amount as payment_fee_effect, a.gross_adjustment_profit as gross_profit_effect,
      a.net_adjustment_profit as net_profit_effect
    from public.sales_order_adjustments a
    join public.sales_orders so on so.id = a.sales_order_id
    join public.stores s on s.id = a.processing_store_id
    where a.status = 'approved'
      and a.adjustment_date between p_date_from and p_date_to
      and a.processing_store_id = any (v_stores)
      and exists (select 1 from public.sales_orders so2 where so2.id = a.sales_order_id and so2.store_id = any (v_stores))
      and (p_adjustment_type_id is null or a.adjustment_type_id = p_adjustment_type_id)
      and (p_search is null or btrim(p_search) = '' or a.adjustment_number ilike '%' || btrim(p_search) || '%' or so.order_number ilike '%' || btrim(p_search) || '%')

    union all

    -- Reversal (undo) movements: reversal_business_date is a SEPARATE own
    -- business date (§85). sales_order_adjustment_reversals' own
    -- *_reversal_amount columns are already correctly signed net-effect
    -- amounts (verified by data inspection) -- used AS-IS, no negation.
    select
      a.id as adjustment_id, a.adjustment_number, r.reversal_business_date as movement_date, 'reversed'::text as movement_type,
      a.sales_order_id, so.order_number, a.processing_store_id, s.name_ar as store_name,
      a.adjustment_type_id, a.adjustment_type_name_ar_snapshot as adjustment_type_label,
      r.customer_charge_reversal_amount as customer_charge_effect, r.direct_cost_reversal_amount as direct_cost_effect,
      r.payment_fee_reversal_amount as payment_fee_effect, r.gross_profit_reversal_amount as gross_profit_effect,
      r.net_profit_reversal_amount as net_profit_effect
    from public.sales_order_adjustment_reversals r
    join public.sales_order_adjustments a on a.id = r.sales_order_adjustment_id
    join public.sales_orders so on so.id = a.sales_order_id
    join public.stores s on s.id = a.processing_store_id
    where r.reversal_business_date between p_date_from and p_date_to
      and a.processing_store_id = any (v_stores)
      and exists (select 1 from public.sales_orders so2 where so2.id = a.sales_order_id and so2.store_id = any (v_stores))
      and (p_adjustment_type_id is null or a.adjustment_type_id = p_adjustment_type_id)
      and (p_search is null or btrim(p_search) = '' or a.adjustment_number ilike '%' || btrim(p_search) || '%' or so.order_number ilike '%' || btrim(p_search) || '%')
  ),
  summary as (
    select
      count(*) as movements_count,
      count(*) filter (where movement_type = 'approved') as approved_count,
      count(*) filter (where movement_type = 'reversed') as reversed_count,
      coalesce(sum(customer_charge_effect), 0) as customer_charge_effect,
      coalesce(sum(direct_cost_effect), 0) as direct_cost_effect,
      coalesce(sum(payment_fee_effect), 0) as payment_fee_effect,
      coalesce(sum(gross_profit_effect), 0) as gross_profit_effect,
      coalesce(sum(net_profit_effect), 0) as net_profit_effect
    from movements
  ),
  paged as (
    select * from movements
    order by
      case when p_sort = 'movement_date_asc' then movement_date end asc,
      movement_date desc, adjustment_number desc
    limit v_limit offset v_offset
  )
  select jsonb_build_object(
    'total_count', (select movements_count from summary),
    'limit', v_limit, 'offset', v_offset,
    'basis', 'movements_during_period',
    'summary', jsonb_build_object(
      'movements_count', (select movements_count from summary),
      'approved_count', (select approved_count from summary),
      'reversed_count', (select reversed_count from summary),
      'customer_charge_effect', (select customer_charge_effect::text from summary)
    ) || (case when v_can_profit then jsonb_build_object(
      'direct_cost_effect', (select direct_cost_effect::text from summary),
      'payment_fee_effect', (select payment_fee_effect::text from summary),
      'gross_profit_effect', (select gross_profit_effect::text from summary),
      'net_profit_effect', (select net_profit_effect::text from summary)
    ) else '{}'::jsonb end),
    'rows', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'adjustment_id', paged.adjustment_id, 'adjustment_number', paged.adjustment_number,
        'movement_date', paged.movement_date, 'movement_type', paged.movement_type,
        'sales_order_id', paged.sales_order_id, 'order_number', paged.order_number,
        'store_id', paged.processing_store_id, 'store_name', paged.store_name,
        'adjustment_type_id', paged.adjustment_type_id, 'adjustment_type_label', paged.adjustment_type_label,
        'customer_charge_effect', paged.customer_charge_effect::text
      ) || (case when v_can_profit then jsonb_build_object(
        'direct_cost_effect', paged.direct_cost_effect::text, 'payment_fee_effect', paged.payment_fee_effect::text,
        'gross_profit_effect', paged.gross_profit_effect::text, 'net_profit_effect', paged.net_profit_effect::text
      ) else '{}'::jsonb end) order by paged.movement_date desc), '[]'::jsonb)
      from paged
    )
  ) into v_result;

  return v_result;
end;
$$;

comment on function public.get_adjustments_report(date, date, uuid[], uuid, text, text, integer, integer) is
  'Phase 8 §32/§39/§45/§63/§83/§84/§85 -- adjustments MOVEMENTS LEDGER (row-level detail behind get_dashboard_summary()''s adjustments figures): an ''approved'' movement dated adjustment_date and, if reversed, a separate ''reversed'' undo movement dated its own reversal_business_date using sales_order_adjustment_reversals'' pre-signed *_reversal_amount columns as-is. Dual cross-store visibility (§8/§9). Financial-effect fields require sales.view_profit. Requires reports.view + adjustments.view. SECURITY DEFINER.';

revoke execute on function public.get_adjustments_report(date, date, uuid[], uuid, text, text, integer, integer) from public;
grant execute on function public.get_adjustments_report(date, date, uuid[], uuid, text, text, integer, integer) to authenticated;

commit;
