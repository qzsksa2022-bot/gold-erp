-- ============================================================================
-- Phase 8 — Integrity Patch 8.1 (0206)
-- get_shipping_report(): explicit Dual Basis (§7-8) — Current Effective
-- (unchanged row shape, still the default) plus a new
-- movements_during_period basis sourced from _report_shipping_profit_
-- movements() (0205). Also raises the export row cap (§11-14/§60).
-- ============================================================================
-- FREEZE: migrations 0001-0205 untouched. CREATE OR REPLACE — p_basis is a
-- NEW parameter appended at the very end with a default, so every existing
-- call site (screen pages, the export route, get_dashboard_summary/trends,
-- which do not call this function at all) keeps working unchanged (§0: an
-- appended, defaulted parameter is not a signature-breaking change).
--
-- §7-8: get_shipping_report() keeps its Current Effective view as the
-- DEFAULT (p_basis='current_effective') — it stays useful operationally
-- (a shipment's CURRENT recorded cost/state) and nothing about it changes.
-- A NEW p_basis='movements_during_period' returns row-level financial
-- MOVEMENTS instead (one row per _report_shipping_profit_movements()
-- result — initial recognition + every dated correction), which is what
-- Dashboard/Daily/Weekly/Monthly/Yearly Management Reports are now backed
-- by (0205) — so this report can show the SAME row-level detail behind
-- those figures on request, closing the gap the patch spec flags (§7:
-- "Dashboard وDaily/Weekly/Monthly/Yearly: يجب تستخدم movements_during_period
-- لا Current cache by shipment_date" — now true by construction for the
-- Dashboard side; this migration gives the Report itself the same option
-- for row-level drill-down, still never labeling a movement's cost delta
-- "actual_carrier_cost", §8).
--
-- §11-14/§60: the export truncation blocker is fixed primarily in the APP
-- layer (see src/features/reports/queries.ts, src/app/api/reports/export/
-- route.ts in this same delivery) — the export path now requests up to a
-- documented EXPORT_SAFETY_MAX rows in ONE call (same RPC, same MVCC
-- snapshot as the summary, §92/§93) instead of hardcoding PAGE_SIZE=50, and
-- explicitly errors ("export_too_large") rather than silently truncating
-- when total_count exceeds that max. This requires every report RPC's own
-- v_limit clamp ceiling to be raised from 500 to a value >= the app's
-- EXPORT_SAFETY_MAX (5000, chosen and documented in the app layer) — done
-- here for get_shipping_report(); the other 10 report RPCs get the same
-- one-line cap raise in their own thematic migrations later in this patch
-- (0208-0213), each already being rewritten there for other Patch 8.1 fixes.
-- ============================================================================
begin;

-- p_basis is a genuinely NEW parameter (13th), not just a body change: in
-- PostgreSQL, appending a parameter changes a function's identity (name +
-- argument-type list), so CREATE OR REPLACE alone would create a SECOND,
-- overloaded get_shipping_report() sitting beside 0203's original 12-arg
-- one — ambiguous for any positional call passing 2-12 args. §0 sanctions
-- exactly this case ("DROP old signature + CREATE عند تغيير signature").
drop function if exists public.get_shipping_report(date, date, uuid[], uuid, uuid, text, text, boolean, text, text, integer, integer);

