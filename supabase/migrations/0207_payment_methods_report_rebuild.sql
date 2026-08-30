-- ============================================================================
-- Phase 8 — Integrity Patch 8.1 (0207)
-- get_payment_methods_report() / get_collection_channels_report() rebuild
-- (§22-25, §64): Sales / Actual-Refund-Cash / Settlement sides shown
-- separately (never blended into one "profit" figure), Payment Method +
-- Collection Channel PAIR identity for the sales grouping, canonical cash
-- sources per §24, narrow cross-domain permission gating per §25.
-- ============================================================================
-- FREEZE: migrations 0001-0206 untouched. CREATE OR REPLACE with an
-- appended, defaulted parameter on get_payment_methods_report() (a genuinely
-- new arg — DROP+CREATE, §0) and a body-only CREATE OR REPLACE on
-- get_collection_channels_report() (same signature, cap raise only).
--
-- §22/§23 — get_payment_methods_report() now returns THREE independent
-- sections instead of one order-grouped list:
--   `rows`         — SALES side, grouped by (payment_method_id,
--                    collection_channel_id) PAIR (§23) with EXACT NULL
--                    semantics (a sale with no collection_channel_id groups
--                    under collection_channel_id=NULL, distinct from every
--                    non-NULL channel — Postgres GROUP BY already treats
--                    NULL as its own group correctly, no special-casing
--                    needed). Gated on sales.view (base requirement relaxed
--                    to reports.view only — §25: a cross-domain report must
--                    not require every domain permission just to show the
--                    ONE section an actor can see).
--   `refund_rows`  — ACTUAL REFUND CASH side (§24): sales_return_refund_
--                    events (cash out, refund_business_date) net of
--                    sales_return_refund_event_reversals (cash back in,
--                    reversal_business_date, using the ORIGINAL event''s own
--                    amount — 0106''s append-only design has no separate
--                    reversal amount column). Grouped by the event''s own
--                    refund_method_id — collection_channel_id is always
--                    NULL here (§24: "قناة: NULL حسب Domain الحالي" — no
--                    channel concept exists on a refund event). Gated on
--                    returns.view.
--   `settlement_rows` — bank settlement side (§24), restricted to
--                    route_kind=''payment_collection'' routes ONLY (COD
--                    carrier routes are get_cod_report()''s domain, §31,
--                    never double-counted here) — same movements-ledger
--                    formula as get_dashboard_summary()/get_settlements_
--                    report() (§39 Single Reporting Engine), grouped by
--                    settlement_route_id (which IS a fixed method+channel
--                    pair for payment_collection routes, §23 route master
--                    data). Gated on settlements.view (money sub-fields
--                    additionally need settlements.view_financials).
--
-- Money fields in EVERY section are absent entirely (§79) — never null,
-- never zero — when the actor lacks that section''s permission; a report
-- viewer missing ALL THREE of sales.view/returns.view/settlements.view
-- still gets a valid (all-sections-absent) envelope rather than an error
-- (§25: "لا تعطل كامل التقرير إذا الجزء المسموح مفيد").
--
-- get_collection_channels_report() keeps its existing channel-focused,
-- sales-only projection (§23''s "أو equivalent" option) unchanged in shape
-- — only the export row cap is raised here (500 -> 5000, §11-14/§60).
-- ============================================================================
begin;

drop function if exists public.get_payment_methods_report(date, date, uuid[], text, text, integer, integer);

