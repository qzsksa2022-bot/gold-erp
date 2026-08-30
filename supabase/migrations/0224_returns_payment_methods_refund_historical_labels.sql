-- ============================================================================
-- Phase 8 — Final Closure Hotfix 8.1.2 — §19-22 CRITICAL:
-- get_returns_report()'s 'actual_cash' basis and get_payment_methods_
-- report()'s Refund Cash section must use the refund EVENT's own historical
-- refund_method_name_snapshot (0106/0107) for display, never a live join to
-- payment_methods.name_ar -- exactly the same class of bug §26/§27 (Hotfix
-- 8.1.1) already fixed for the Settlement/COD sections of these same
-- reports, just never applied to the Refund Cash side.
-- ============================================================================
-- Migrations 0001-0223 are FROZEN. This migration only ADDS 0224+.
-- Both functions' signatures are UNCHANGED -- body-only fixes, CREATE OR
-- REPLACE directly (§0, no DROP needed).
--
-- §19-20 bug: sales_return_refund_events.refund_method_name_snapshot (0106)
-- is captured PERMANENTLY at insert time specifically so a later Payment
-- Method rename can never rewrite an already-reported historical period's
-- label (0106's own UPDATE-blocking trigger enforces this immutability) --
-- but get_returns_report()'s 'actual_cash' basis and get_payment_methods_
-- report()'s Refund Cash section both instead did
-- `join public.payment_methods pm on pm.id = e.refund_method_id ...
-- pm.name_ar as refund_method_name`, reading the CURRENT name, defeating
-- the snapshot's entire purpose for exactly the two screens/reports whose
-- name is "Refund Method" / "Refund Cash".
--
-- Fix (§21-22): both now read
-- `coalesce(e.refund_method_name_snapshot, pm.name_ar) as refund_method_name`
-- -- the historical snapshot wins whenever present (the normal case for
-- every event recorded since 0107); the live name is only a defensive
-- fallback for the (already backfilled by 0106, so not expected to ever
-- fire in practice) case of a legacy pre-snapshot row. Identity
-- (refund_method_id) is UNCHANGED -- still the stable master-data reference
-- used for filtering (p_refund_method_id) and joining.
--
-- get_payment_methods_report()'s Refund Cash `by_method` aggregation
-- additionally now GROUPS BY (refund_method_id, refund_method_name_snapshot)
-- instead of refund_method_id alone -- unlike the Settlement/COD sections
-- (§26/§27, "latest-in-period batch wins" tie-break, because those group by
-- a ROUTE identity that can only display ONE label per period), a Refund
-- Cash row IS the aggregate itself: if a payment method was renamed
-- mid-period, the events recorded under each name are already two
-- genuinely different historical facts, and a mid-period grouping change
-- would either silently mix them under one arbitrary label (data loss) or
-- require an extra lookup this report has no need for. Grouping by the pair
-- instead surfaces BOTH historical labels as their own correctly-labelled
-- rows -- no information is hidden, and the common case (no rename in the
-- period) is visually unchanged (exactly one row per refund_method_id, as
-- before).
-- ============================================================================
begin;

create or replace function public.get_returns_report(
  p_date_from date,
  p_date_to date,
  p_store_ids uuid[] default null,
  p_scenario text default null,
  p_status text default null,
  p_payment_method_id uuid default null,
  p_collection_channel_id uuid default null,
  p_search text default null,
  p_sort text default 'movement_date_desc',
  p_limit integer default 50,
  p_offset integer default 0,
  p_basis text default 'business_effect',
  p_refund_method_id uuid default null,
  p_salesperson_id uuid default null,
  p_original_sale_date_from date default null,
  p_original_sale_date_to date default null,
  p_refund_reconciliation_state text default null
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
  v_basis text := coalesce(p_basis, 'business_effect');
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 5000);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_result jsonb;
begin
  if v_actor is null or not public.has_permission('reports.view') or not public.has_permission('returns.view') then
    raise exception 'ليست لديك صلاحية عرض تقرير المرتجعات' using errcode = 'P0001';
  end if;
  if v_basis not in ('business_effect', 'actual_cash') then
    raise exception 'أساس تقرير غير صالح' using errcode = 'P0001';
  end if;
  perform public._report_validate_date_range(p_date_from, p_date_to);
  v_can_profit := public.has_permission('sales.view_profit');
  v_stores := public._report_resolve_store_filter(v_actor, p_store_ids);

  if v_basis = 'business_effect' then
    with movements as (
      select
        sr.id as return_id, sr.return_number, sr.return_date as movement_date, 'approved'::text as movement_type,
        sr.sales_order_id, so.order_number, so.sale_date as original_sale_date, so.salesperson_id,
        sr.processed_store_id, s.name_ar as store_name,
        sr.scenario, sr.status, sr.payment_method_id, pm.name_ar as payment_method_name,
        sr.collection_channel_id_snapshot as collection_channel_id, ch.name_ar as collection_channel_name,
        sr.sales_revenue_reversal_amount as revenue_effect,
        sr.gross_profit_reversal_amount as gross_profit_effect,
        sr.payment_fee_reversal_amount as payment_fee_effect,
        sr.net_sales_profit_adjustment as net_profit_effect,
        sr.approved_refund_amount as refund_effect,
        (case
          when sr.status not in ('approved', 'reversed') then 'not_applicable'
          when sr.refund_finalized_at is null then 'pending'
          when sr.refund_final_variance_reason is null then 'finalized_matched'
          else 'finalized_with_variance'
        end) as refund_reconciliation_state
      from public.sales_returns sr
      join public.sales_orders so on so.id = sr.sales_order_id
      join public.stores s on s.id = sr.processed_store_id
      left join public.payment_methods pm on pm.id = sr.payment_method_id
      left join public.collection_channels ch on ch.id = sr.collection_channel_id_snapshot
      where sr.status in ('approved', 'reversed')
        and sr.return_date between p_date_from and p_date_to
        and sr.processed_store_id = any (v_stores)
        and (p_scenario is null or sr.scenario = p_scenario)
        and (p_status is null or sr.status = p_status)
        and (p_payment_method_id is null or sr.payment_method_id = p_payment_method_id)
        and (p_collection_channel_id is null or sr.collection_channel_id_snapshot = p_collection_channel_id)
        and (p_salesperson_id is null or so.salesperson_id = p_salesperson_id)
        and (p_original_sale_date_from is null or so.sale_date >= p_original_sale_date_from)
        and (p_original_sale_date_to is null or so.sale_date <= p_original_sale_date_to)
        and (p_search is null or btrim(p_search) = '' or sr.return_number ilike '%' || btrim(p_search) || '%' or so.order_number ilike '%' || btrim(p_search) || '%')

      union all

      select
        sr.id as return_id, sr.return_number, sr.reversal_business_date as movement_date, 'reversed'::text as movement_type,
        sr.sales_order_id, so.order_number, so.sale_date as original_sale_date, so.salesperson_id,
        sr.processed_store_id, s.name_ar as store_name,
        sr.scenario, sr.status, sr.payment_method_id, pm.name_ar as payment_method_name,
        sr.collection_channel_id_snapshot as collection_channel_id, ch.name_ar as collection_channel_name,
        -coalesce(sr.sales_revenue_reversal_amount, 0) as revenue_effect,
        -coalesce(sr.gross_profit_reversal_amount, 0) as gross_profit_effect,
        -coalesce(sr.payment_fee_reversal_amount, 0) as payment_fee_effect,
        -coalesce(sr.net_sales_profit_adjustment, 0) as net_profit_effect,
        -coalesce(sr.approved_refund_amount, 0) as refund_effect,
        (case
          when sr.status not in ('approved', 'reversed') then 'not_applicable'
          when sr.refund_finalized_at is null then 'pending'
          when sr.refund_final_variance_reason is null then 'finalized_matched'
          else 'finalized_with_variance'
        end) as refund_reconciliation_state
      from public.sales_returns sr
      join public.sales_orders so on so.id = sr.sales_order_id
      join public.stores s on s.id = sr.processed_store_id
      left join public.payment_methods pm on pm.id = sr.payment_method_id
      left join public.collection_channels ch on ch.id = sr.collection_channel_id_snapshot
      where sr.status = 'reversed'
        and sr.reversal_business_date between p_date_from and p_date_to
        and sr.processed_store_id = any (v_stores)
        and (p_scenario is null or sr.scenario = p_scenario)
        and (p_status is null or sr.status = p_status)
        and (p_payment_method_id is null or sr.payment_method_id = p_payment_method_id)
        and (p_collection_channel_id is null or sr.collection_channel_id_snapshot = p_collection_channel_id)
        and (p_salesperson_id is null or so.salesperson_id = p_salesperson_id)
        and (p_original_sale_date_from is null or so.sale_date >= p_original_sale_date_from)
        and (p_original_sale_date_to is null or so.sale_date <= p_original_sale_date_to)
        and (p_search is null or btrim(p_search) = '' or sr.return_number ilike '%' || btrim(p_search) || '%' or so.order_number ilike '%' || btrim(p_search) || '%')
    ),
    filtered as (
      select * from movements m
      where (p_refund_reconciliation_state is null or m.refund_reconciliation_state = p_refund_reconciliation_state)
    ),
    summary as (
      select
        count(*) as movements_count,
        count(*) filter (where movement_type = 'approved') as approved_count,
        count(*) filter (where movement_type = 'reversed') as reversed_count,
        coalesce(sum(revenue_effect), 0) as revenue_effect,
        coalesce(sum(gross_profit_effect), 0) as gross_profit_effect,
        coalesce(sum(payment_fee_effect), 0) as payment_fee_effect,
        coalesce(sum(net_profit_effect), 0) as net_profit_effect,
        coalesce(sum(refund_effect), 0) as refund_effect
      from filtered
    ),
    paged as (
      select * from filtered
      order by
        case when p_sort = 'movement_date_asc' then movement_date end asc,
        movement_date desc, return_number desc
      limit v_limit offset v_offset
    )
    select jsonb_build_object(
      'total_count', (select movements_count from summary),
      'limit', v_limit, 'offset', v_offset,
      'basis', 'business_effect',
      'summary', jsonb_build_object(
        'movements_count', (select movements_count from summary),
        'approved_count', (select approved_count from summary),
        'reversed_count', (select reversed_count from summary),
        'refund_effect', (select refund_effect::text from summary)
      ) || (case when v_can_profit then jsonb_build_object(
        'revenue_effect', (select revenue_effect::text from summary),
        'gross_profit_effect', (select gross_profit_effect::text from summary),
        'payment_fee_effect', (select payment_fee_effect::text from summary),
        'net_profit_effect', (select net_profit_effect::text from summary)
      ) else '{}'::jsonb end),
      'rows', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'return_id', paged.return_id, 'return_number', paged.return_number,
          'movement_date', paged.movement_date, 'movement_type', paged.movement_type,
          'sales_order_id', paged.sales_order_id, 'order_number', paged.order_number,
          'original_sale_date', paged.original_sale_date,
          'store_id', paged.processed_store_id, 'store_name', paged.store_name,
          'scenario', paged.scenario, 'status', paged.status,
          'payment_method_name', paged.payment_method_name, 'collection_channel_name', paged.collection_channel_name,
          'refund_reconciliation_state', paged.refund_reconciliation_state,
          'refund_effect', paged.refund_effect::text
        ) || (case when v_can_profit then jsonb_build_object(
          'revenue_effect', paged.revenue_effect::text, 'gross_profit_effect', paged.gross_profit_effect::text,
          'payment_fee_effect', paged.payment_fee_effect::text, 'net_profit_effect', paged.net_profit_effect::text
        ) else '{}'::jsonb end) order by paged.movement_date desc), '[]'::jsonb)
        from paged
      )
    ) into v_result;
  else
    -- 'actual_cash' basis -- §19-22 FIX: refund_method_name now reads the
    -- refund EVENT's own permanent refund_method_name_snapshot (0106) when
    -- present, falling back to the live payment_methods.name_ar ONLY for a
    -- legacy pre-snapshot row (already backfilled by 0106, not expected in
    -- practice). Never a plain live join result any more.
    with cash_movements as (
      select
        e.sales_return_id as return_id, sr.return_number, e.refund_business_date as movement_date,
        'actual_refund'::text as movement_type,
        sr.sales_order_id, so.order_number, so.sale_date as original_sale_date, so.salesperson_id,
        sr.processed_store_id, s.name_ar as store_name,
        sr.scenario, sr.status,
        e.refund_method_id, coalesce(e.refund_method_name_snapshot, pm.name_ar) as refund_method_name,
        (-e.amount) as cash_effect,
        (case
          when sr.status not in ('approved', 'reversed') then 'not_applicable'
          when sr.refund_finalized_at is null then 'pending'
          when sr.refund_final_variance_reason is null then 'finalized_matched'
          else 'finalized_with_variance'
        end) as refund_reconciliation_state
      from public.sales_return_refund_events e
      join public.sales_returns sr on sr.id = e.sales_return_id
      join public.sales_orders so on so.id = sr.sales_order_id
      join public.stores s on s.id = sr.processed_store_id
      join public.payment_methods pm on pm.id = e.refund_method_id
      where e.refund_business_date between p_date_from and p_date_to
        and sr.processed_store_id = any (v_stores)
        and (p_scenario is null or sr.scenario = p_scenario)
        and (p_status is null or sr.status = p_status)
        and (p_refund_method_id is null or e.refund_method_id = p_refund_method_id)
        and (p_salesperson_id is null or so.salesperson_id = p_salesperson_id)
        and (p_original_sale_date_from is null or so.sale_date >= p_original_sale_date_from)
        and (p_original_sale_date_to is null or so.sale_date <= p_original_sale_date_to)
        and (p_search is null or btrim(p_search) = '' or sr.return_number ilike '%' || btrim(p_search) || '%' or so.order_number ilike '%' || btrim(p_search) || '%')

      union all

      select
        rev.sales_return_id as return_id, sr.return_number, rev.reversal_business_date as movement_date,
        'actual_refund_reversal'::text as movement_type,
        sr.sales_order_id, so.order_number, so.sale_date as original_sale_date, so.salesperson_id,
        sr.processed_store_id, s.name_ar as store_name,
        sr.scenario, sr.status,
        e.refund_method_id, coalesce(e.refund_method_name_snapshot, pm.name_ar) as refund_method_name,
        e.amount as cash_effect,
        (case
          when sr.status not in ('approved', 'reversed') then 'not_applicable'
          when sr.refund_finalized_at is null then 'pending'
          when sr.refund_final_variance_reason is null then 'finalized_matched'
          else 'finalized_with_variance'
        end) as refund_reconciliation_state
      from public.sales_return_refund_event_reversals rev
      join public.sales_return_refund_events e on e.id = rev.refund_event_id
      join public.sales_returns sr on sr.id = rev.sales_return_id
      join public.sales_orders so on so.id = sr.sales_order_id
      join public.stores s on s.id = sr.processed_store_id
      join public.payment_methods pm on pm.id = e.refund_method_id
      where rev.reversal_business_date between p_date_from and p_date_to
        and sr.processed_store_id = any (v_stores)
        and (p_scenario is null or sr.scenario = p_scenario)
        and (p_status is null or sr.status = p_status)
        and (p_refund_method_id is null or e.refund_method_id = p_refund_method_id)
        and (p_salesperson_id is null or so.salesperson_id = p_salesperson_id)
        and (p_original_sale_date_from is null or so.sale_date >= p_original_sale_date_from)
        and (p_original_sale_date_to is null or so.sale_date <= p_original_sale_date_to)
        and (p_search is null or btrim(p_search) = '' or sr.return_number ilike '%' || btrim(p_search) || '%' or so.order_number ilike '%' || btrim(p_search) || '%')
    ),
    filtered as (
      select * from cash_movements cm
      where (p_refund_reconciliation_state is null or cm.refund_reconciliation_state = p_refund_reconciliation_state)
    ),
    summary as (
      select
        count(*) as movements_count,
        count(*) filter (where movement_type = 'actual_refund') as refund_events_count,
        count(*) filter (where movement_type = 'actual_refund_reversal') as reversal_events_count,
        coalesce(sum(cash_effect), 0) as cash_effect
      from filtered
    ),
    paged as (
      select * from filtered
      order by
        case when p_sort = 'movement_date_asc' then movement_date end asc,
        movement_date desc, return_number desc
      limit v_limit offset v_offset
    )
    select jsonb_build_object(
      'total_count', (select movements_count from summary),
      'limit', v_limit, 'offset', v_offset,
      'basis', 'actual_cash',
      'summary', jsonb_build_object(
        'movements_count', (select movements_count from summary),
        'refund_events_count', (select refund_events_count from summary),
        'reversal_events_count', (select reversal_events_count from summary),
        'cash_effect', (select cash_effect::text from summary)
      ),
      'rows', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'return_id', paged.return_id, 'return_number', paged.return_number,
          'movement_date', paged.movement_date, 'movement_type', paged.movement_type,
          'sales_order_id', paged.sales_order_id, 'order_number', paged.order_number,
          'original_sale_date', paged.original_sale_date,
          'store_id', paged.processed_store_id, 'store_name', paged.store_name,
          'scenario', paged.scenario, 'status', paged.status,
          'refund_method_id', paged.refund_method_id, 'refund_method_name', paged.refund_method_name,
          'refund_reconciliation_state', paged.refund_reconciliation_state,
          'cash_effect', paged.cash_effect::text
        ) order by paged.movement_date desc), '[]'::jsonb)
        from paged
      )
    ) into v_result;
  end if;

  return v_result;