create function public.get_shipping_report(
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
  p_offset integer default 0,
  p_basis text default 'current_effective'
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
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 5000);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_result jsonb;
begin
  if v_actor is null or not public.has_permission('reports.view') or not public.has_permission('shipments.view') then
    raise exception 'ليست لديك صلاحية عرض تقرير الشحن' using errcode = 'P0001';
  end if;
  if p_basis not in ('current_effective', 'movements_during_period') then
    raise exception 'basis غير صالح: % (المسموح: current_effective/movements_during_period)', p_basis using errcode = 'P0001';
  end if;
  perform public._report_validate_date_range(p_date_from, p_date_to);
  v_can_profit := public.has_permission('sales.view_profit');
  v_stores := public._report_resolve_store_filter(v_actor, p_store_ids);

  if p_basis = 'movements_during_period' then
    -- §7-8: row-level financial MOVEMENTS (initial recognition + every
    -- dated actual_cost_recorded/actual_cost_correction/customer_charge_
    -- correction event) — never called "actual_carrier_cost" anywhere here.
    with movements as (
      select m.shipment_id, m.movement_date, m.movement_type, m.customer_charge_effect, m.carrier_cost_effect, m.net_shipping_effect,
        sh.shipment_number, sh.store_id, s.name_ar as store_name, so.order_number,
        sh.carrier_name_snapshot, sh.is_cod
      from public._report_shipping_profit_movements(p_date_from, p_date_to, v_stores) m
      join public.shipments sh on sh.id = m.shipment_id
      join public.stores s on s.id = sh.store_id
      join public.sales_orders so on so.id = sh.sales_order_id
      where (p_carrier_id is null or sh.carrier_id = p_carrier_id)
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
        count(*) as movements_count,
        count(*) filter (where movement_type = 'initial') as initial_count,
        coalesce(sum(customer_charge_effect), 0) as customer_charge_effect,
        coalesce(sum(carrier_cost_effect), 0) as carrier_cost_effect,
        coalesce(sum(net_shipping_effect), 0) as net_shipping_effect
      from movements
    ),
    paged as (
      select * from movements
      order by
        case when p_sort = 'shipment_date_asc' then movement_date end asc,
        movement_date desc, shipment_number desc
      limit v_limit offset v_offset
    )
    select jsonb_build_object(
      'total_count', (select movements_count from summary),
      'limit', v_limit, 'offset', v_offset,
      'basis', 'movements_during_period',
      'summary', jsonb_build_object(
        'movements_count', (select movements_count from summary),
        'initial_count', (select initial_count from summary),
        'customer_charge_effect', (select customer_charge_effect::text from summary)
      ) || (case when v_can_profit then jsonb_build_object(
        'carrier_cost_effect', (select carrier_cost_effect::text from summary),
        'net_shipping_effect', (select net_shipping_effect::text from summary)
      ) else '{}'::jsonb end),
      'rows', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'shipment_id', paged.shipment_id, 'shipment_number', paged.shipment_number,
          'movement_date', paged.movement_date, 'movement_type', paged.movement_type,
          'store_id', paged.store_id, 'store_name', paged.store_name, 'order_number', paged.order_number,
          'carrier_name', paged.carrier_name_snapshot, 'is_cod', paged.is_cod,
          'customer_charge_effect', paged.customer_charge_effect::text
        ) || (case when v_can_profit then jsonb_build_object(
          'carrier_cost_effect', paged.carrier_cost_effect::text,
          'net_shipping_effect', paged.net_shipping_effect::text
        ) else '{}'::jsonb end) order by paged.movement_date desc), '[]'::jsonb)
        from paged
      )
    ) into v_result;

    return v_result;
  end if;

  -- p_basis = 'current_effective' (default, unchanged from 0203 except the
  -- v_limit cap raise above).
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

comment on function public.get_shipping_report(date, date, uuid[], uuid, uuid, text, text, boolean, text, text, integer, integer, text) is
  'Phase 8 §29/§39/§45/§63/§83; Patch 8.1 §7-8/§11-14/§60 -- row-level Shipping Report, explicit DUAL basis: current_effective (default, unchanged) shows each shipment''s current recorded state; movements_during_period (new) shows row-level financial movements from _report_shipping_profit_movements() (initial recognition + every dated cost/charge correction event) -- the same event-dated basis the Dashboard now uses (0205). Movement cost fields are named carrier_cost_effect/net_shipping_effect, never "actual_carrier_cost" (§8). Export row cap raised 500->5000 (§11-14/§60). Cost/profit fields require sales.view_profit either basis. Requires reports.view + shipments.view. SECURITY DEFINER.';

revoke execute on function public.get_shipping_report(date, date, uuid[], uuid, uuid, text, text, boolean, text, text, integer, integer, text) from public;
grant execute on function public.get_shipping_report(date, date, uuid[], uuid, uuid, text, text, boolean, text, text, integer, integer, text) to authenticated;

commit;