create function public.get_payment_methods_report(
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

  -- ---- Sales side: grouped by (payment_method_id, collection_channel_id) ----
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

  -- ---- Actual Refund Cash side (§24): refund_method_id only, channel NULL ----
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

  -- ---- Bank Settlement side (§24): payment_collection routes only ----
  if v_can_settlements then
    with route_scope as (
      select r.id as route_id, r.name_ar as route_name, r.payment_method_id, r.collection_channel_id,
        pm.name_ar as payment_method_name, ch.name_ar as collection_channel_name
      from public.settlement_routes r
      join public.payment_methods pm on pm.id = r.payment_method_id
      left join public.collection_channels ch on ch.id = r.collection_channel_id
      where r.route_kind = 'payment_collection'
    ),
    batch_scope as (
      select b.id, b.settlement_route_id, b.settlement_date, b.expected_bank_settlement,
        exists (select 1 from public.settlement_batch_cancellations c where c.settlement_batch_id = b.id) as is_cancelled
      from public.settlement_batches b
      join route_scope rs on rs.route_id = b.settlement_route_id
      where public._report_settlement_batch_in_store_scope(b.id, v_stores)
        and b.status in ('finalized', 'reconciled')
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
      select rs.route_id, rs.route_name, rs.payment_method_id, rs.payment_method_name, rs.collection_channel_id, rs.collection_channel_name,
        (coalesce((select sum(expected_bank_settlement) from batch_scope where settlement_route_id = rs.route_id and settlement_date between p_date_from and p_date_to), 0)
          + coalesce((select sum(-expected_bank_settlement) from cancellations where settlement_route_id = rs.route_id and cancellation_business_date between p_date_from and p_date_to), 0)) as expected,
        (coalesce((select sum(amount) from movements where settlement_route_id = rs.route_id and movement_business_date between p_date_from and p_date_to), 0)
          + coalesce((select sum(amount_impact) from reversals where settlement_route_id = rs.route_id and reversal_business_date between p_date_from and p_date_to), 0)
          + coalesce((select sum(-live_actual_at_cancel) from cancellations where settlement_route_id = rs.route_id and cancellation_business_date between p_date_from and p_date_to), 0)) as actual,
        (select count(*) from batch_scope where settlement_route_id = rs.route_id and settlement_date between p_date_from and p_date_to) as batches_count
      from route_scope rs
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
  'Phase 8 §26/§39/§45/§63; Patch 8.1 §22-25/§64 -- Payment Method report rebuilt into THREE independently-gated sections: `rows` (Sales, grouped by payment_method_id+collection_channel_id PAIR with exact NULL semantics, sales.view), `refund_rows` (Actual Refund Cash from sales_return_refund_events/_reversals, grouped by refund_method_id with collection_channel_id always NULL, returns.view), `settlement_rows` (bank settlement movements-ledger restricted to route_kind=payment_collection only, never double-counting COD carrier routes, settlements.view + settlements.view_financials for amounts). Never blends the three into one profit figure (§22). A viewer missing all three domain permissions still gets a valid envelope (§25). SECURITY DEFINER.';

revoke execute on function public.get_payment_methods_report(date, date, uuid[], text, text, integer, integer, uuid, uuid) from public;
grant execute on function public.get_payment_methods_report(date, date, uuid[], text, text, integer, integer, uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- get_collection_channels_report() (§27) — unchanged shape, export cap raise
-- only (500 -> 5000, §11-14/§60). Same signature as 0202, true CREATE OR
-- REPLACE (no DROP needed — parameter list identical).
-- ---------------------------------------------------------------------------
create or replace function public.get_collection_channels_report(
  p_date_from date,
  p_date_to date,
  p_store_ids uuid[] default null,
  p_search text default null,
  p_sort text default 'revenue_desc',
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
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 5000);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_result jsonb;
begin
  if v_actor is null or not public.has_permission('reports.view') or not public.has_permission('sales.view') then
    raise exception 'ليست لديك صلاحية عرض تقرير قنوات التحصيل' using errcode = 'P0001';
  end if;
  perform public._report_validate_date_range(p_date_from, p_date_to);
  v_can_profit := public.has_permission('sales.view_profit');
  v_stores := public._report_resolve_store_filter(v_actor, p_store_ids);

  with matched as (
    select so.id, so.collection_channel_id, so.subtotal, so.gross_profit, so.payment_fee_amount, so.net_sales_profit
    from public.sales_orders so
    where so.sale_date between p_date_from and p_date_to
      and so.store_id = any (v_stores)
  ),
  grouped as (
    select collection_channel_id,
      count(*) as orders_count,
      coalesce(sum(subtotal), 0) as revenue,
      coalesce(sum(gross_profit), 0) as gross_profit,
      coalesce(sum(payment_fee_amount), 0) as payment_fees,
      coalesce(sum(net_sales_profit), 0) as net_sales_profit
    from matched
    group by collection_channel_id
  ),
  labelled as (
    select g.*, ch.name_ar as collection_channel_name, ch.key as collection_channel_key
    from grouped g
    join public.collection_channels ch on ch.id = g.collection_channel_id
    where p_search is null or btrim(p_search) = '' or ch.name_ar ilike '%' || btrim(p_search) || '%' or ch.key ilike '%' || btrim(p_search) || '%'
  ),
  summary as (
    select
      count(*) as collection_channels_count,
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
      case when p_sort = 'orders_asc' then orders_count end asc,
      revenue desc, collection_channel_name asc
    limit v_limit offset v_offset
  )
  select jsonb_build_object(
    'total_count', (select collection_channels_count from summary),
    'limit', v_limit, 'offset', v_offset,
    'summary', jsonb_build_object(
      'collection_channels_count', (select collection_channels_count from summary),
      'orders_count', (select orders_count from summary),
      'revenue', (select revenue::text from summary)
    ) || (case when v_can_profit then jsonb_build_object(
      'gross_profit', (select gross_profit::text from summary),
      'payment_fees', (select payment_fees::text from summary),
      'net_sales_profit', (select net_sales_profit::text from summary)
    ) else '{}'::jsonb end),
    'rows', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'collection_channel_id', paged.collection_channel_id, 'collection_channel_name', paged.collection_channel_name, 'collection_channel_key', paged.collection_channel_key,
        'orders_count', paged.orders_count, 'revenue', paged.revenue::text
      ) || (case when v_can_profit then jsonb_build_object(
        'gross_profit', paged.gross_profit::text, 'payment_fees', paged.payment_fees::text, 'net_sales_profit', paged.net_sales_profit::text
      ) else '{}'::jsonb end) order by paged.revenue desc), '[]'::jsonb)
      from paged
    )
  ) into v_result;

  return v_result;
end;
$$;

comment on function public.get_collection_channels_report(date, date, uuid[], text, text, integer, integer) is
  'Phase 8 §27/§39/§45/§63; Patch 8.1 §60 -- collection channel ranking over sales_orders grouped by collection_channel_id, current master-data label (descriptive-only, §50). Profit fields require sales.view_profit. Export row cap raised 500->5000. Requires reports.view + sales.view. SECURITY DEFINER.';

revoke execute on function public.get_collection_channels_report(date, date, uuid[], text, text, integer, integer) from public;
grant execute on function public.get_collection_channels_report(date, date, uuid[], text, text, integer, integer) to authenticated;

commit;