end;
$$;

comment on function public.get_returns_report(date, date, uuid[], text, text, uuid, uuid, text, text, integer, integer, text, uuid, uuid, date, date, text) is
  'Phase 8 §26-29/§39/§45/§63/§83/§84/§85; Hotfix 8.1.1 §36; Hotfix 8.1.2 §19-22 -- returns DUAL BASIS report. ''actual_cash'' basis refund_method_name now reads the refund event''s own permanent refund_method_name_snapshot (0106) when present, falling back to the live payment_methods.name_ar only for a legacy pre-snapshot row -- a later Payment Method rename never rewrites an already-reported period''s label. ''business_effect'' basis (Hotfix 8.1.1 §36) and everything else unchanged. Requires reports.view + returns.view. SECURITY DEFINER.';

revoke execute on function public.get_returns_report(date, date, uuid[], text, text, uuid, uuid, text, text, integer, integer, text, uuid, uuid, date, date, text) from public;
grant execute on function public.get_returns_report(date, date, uuid[], text, text, uuid, uuid, text, text, integer, integer, text, uuid, uuid, date, date, text) to authenticated;

-- ---------------------------------------------------------------------------
-- get_payment_methods_report() (0217) -- same §19-22 fix, Refund Cash section
-- only (Sales/Settlement sections untouched).
-- ---------------------------------------------------------------------------
create or replace function public.get_payment_methods_report(
  p_date_from date,
  p_date_to date,
  p_store_ids uuid[] default null,
  p_search text default null,
  p_sort text default 'revenue_desc',
  p_limit integer default 50,
  p_offset integer default 0,
  p_refund_method_id uuid default null,
  p_collection_channel_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_actor uuid := auth.uid();
  v_can_sales boolean;
  v_can_profit boolean;
  v_can_returns boolean;
  v_can_settlements boolean;
  v_can_settlements_financials boolean;
  v_stores uuid[];
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 5000);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_result jsonb;
begin
  if v_actor is null or not public.has_permission('reports.view') then
    raise exception 'ليست لديك صلاحية عرض تقرير طرق الدفع' using errcode = 'P0001';
  end if;
  perform public._report_validate_date_range(p_date_from, p_date_to);
  v_can_sales := public.has_permission('sales.view');
  v_can_profit := v_can_sales and public.has_permission('sales.view_profit');
  v_can_returns := public.has_permission('returns.view');
  v_can_settlements := public.has_permission('settlements.view');
  v_can_settlements_financials := v_can_settlements and public.has_permission('settlements.view_financials');
  v_stores := public._report_resolve_store_filter(v_actor, p_store_ids);

  v_result := jsonb_build_object('date_from', p_date_from, 'date_to', p_date_to, 'limit', v_limit, 'offset', v_offset);

  -- ---- Sales side (unchanged from 0207) ----
  if v_can_sales then
    with matched as (
      select so.id, so.payment_method_id, so.collection_channel_id, so.subtotal, so.gross_profit, so.payment_fee_amount, so.net_sales_profit
      from public.sales_orders so
      where so.sale_date between p_date_from and p_date_to
        and so.store_id = any (v_stores)
    ),
    grouped as (
      select payment_method_id, collection_channel_id,
        count(*) as orders_count,
        coalesce(sum(subtotal), 0) as revenue,
        coalesce(sum(gross_profit), 0) as gross_profit,
        coalesce(sum(payment_fee_amount), 0) as payment_fees,
        coalesce(sum(net_sales_profit), 0) as net_sales_profit
      from matched
      group by payment_method_id, collection_channel_id
    ),
    labelled as (
      select g.*, pm.name_ar as payment_method_name, pm.key as payment_method_key,
        ch.name_ar as collection_channel_name, ch.key as collection_channel_key
      from grouped g
      join public.payment_methods pm on pm.id = g.payment_method_id
      left join public.collection_channels ch on ch.id = g.collection_channel_id
      where (p_search is null or btrim(p_search) = '' or pm.name_ar ilike '%' || btrim(p_search) || '%' or ch.name_ar ilike '%' || btrim(p_search) || '%')
        and (p_collection_channel_id is null or g.collection_channel_id = p_collection_channel_id)
    ),
    summary as (
      select
        count(*) as pairs_count,
        coalesce(sum(orders_count), 0) as orders_count,
        coalesce(sum(revenue), 0) as revenue,
        coalesce(sum(gross_profit), 0) as gross_profit,
        coalesce(sum(payment_fees), 0) as payment_fees,
        coalesce(sum(net_sales_profit), 0) as net_sales_profit
      from labelled
    ),
    paged as (
      select * from labelled
      order by
        case when p_sort = 'revenue_asc' then revenue end asc,
        case when p_sort = 'orders_desc' then orders_count end desc,
        revenue desc, payment_method_name asc
      limit v_limit offset v_offset
    )
    select v_result || jsonb_build_object(
      'total_count', (select pairs_count from summary),
      'summary', jsonb_build_object(
        'payment_method_pairs_count', (select pairs_count from summary),
        'orders_count', (select orders_count from summary),
        'revenue', (select revenue::text from summary)
      ) || (case when v_can_profit then jsonb_build_object(
        'gross_profit', (select gross_profit::text from summary),
        'payment_fees', (select payment_fees::text from summary),
        'net_sales_profit', (select net_sales_profit::text from summary)
      ) else '{}'::jsonb end),
      'rows', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'payment_method_id', paged.payment_method_id, 'payment_method_name', paged.payment_method_name, 'payment_method_key', paged.payment_method_key,
          'collection_channel_id', paged.collection_channel_id, 'collection_channel_name', paged.collection_channel_name, 'collection_channel_key', paged.collection_channel_key,
          'orders_count', paged.orders_count, 'revenue', paged.revenue::text
        ) || (case when v_can_profit then jsonb_build_object(
          'gross_profit', paged.gross_profit::text, 'payment_fees', paged.payment_fees::text, 'net_sales_profit', paged.net_sales_profit::text
        ) else '{}'::jsonb end) order by paged.revenue desc), '[]'::jsonb)
        from paged
      )
    ) into v_result;
  end if;

  -- ---- Actual Refund Cash side -- §19-22 FIX: refund_method_name now
  -- reads each event's own permanent refund_method_name_snapshot (0106),
  -- falling back to the live name only for a legacy pre-snapshot row.
  -- by_method now groups by (refund_method_id, refund_method_name_snapshot)
  -- -- a mid-period rename surfaces as two correctly-labelled rows instead
  -- of one row silently mislabelled with whichever name happens to be
  -- live now (see migration header for why this differs from the
  -- Settlement/COD sections' "latest wins" tie-break).
  if v_can_returns then
    with matched_events as (
      select e.id, e.refund_method_id, e.refund_method_name_snapshot, e.amount, e.refund_business_date, e.sales_return_id
      from public.sales_return_refund_events e
      join public.sales_returns sr on sr.id = e.sales_return_id and sr.processed_store_id = any (v_stores)
      where e.refund_business_date between p_date_from and p_date_to
    ),
    matched_reversals as (
      select rv.id, e.refund_method_id, e.refund_method_name_snapshot, e.amount, rv.reversal_business_date
      from public.sales_return_refund_event_reversals rv
      join public.sales_return_refund_events e on e.id = rv.refund_event_id
      join public.sales_returns sr on sr.id = e.sales_return_id and sr.processed_store_id = any (v_stores)
      where rv.reversal_business_date between p_date_from and p_date_to
    ),
    by_method as (
      select refund_method_id, refund_method_name_snapshot, sum(cash_effect) as actual_refunded_cash, count(*) as events_count
      from (
        select refund_method_id, refund_method_name_snapshot, -amount as cash_effect from matched_events
        union all
        select refund_method_id, refund_method_name_snapshot, amount as cash_effect from matched_reversals
      ) x
      group by refund_method_id, refund_method_name_snapshot
    ),
    labelled as (
      select bm.*, coalesce(bm.refund_method_name_snapshot, pm.name_ar) as refund_method_name, pm.key as refund_method_key
      from by_method bm
      join public.payment_methods pm on pm.id = bm.refund_method_id
      where (p_refund_method_id is null or bm.refund_method_id = p_refund_method_id)
        and (p_search is null or btrim(p_search) = '' or coalesce(bm.refund_method_name_snapshot, pm.name_ar) ilike '%' || btrim(p_search) || '%')
    ),
    summary as (
      select count(*) as methods_count, coalesce(sum(events_count), 0) as events_count, coalesce(sum(actual_refunded_cash), 0) as actual_refunded_cash
      from labelled
    )
    select v_result || jsonb_build_object(
      'refund_summary', jsonb_build_object(
        'refund_methods_count', (select methods_count from summary),
        'refund_events_count', (select events_count from summary),
        'actual_refunded_cash', (select actual_refunded_cash::text from summary)
      ),
      'refund_rows', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'refund_method_id', labelled.refund_method_id, 'refund_method_name', labelled.refund_method_name, 'refund_method_key', labelled.refund_method_key,
          'collection_channel_id', null,
          'events_count', labelled.events_count, 'actual_refunded_cash', labelled.actual_refunded_cash::text
        ) order by labelled.actual_refunded_cash desc), '[]'::jsonb)
        from labelled
      )
    ) into v_result;
  end if;

  -- ---- Bank Settlement side (unchanged from 0217) ----
  if v_can_settlements then
    with route_scope as (
      select r.id as route_id, r.payment_method_id, r.collection_channel_id
      from public.settlement_routes r
      where r.route_kind = 'payment_collection'
    ),
    batch_scope as (
      select b.id, b.settlement_route_id, b.settlement_date, b.expected_bank_settlement,
        b.route_name_ar_snapshot, b.payment_method_name_snapshot, b.collection_channel_name_snapshot,
        exists (select 1 from public.settlement_batch_cancellations c where c.settlement_batch_id = b.id) as is_cancelled
      from public.settlement_batches b
      join route_scope rs on rs.route_id = b.settlement_route_id
      where public._report_settlement_batch_in_store_scope(b.id, v_stores)
        and b.status in ('finalized', 'reconciled')
    ),
    route_label as (
      select distinct on (settlement_route_id) settlement_route_id,
        route_name_ar_snapshot as route_name,
        payment_method_name_snapshot as payment_method_name,
        collection_channel_name_snapshot as collection_channel_name
      from batch_scope
      where settlement_date between p_date_from and p_date_to
      order by settlement_route_id, settlement_date desc, id desc
    ),
    cancellations as (
      select bs.id, bs.settlement_route_id, bs.expected_bank_settlement, cx.cancellation_business_date,
        coalesce((select sum(e.amount) from public.settlement_bank_movement_events e where e.settlement_batch_id = bs.id), 0)
          + coalesce((select sum(rv.amount_impact) from public.settlement_bank_movement_reversals rv
                       join public.settlement_bank_movement_events e2 on e2.id = rv.bank_movement_event_id
                       where e2.settlement_batch_id = bs.id), 0) as live_actual_at_cancel
      from batch_scope bs
      join public.settlement_batch_cancellations cx on cx.settlement_batch_id = bs.id
      where bs.expected_bank_settlement is not null
    ),
    movements as (
      select bs.settlement_route_id, e.movement_business_date, e.amount
      from public.settlement_bank_movement_events e
      join batch_scope bs on bs.id = e.settlement_batch_id
    ),
    reversals as (
      select bs.settlement_route_id, rv.reversal_business_date, rv.amount_impact
      from public.settlement_bank_movement_reversals rv
      join public.settlement_bank_movement_events e on e.id = rv.bank_movement_event_id
      join batch_scope bs on bs.id = e.settlement_batch_id
    ),
    per_route as (
      select rs.route_id, rl.route_name, rs.payment_method_id, rl.payment_method_name, rs.collection_channel_id, rl.collection_channel_name,
        (coalesce((select sum(expected_bank_settlement) from batch_scope where settlement_route_id = rs.route_id and settlement_date between p_date_from and p_date_to), 0)
          + coalesce((select sum(-expected_bank_settlement) from cancellations where settlement_route_id = rs.route_id and cancellation_business_date between p_date_from and p_date_to), 0)) as expected,
        (coalesce((select sum(amount) from movements where settlement_route_id = rs.route_id and movement_business_date between p_date_from and p_date_to), 0)
          + coalesce((select sum(amount_impact) from reversals where settlement_route_id = rs.route_id and reversal_business_date between p_date_from and p_date_to), 0)
          + coalesce((select sum(-live_actual_at_cancel) from cancellations where settlement_route_id = rs.route_id and cancellation_business_date between p_date_from and p_date_to), 0)) as actual,
        (select count(*) from batch_scope where settlement_route_id = rs.route_id and settlement_date between p_date_from and p_date_to) as batches_count
      from route_scope rs
      join route_label rl on rl.settlement_route_id = rs.route_id
    ),
    filtered as (
      select * from per_route
      where batches_count > 0
        and (p_search is null or btrim(p_search) = '' or route_name ilike '%' || btrim(p_search) || '%')
        and (p_collection_channel_id is null or collection_channel_id = p_collection_channel_id)
    ),
    summary as (
      select count(*) as routes_count, coalesce(sum(batches_count), 0) as batches_count,
        coalesce(sum(expected), 0) as expected, coalesce(sum(actual), 0) as actual
      from filtered
    )
    select v_result || (case when v_can_settlements_financials then jsonb_build_object(
      'settlement_summary', jsonb_build_object(
        'settlement_routes_count', (select routes_count from summary),
        'settlement_batches_count', (select batches_count from summary),
        'settlement_expected', (select expected::text from summary),
        'settlement_actual', (select actual::text from summary),
        'settlement_variance', (select (actual - expected)::text from summary)
      ),
      'settlement_rows', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'settlement_route_id', filtered.route_id, 'route_name', filtered.route_name,
          'payment_method_id', filtered.payment_method_id, 'payment_method_name', filtered.payment_method_name,
          'collection_channel_id', filtered.collection_channel_id, 'collection_channel_name', filtered.collection_channel_name,
          'batches_count', filtered.batches_count,
          'expected', filtered.expected::text, 'actual', filtered.actual::text, 'variance', (filtered.actual - filtered.expected)::text
        ) order by filtered.actual desc), '[]'::jsonb)
        from filtered
      )
    ) else '{}'::jsonb end) into v_result;
  end if;

  return v_result;
end;
$$;

comment on function public.get_payment_methods_report(date, date, uuid[], text, text, integer, integer, uuid, uuid) is
  'Phase 8 §26/§39/§45/§63; Patch 8.1 §22-25/§64; Hotfix 8.1.1 §27; Hotfix 8.1.2 §19-22 -- Payment Method report, three independently-gated sections. Refund Cash section refund_method_name now reads each event''s own permanent refund_method_name_snapshot (0106), grouped by (refund_method_id, refund_method_name_snapshot) so a mid-period rename surfaces as two correctly-labelled rows instead of one silently mislabelled row. Settlement section DISPLAY labels (Hotfix 8.1.1 §27, unchanged) still use the in-scope batch''s own historical snapshot columns. Route/payment-method/collection-channel IDENTITY stays the stable master reference for filtering. SECURITY DEFINER.';

revoke execute on function public.get_payment_methods_report(date, date, uuid[], text, text, integer, integer, uuid, uuid) from public;
grant execute on function public.get_payment_methods_report(date, date, uuid[], text, text, integer, integer, uuid, uuid) to authenticated;

commit;
