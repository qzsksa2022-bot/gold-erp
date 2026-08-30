-- ============================================================================
-- Phase 8 — Final Integrity Hotfix 8.1.1 — §27: get_payment_methods_report()
-- Settlement section must use historical batch snapshot labels, never a
-- live join to settlement_routes/payment_methods/collection_channels.
-- ============================================================================
-- Migrations 0001-0216 are FROZEN. This migration only ADDS 0217+.
-- get_payment_methods_report()'s signature is UNCHANGED from 0207 -- this
-- fix is body-only (Settlement section only), so CREATE OR REPLACE is used
-- directly (no DROP needed, §0). Sales/Refund-Cash sections are untouched.
--
-- §27: identical bug/fix pattern to §26 (get_cod_report(), 0216) -- the
-- Settlement section's route_scope joined LIVE settlement_routes/payment_
-- methods/collection_channels for display names, so a later master-data
-- rename would silently rewrite an already-reported period's labels.
-- settlement_batches' own route_name_ar_snapshot/payment_method_name_
-- snapshot/collection_channel_name_snapshot (0172) are used for DISPLAY
-- instead, with the same "latest-in-period batch wins" deterministic
-- tie-break as 0216/0211. Route/payment-method/collection-channel IDENTITY
-- (route_id, payment_method_id, collection_channel_id) stays the stable
-- master-data reference used for FILTERING and grouping (§27: "keeping
-- stable route/snapshot IDs for grouping identity") -- payment_collection
-- routes have a fixed method+channel pair by design (0207's own comment),
-- so filtering against the route's live master assignment remains correct
-- and does not need to track per-batch snapshot drift.
-- ============================================================================
begin;

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

  -- ---- Sales side: grouped by (payment_method_id, collection_channel_id) ---- (unchanged from 0207)
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

  -- ---- Actual Refund Cash side (unchanged from 0207) ----
  if v_can_returns then
    with matched_events as (
      select e.id, e.refund_method_id, e.amount, e.refund_business_date, e.sales_return_id
      from public.sales_return_refund_events e
      join public.sales_returns sr on sr.id = e.sales_return_id and sr.processed_store_id = any (v_stores)
      where e.refund_business_date between p_date_from and p_date_to
    ),
    matched_reversals as (
      select rv.id, e.refund_method_id, e.amount, rv.reversal_business_date
      from public.sales_return_refund_event_reversals rv
      join public.sales_return_refund_events e on e.id = rv.refund_event_id
      join public.sales_returns sr on sr.id = e.sales_return_id and sr.processed_store_id = any (v_stores)
      where rv.reversal_business_date between p_date_from and p_date_to
    ),
    by_method as (
      select refund_method_id, sum(cash_effect) as actual_refunded_cash, count(*) as events_count
      from (
        select refund_method_id, -amount as cash_effect from matched_events
        union all
        select refund_method_id, amount as cash_effect from matched_reversals
      ) x
      group by refund_method_id
    ),
    labelled as (
      select bm.*, pm.name_ar as refund_method_name, pm.key as refund_method_key
      from by_method bm
      join public.payment_methods pm on pm.id = bm.refund_method_id
      where (p_refund_method_id is null or bm.refund_method_id = p_refund_method_id)
        and (p_search is null or btrim(p_search) = '' or pm.name_ar ilike '%' || btrim(p_search) || '%')
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

  -- ---- Bank Settlement side (§27 historical labels): payment_collection
  -- routes only. Identity via route_scope (live, stable master reference,
  -- unchanged); DISPLAY labels via route_label (batch snapshot columns,
  -- latest-in-period wins) -- same tie-break as 0216/0211.
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
  'Phase 8 §26/§39/§45/§63; Patch 8.1 §22-25/§64; Hotfix 8.1.1 §27 -- Payment Method report, three independently-gated sections (unchanged from 0207: rows/Sales, refund_rows/Actual Refund Cash, settlement_rows/Settlements). Settlement section DISPLAY labels now read from the in-scope batch''s own historical snapshot columns (route_name_ar_snapshot/payment_method_name_snapshot/collection_channel_name_snapshot, latest-in-period wins on a mid-period rename) instead of a live join -- a later master-data rename never rewrites an already-reported period (§27). Route/payment-method/collection-channel IDENTITY stays the stable master reference for filtering. SECURITY DEFINER.';

revoke execute on function public.get_payment_methods_report(date, date, uuid[], text, text, integer, integer, uuid, uuid) from public;
grant execute on function public.get_payment_methods_report(date, date, uuid[], text, text, integer, integer, uuid, uuid) to authenticated;

commit;
