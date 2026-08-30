-- ============================================================================
-- Phase 8 — Integrity Patch 8.1 (0205)
-- Dashboard Financial Privacy Matrix (§1-3), Trend Bucket Range Clipping
-- (§9-10, §59), and the Canonical Shipping Profit Movement Adapter with
-- Event-Date dashboard/trend reporting (§4-8, §58).
-- ============================================================================
-- FREEZE: migrations 0001-0204 are UNTOUCHED. Every fix below is a
-- CREATE OR REPLACE of an existing function signature (get_dashboard_summary,
-- get_dashboard_trends — same (date,date,uuid[]) / (date,date,uuid[],text)
-- signatures) or a DROP+CREATE of report_date_buckets (its OUTPUT COLUMN SET
-- changes, which Postgres does not allow via a bare CREATE OR REPLACE — §0
-- explicitly sanctions "DROP old signature + CREATE عند تغيير signature").
-- Nothing in 0001-0204 is edited. All new work starts at 0205+.
--
-- §1-3 CRITICAL FIX — Dashboard Financial Privacy Matrix:
--   0200's get_dashboard_summary()/get_dashboard_trends() gated Shipping's
--   actual_carrier_cost/net_shipping_result and Adjustments' direct_costs/
--   net_adjustments_result behind `dashboard.view_financials` ALONE. That
--   contradicts the ALREADY-CORRECT contract get_shipping_report() (0203)
--   and get_adjustments_report() (0203) themselves enforce for the exact
--   same figures at row level: `v_can_profit := has_permission(
--   'sales.view_profit')`. dashboard.view_financials is a DASHBOARD-SCOPE
--   gate (read: "may this actor see money on the Dashboard at all"), never a
--   substitute for a SOURCE-DOMAIN profit permission — an actor who can see
--   Settlements' bank reconciliation numbers must not, by that fact alone,
--   also see Shipping/Adjustments COST figures. customer_shipping_charges
--   (Shipping) and customer_charges (Adjustments) remain gated by
--   dashboard.view_financials ALONE — they are the customer-facing charge,
--   explicitly called out as operational-adjacent in the patch spec ("يمكن
--   إظهارها مع shipments.view/dashboard financial presentation إذا مناسب"),
--   unlike the carrier/direct COST and PROFIT figures beside them. This
--   mirrors get_shipping_report()/get_adjustments_report() exactly, where
--   customer_shipping_charge/customer_charge_effect are exposed
--   unconditionally (operational) while cost/profit fields require
--   sales.view_profit. Settlements is untouched — it never required
--   sales.view_profit and still does not (§1: "تظل مستقلة").
--
-- §9-10 CRITICAL FIX — Trend Bucket Range Leak: report_date_buckets()
--   anchors week/month buckets to their CALENDAR boundary (the Saturday
--   before p_date_from, or the 1st of p_date_from's month) for LABELING
--   purposes, but get_dashboard_trends() was aggregating using those same
--   anchored bucket_start/bucket_end values as the actual data predicate —
--   so a Custom Range starting mid-week/mid-month silently pulled in
--   activity from BEFORE p_date_from. report_date_buckets() now ALSO
--   returns effective_start/effective_end = the bucket's own anchor
--   clamped into [p_date_from, p_date_to]; every aggregation CTE in
--   get_dashboard_trends() now filters on effective_start/effective_end
--   while bucket_start/bucket_end/bucket_label remain exactly as before for
--   display (the calendar anchor is still what a user expects a "week"/
--   "month" label to read as).
--
-- §4-8, §58 CRITICAL FIX — Shipping Profit Movement Adapter: Shipping had
--   ONE basis (shipments.shipment_date + CURRENT cached actual_carrier_cost)
--   feeding BOTH the row-level "Current Effective" report AND the Dashboard/
--   Management movements aggregate — violating §84/§85 (a July shipment
--   whose actual cost is corrected in August must show its July P/L as it
--   stood in July, with the correction landing in August, never silently
--   rewriting July). shipment_financial_events (0116) is the canonical,
--   append-only, per-event-dated ledger this project already has for
--   exactly this domain (actual_cost_recorded/actual_cost_correction/
--   customer_charge_correction, each carrying its own business_date) — this
--   migration adds _report_shipping_profit_movements(), an internal
--   table-returning adapter that walks a shipment's initial recognition
--   (at shipment_date) plus every later financial-event correction (at that
--   event's own business_date), computing each movement's delta against the
--   immediately-preceding cost/charge basis (deterministic ordering:
--   business_date, created_at, id — ties broken the same way 0130/0131's
--   existing shipment-event-chronology logic already breaks them).
--   get_dashboard_summary()/get_dashboard_trends() now source Shipping's
--   money figures from this movements ledger instead of the shipment
--   cohort-by-shipment_date cache. get_shipping_report() itself (the
--   row-level Current Effective view most users actually browse) is
--   deliberately UNCHANGED here — it gets its own explicit dual-basis
--   upgrade in 0206, which also raises its export row cap (§60/§11-14).
--   Field naming (§8): the movements ledger below never calls a value
--   "actual_carrier_cost" — that name is reserved for the shipment's TRUE
--   current recorded cost (Current Effective basis only). Movement rows use
--   carrier_cost_effect/net_shipping_effect throughout.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- Part A (§9/§10/§59) — report_date_buckets() gains effective_start/
-- effective_end. DROP+CREATE: the output column set changes.
-- ---------------------------------------------------------------------------
drop function if exists public.report_date_buckets(date, date, text);

create function public.report_date_buckets(p_date_from date, p_date_to date, p_granularity text default null)
returns table (bucket_start date, bucket_end date, bucket_label text, effective_start date, effective_end date)
language plpgsql
immutable
as $$
declare
  v_gran text := coalesce(p_granularity, public.report_trend_granularity(p_date_from, p_date_to));
  v_start date;
begin
  if p_date_from is null or p_date_to is null then
    raise exception 'date_from/date_to مطلوبة' using errcode = 'P0001';
  end if;
  if p_date_from > p_date_to then
    raise exception 'date_from يجب أن يكون قبل أو يساوي date_to' using errcode = 'P0001';
  end if;
  if v_gran not in ('day', 'week', 'month') then
    raise exception 'granularity غير صالحة: % (المسموح: day/week/month)', v_gran using errcode = 'P0001';
  end if;

  if v_gran = 'day' then
    return query
      select gs::date, gs::date, to_char(gs, 'YYYY-MM-DD'),
        greatest(gs::date, p_date_from), least(gs::date, p_date_to)
      from generate_series(p_date_from::timestamp, p_date_to::timestamp, interval '1 day') gs;
  elsif v_gran = 'week' then
    v_start := public.riyadh_week_start(p_date_from);
    return query
      select gs::date, least((gs::date + 6), p_date_to), to_char(gs, 'YYYY-MM-DD'),
        greatest(gs::date, p_date_from), least((gs::date + 6), p_date_to)
      from generate_series(v_start::timestamp, p_date_to::timestamp, interval '7 days') gs;
  else
    v_start := date_trunc('month', p_date_from)::date;
    return query
      select gs::date, least((gs + interval '1 month' - interval '1 day')::date, p_date_to), to_char(gs, 'YYYY-MM'),
        greatest(gs::date, p_date_from), least((gs + interval '1 month' - interval '1 day')::date, p_date_to)
      from generate_series(v_start::timestamp, p_date_to::timestamp, interval '1 month') gs;
  end if;
end;
$$;

comment on function public.report_date_buckets(date, date, text) is
  'Phase 8 §19/§73; Patch 8.1 §9/§10/§59 — zero-filled trend buckets for [date_from, date_to]. bucket_start/bucket_end/bucket_label remain the calendar-anchored label (e.g. the Saturday starting a week, even when before date_from) for DISPLAY. effective_start/effective_end are that same bucket clamped into [date_from, date_to] — every caller MUST filter its data predicate on effective_start/effective_end, never bucket_start/bucket_end, or activity before date_from / after date_to leaks into the first/last bucket (Patch 8.1 §9 CRITICAL finding).';

revoke execute on function public.report_date_buckets(date, date, text) from public;
grant execute on function public.report_date_buckets(date, date, text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Part B (§4-8, §58) — _report_shipping_profit_movements(): canonical
-- shipping profit movements ledger, one row per financial event (initial
-- recognition + every actual_cost_recorded/actual_cost_correction/
-- customer_charge_correction), each dated at its OWN business_date.
-- ---------------------------------------------------------------------------
create or replace function public._report_shipping_profit_movements(p_date_from date, p_date_to date, p_stores uuid[])
returns table (
  shipment_id uuid,
  movement_date date,
  movement_type text,
  customer_charge_effect numeric,
  carrier_cost_effect numeric,
  net_shipping_effect numeric
)
language plpgsql
stable
as $$
begin
  return query
  with scoped_shipments as (
    select sh.id, sh.shipment_date, sh.customer_shipping_charge, sh.expected_carrier_cost, sh.store_id
    from public.shipments sh
    where sh.store_id = any (p_stores)
  ),
  -- Every event, in this shipment's own deterministic chronology
  -- (business_date, created_at, id — same tie-break convention as 0130/0131).
  events_ordered as (
    select
      e.shipment_id, e.event_type, e.amount, e.business_date, e.created_at, e.id,
      row_number() over (partition by e.shipment_id order by e.business_date, e.created_at, e.id) as rn
    from public.shipment_financial_events e
    join scoped_shipments ss on ss.id = e.shipment_id
  ),
  -- Part A of §5: the Initial movement, at shipment_date, is the shipment's
  -- provisional Expected P/L the moment it was created — original customer
  -- charge minus EXPECTED carrier cost (never the eventual actual cost,
  -- which may not exist yet and, even once it does, is its own separate
  -- dated movement below).
  initial_movement as (
    select
      ss.id as shipment_id, ss.shipment_date as movement_date, 'initial'::text as movement_type,
      ss.customer_shipping_charge as customer_charge_effect,
      ss.expected_carrier_cost as carrier_cost_effect,
      (ss.customer_shipping_charge - ss.expected_carrier_cost) as net_shipping_effect
    from scoped_shipments ss
  ),
  -- Parts B/C of §5: every actual_cost_recorded/actual_cost_correction event
  -- carries a carrier_cost_effect = its own amount MINUS the immediately
  -- preceding cost basis (expected_carrier_cost for the FIRST such event on
  -- a shipment, else the previous actual_cost_recorded/_correction amount —
  -- deterministic via the row_number() chronology above). net_shipping_effect
  -- is the negation (a cost increase reduces the net result by the same
  -- amount) — matches §5's worked example exactly (expected=20, actual=25 ->
  -- cost effect +5, net effect -5).
  cost_events as (
    select
      eo.shipment_id, eo.business_date as movement_date, eo.event_type as movement_type,
      null::numeric as customer_charge_effect,
      (eo.amount - coalesce(
        (select eo2.amount from events_ordered eo2
         where eo2.shipment_id = eo.shipment_id and eo2.event_type in ('actual_cost_recorded', 'actual_cost_correction')
           and eo2.rn < eo.rn
         order by eo2.rn desc limit 1),
        (select ss2.expected_carrier_cost from scoped_shipments ss2 where ss2.id = eo.shipment_id)
      )) as carrier_cost_effect,
      -(eo.amount - coalesce(
        (select eo2.amount from events_ordered eo2
         where eo2.shipment_id = eo.shipment_id and eo2.event_type in ('actual_cost_recorded', 'actual_cost_correction')
           and eo2.rn < eo.rn
         order by eo2.rn desc limit 1),
        (select ss2.expected_carrier_cost from scoped_shipments ss2 where ss2.id = eo.shipment_id)
      )) as net_shipping_effect
    from events_ordered eo
    where eo.event_type in ('actual_cost_recorded', 'actual_cost_correction')
  ),
  -- Part D of §5: customer_charge_correction — charge_effect = new amount
  -- minus the immediately preceding effective charge (previous
  -- customer_charge_correction amount, or the original shipment charge if
  -- this is the first correction). net_shipping_effect = the SAME delta
  -- (a charge increase raises the net result by the same amount, unlike a
  -- cost increase).
  charge_events as (
    select
      eo.shipment_id, eo.business_date as movement_date, eo.event_type as movement_type,
      (eo.amount - coalesce(
        (select eo2.amount from events_ordered eo2
         where eo2.shipment_id = eo.shipment_id and eo2.event_type = 'customer_charge_correction'
           and eo2.rn < eo.rn
         order by eo2.rn desc limit 1),
        (select ss2.customer_shipping_charge from scoped_shipments ss2 where ss2.id = eo.shipment_id)
      )) as customer_charge_effect,
      null::numeric as carrier_cost_effect,
      (eo.amount - coalesce(
        (select eo2.amount from events_ordered eo2
         where eo2.shipment_id = eo.shipment_id and eo2.event_type = 'customer_charge_correction'
           and eo2.rn < eo.rn
         order by eo2.rn desc limit 1),
        (select ss2.customer_shipping_charge from scoped_shipments ss2 where ss2.id = eo.shipment_id)
      )) as net_shipping_effect
    from events_ordered eo
    where eo.event_type = 'customer_charge_correction'
  ),
  all_movements as (
    select im.shipment_id, im.movement_date, im.movement_type, im.customer_charge_effect, im.carrier_cost_effect, im.net_shipping_effect from initial_movement im
    union all
    select ce.shipment_id, ce.movement_date, ce.movement_type, ce.customer_charge_effect, ce.carrier_cost_effect, ce.net_shipping_effect from cost_events ce
    union all
    select che.shipment_id, che.movement_date, che.movement_type, che.customer_charge_effect, che.carrier_cost_effect, che.net_shipping_effect from charge_events che
  )
  select am.shipment_id, am.movement_date, am.movement_type,
    coalesce(am.customer_charge_effect, 0), coalesce(am.carrier_cost_effect, 0), am.net_shipping_effect
  from all_movements am
  where am.movement_date between p_date_from and p_date_to;
end;
$$;

comment on function public._report_shipping_profit_movements(date, date, uuid[]) is
  'Patch 8.1 §4-8/§58 (internal) — canonical Shipping profit MOVEMENTS ledger: one ''initial'' row per shipment at shipment_date (customer_shipping_charge - expected_carrier_cost), plus one row per shipment_financial_events entry at ITS OWN business_date (actual_cost_recorded/actual_cost_correction: carrier_cost_effect/net_shipping_effect = delta against the immediately-preceding cost basis; customer_charge_correction: delta against the immediately-preceding charge basis). Deterministic chronology (business_date, created_at, id). Used by get_dashboard_summary()/get_dashboard_trends() (this migration) and get_shipping_report()''s movements_during_period basis (0206). Never call any of these fields "actual_carrier_cost" downstream (§8) — that name is reserved for the Current Effective basis. Not directly callable (revoked from public, no explicit grant).';

revoke execute on function public._report_shipping_profit_movements(date, date, uuid[]) from public;

-- ---------------------------------------------------------------------------
-- Part C (§1-3, §4-8) — get_dashboard_summary(): privacy matrix fix +
-- shipping now sourced from _report_shipping_profit_movements() instead of
-- the shipment cohort-by-shipment_date cache.
-- ---------------------------------------------------------------------------
create or replace function public.get_dashboard_summary(
  p_date_from date,
  p_date_to date,
  p_store_ids uuid[] default null
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
  v_can_sales_profit boolean;
  v_can_returns boolean;
  v_can_shipments boolean;
  v_can_adjustments boolean;
  v_can_settlements boolean;
  v_can_settlements_financials boolean;
  v_can_financials boolean;
  v_stores uuid[];
  v_prev_from date;
  v_prev_to date;
  v_raw jsonb;
  v_c jsonb;
  v_p jsonb;
  v_result jsonb;
  v_open_day boolean;
  -- current-period derived numerics
  v_cur_sales_revenue numeric; v_cur_gross_profit numeric; v_cur_payment_fees numeric; v_cur_net_sales_profit_original numeric;
  v_cur_orders_count numeric;
  v_cur_returns_count numeric; v_cur_return_revenue_reversal numeric; v_cur_return_net_profit_reversal numeric; v_cur_return_payment_fee_reversal numeric;
  v_cur_return_revenue_reversal_undo numeric; v_cur_return_net_profit_reversal_undo numeric; v_cur_return_payment_fee_reversal_undo numeric;
  v_cur_return_financial_impact numeric; v_cur_effective_net_sales_profit numeric;
  v_cur_refund_cash_issued numeric; v_cur_refund_cash_reversed numeric; v_cur_actual_refunded_cash numeric;
  v_cur_shipments_count numeric; v_cur_shipping_customer_charges numeric; v_cur_shipping_carrier_cost_effect numeric; v_cur_net_shipping_result numeric;
  v_cur_adjustments_count numeric; v_cur_adj_customer_charge numeric; v_cur_adj_direct_cost numeric; v_cur_adj_payment_fee numeric; v_cur_adj_gross_profit numeric; v_cur_adj_net_profit numeric;
  v_cur_adj_customer_charge_reversal numeric; v_cur_adj_direct_cost_reversal numeric; v_cur_adj_payment_fee_reversal numeric; v_cur_adj_gross_profit_reversal numeric; v_cur_adj_net_profit_reversal numeric;
  v_cur_net_adjustments_result numeric; v_cur_net_operating_return numeric;
  v_cur_settlement_batches_count numeric; v_cur_settlement_expected numeric; v_cur_settlement_actual numeric; v_cur_settlement_variance numeric;
  v_cur_settlement_cancelled_count numeric; v_cur_settlement_variance_count numeric;
  -- previous-period derived numerics (same shape)
  v_prev_sales_revenue numeric; v_prev_gross_profit numeric; v_prev_payment_fees numeric; v_prev_net_sales_profit_original numeric;
  v_prev_orders_count numeric;
  v_prev_returns_count numeric; v_prev_return_revenue_reversal numeric; v_prev_return_net_profit_reversal numeric; v_prev_return_payment_fee_reversal numeric;
  v_prev_return_revenue_reversal_undo numeric; v_prev_return_net_profit_reversal_undo numeric; v_prev_return_payment_fee_reversal_undo numeric;
  v_prev_return_financial_impact numeric; v_prev_effective_net_sales_profit numeric;
  v_prev_refund_cash_issued numeric; v_prev_refund_cash_reversed numeric; v_prev_actual_refunded_cash numeric;
  v_prev_shipments_count numeric; v_prev_shipping_customer_charges numeric; v_prev_shipping_carrier_cost_effect numeric; v_prev_net_shipping_result numeric;
  v_prev_adjustments_count numeric; v_prev_adj_customer_charge numeric; v_prev_adj_direct_cost numeric; v_prev_adj_payment_fee numeric; v_prev_adj_gross_profit numeric; v_prev_adj_net_profit numeric;
  v_prev_adj_customer_charge_reversal numeric; v_prev_adj_direct_cost_reversal numeric; v_prev_adj_payment_fee_reversal numeric; v_prev_adj_gross_profit_reversal numeric; v_prev_adj_net_profit_reversal numeric;
  v_prev_net_adjustments_result numeric; v_prev_net_operating_return numeric;
  v_prev_settlement_batches_count numeric; v_prev_settlement_expected numeric; v_prev_settlement_actual numeric; v_prev_settlement_variance numeric;
  v_prev_settlement_cancelled_count numeric; v_prev_settlement_variance_count numeric;
begin
  if v_actor is null or not public.has_permission('dashboard.view') then
    raise exception 'ليست لديك صلاحية عرض لوحة التحكم' using errcode = 'P0001';
  end if;

  perform public._report_validate_date_range(p_date_from, p_date_to);

  v_can_financials := public.has_permission('dashboard.view_financials');
  v_can_sales := public.has_permission('sales.view');
  v_can_sales_profit := v_can_sales and public.has_permission('sales.view_profit');
  v_can_returns := public.has_permission('returns.view');
  v_can_shipments := public.has_permission('shipments.view');
  v_can_adjustments := public.has_permission('adjustments.view');
  v_can_settlements := public.has_permission('settlements.view');
  v_can_settlements_financials := v_can_settlements and public.has_permission('settlements.view_financials');

  v_stores := public._report_resolve_store_filter(v_actor, p_store_ids);
  select prev_date_from, prev_date_to into v_prev_from, v_prev_to from public.report_previous_period(p_date_from, p_date_to);

  -- =========================================================================
  -- ONE atomic data-fetch query: both periods, every domain, raw numbers.
  -- Shipping now sources from _report_shipping_profit_movements() (§4-8) —
  -- an event-dated movements ledger — instead of shipments.shipment_date +
  -- the shipment's CURRENT cached cost.
  -- =========================================================================
  with periods (label, d_from, d_to) as (
    values ('current', p_date_from, p_date_to), ('previous', v_prev_from, v_prev_to)
  ),
  sales_cte as (
    select p.label,
      count(so.id) as orders_count,
      coalesce(sum(so.subtotal), 0) as sales_revenue,
      coalesce(sum(so.gross_profit), 0) as sales_gross_profit,
      coalesce(sum(so.payment_fee_amount), 0) as sales_payment_fees,
      coalesce(sum(so.net_sales_profit), 0) as net_sales_profit_original
    from periods p
    left join public.sales_orders so
      on so.sale_date between p.d_from and p.d_to and so.store_id = any (v_stores)
    group by p.label
  ),
  returns_appr_cte as (
    select p.label,
      count(sr.id) as returns_count,
      coalesce(sum(sr.sales_revenue_reversal_amount), 0) as revenue_reversal,
      coalesce(sum(sr.net_sales_profit_adjustment), 0) as net_profit_reversal,
      coalesce(sum(sr.payment_fee_reversal_amount), 0) as payment_fee_reversal
    from periods p
    left join public.sales_returns sr
      on sr.return_date between p.d_from and p.d_to
      and sr.status in ('approved', 'reversed')
      and sr.processed_store_id = any (v_stores)
    group by p.label
  ),
  returns_undo_cte as (
    select p.label,
      coalesce(sum(sr.sales_revenue_reversal_amount), 0) as revenue_reversal_undo,
      coalesce(sum(sr.net_sales_profit_adjustment), 0) as net_profit_reversal_undo,
      coalesce(sum(sr.payment_fee_reversal_amount), 0) as payment_fee_reversal_undo
    from periods p
    left join public.sales_returns sr
      on sr.reversal_business_date between p.d_from and p.d_to
      and sr.status = 'reversed'
      and sr.processed_store_id = any (v_stores)
    group by p.label
  ),
  refund_cte as (
    select p.label, coalesce(sum(e.amount), 0) as refund_cash_issued
    from periods p
    left join (
      public.sales_return_refund_events e
      join public.sales_returns sr2 on sr2.id = e.sales_return_id and sr2.processed_store_id = any (v_stores)
    ) on e.refund_business_date between p.d_from and p.d_to
    group by p.label
  ),
  refund_undo_cte as (
    select p.label, coalesce(sum(e.amount), 0) as refund_cash_reversed
    from periods p
    left join (
      public.sales_return_refund_event_reversals rev
      join public.sales_return_refund_events e on e.id = rev.refund_event_id
      join public.sales_returns sr3 on sr3.id = e.sales_return_id and sr3.processed_store_id = any (v_stores)
    ) on rev.reversal_business_date between p.d_from and p.d_to
    group by p.label
  ),
  -- §4-8: shipping movements ledger, event-dated (replaces the old
  -- shipments-cohort-by-shipment_date CTE).
  shipping_movements_cte as (
    select p.label,
      count(*) filter (where m.movement_type = 'initial') as shipments_count,
      coalesce(sum(m.customer_charge_effect), 0) as customer_charges,
      coalesce(sum(m.carrier_cost_effect), 0) as carrier_cost_effect,
      coalesce(sum(m.net_shipping_effect), 0) as net_shipping_result
    from periods p
    left join public._report_shipping_profit_movements(p.d_from, p.d_to, v_stores) m on true
    group by p.label
  ),
  adj_appr_cte as (
    select p.label,
      count(a.id) as adjustments_count,
      coalesce(sum(a.customer_charge), 0) as customer_charge,
      coalesce(sum(a.direct_cost), 0) as direct_cost,
      coalesce(sum(a.payment_fee_amount), 0) as payment_fee,
      coalesce(sum(a.gross_adjustment_profit), 0) as gross_profit,
      coalesce(sum(a.net_adjustment_profit), 0) as net_profit
    from periods p
    left join public.sales_order_adjustments a
      on a.adjustment_date between p.d_from and p.d_to
      and a.status = 'approved'
      and a.processing_store_id = any (v_stores)
      and exists (select 1 from public.sales_orders so2 where so2.id = a.sales_order_id and so2.store_id = any (v_stores))
    group by p.label
  ),
  adj_rev_cte as (
    select p.label,
      coalesce(sum(r.customer_charge_reversal_amount), 0) as customer_charge_reversal,
      coalesce(sum(r.direct_cost_reversal_amount), 0) as direct_cost_reversal,
      coalesce(sum(r.payment_fee_reversal_amount), 0) as payment_fee_reversal,
      coalesce(sum(r.gross_profit_reversal_amount), 0) as gross_profit_reversal,
      coalesce(sum(r.net_profit_reversal_amount), 0) as net_profit_reversal
    from periods p
    left join (
      public.sales_order_adjustment_reversals r
      join public.sales_order_adjustments a2 on a2.id = r.sales_order_adjustment_id
        and a2.processing_store_id = any (v_stores)
        and exists (select 1 from public.sales_orders so3 where so3.id = a2.sales_order_id and so3.store_id = any (v_stores))
    ) on r.reversal_business_date between p.d_from and p.d_to
    group by p.label
  ),
  settle_batch_scope as (
    select b.id, b.status, b.settlement_date, b.expected_bank_settlement,
      exists (select 1 from public.settlement_batch_cancellations c where c.settlement_batch_id = b.id) as is_cancelled
    from public.settlement_batches b
    where public._report_settlement_batch_in_store_scope(b.id, v_stores)
  ),
  settle_batch_eff as (
    select sbs.*,
      coalesce((select sum(e.amount) from public.settlement_bank_movement_events e where e.settlement_batch_id = sbs.id), 0)
        + coalesce((
            select sum(rv.amount_impact)
            from public.settlement_bank_movement_reversals rv
            join public.settlement_bank_movement_events e2 on e2.id = rv.bank_movement_event_id
            where e2.settlement_batch_id = sbs.id
          ), 0) as live_actual
    from settle_batch_scope sbs
  ),
  settle_badges_cte as (
    select p.label,
      count(b.id) as batches_count,
      count(*) filter (where b.is_cancelled) as cancelled_count,
      count(*) filter (where not b.is_cancelled and b.expected_bank_settlement is not null and b.live_actual - b.expected_bank_settlement <> 0) as variance_count
    from periods p
    left join settle_batch_eff b
      on b.settlement_date between p.d_from and p.d_to and b.status in ('finalized', 'reconciled')
    group by p.label
  ),
  settle_finalized_scoped as (
    select b.id, b.settlement_date, b.expected_bank_settlement
    from settle_batch_scope b
    where b.status in ('finalized', 'reconciled')
  ),
  settle_cancellations_scoped as (
    select sf.id, sf.expected_bank_settlement, cx.cancellation_business_date,
      coalesce((select sum(e.amount) from public.settlement_bank_movement_events e where e.settlement_batch_id = sf.id), 0)
        + coalesce((
            select sum(rv.amount_impact)
            from public.settlement_bank_movement_reversals rv
            join public.settlement_bank_movement_events e2 on e2.id = rv.bank_movement_event_id
            where e2.settlement_batch_id = sf.id
          ), 0) as live_actual_at_cancel
    from settle_finalized_scoped sf
    join public.settlement_batch_cancellations cx on cx.settlement_batch_id = sf.id
    where sf.expected_bank_settlement is not null
  ),
  settle_movements_scoped as (
    select e.settlement_batch_id, e.movement_business_date, e.amount
    from public.settlement_bank_movement_events e
    join settle_finalized_scoped sf on sf.id = e.settlement_batch_id
  ),
  settle_reversals_scoped as (
    select e.settlement_batch_id, rv.reversal_business_date, rv.amount_impact
    from public.settlement_bank_movement_reversals rv
    join public.settlement_bank_movement_events e on e.id = rv.bank_movement_event_id
    join settle_finalized_scoped sf on sf.id = e.settlement_batch_id
  ),
  settle_expected_cte as (
    select p.label, coalesce(sum(sf.expected_bank_settlement), 0) as expected_recognized
    from periods p
    left join settle_finalized_scoped sf on sf.settlement_date between p.d_from and p.d_to
    group by p.label
  ),
  settle_undo_cte as (
    select p.label,
      coalesce(sum(-sc.expected_bank_settlement), 0) as expected_undo,
      coalesce(sum(-sc.live_actual_at_cancel), 0) as actual_undo
    from periods p
    left join settle_cancellations_scoped sc on sc.cancellation_business_date between p.d_from and p.d_to
    group by p.label
  ),
  settle_actual_cte as (
    select p.label, coalesce(sum(sm.amount), 0) as actual_from_movements
    from periods p
    left join settle_movements_scoped sm on sm.movement_business_date between p.d_from and p.d_to
    group by p.label
  ),
  settle_reversal_cte as (
    select p.label, coalesce(sum(sr.amount_impact), 0) as actual_from_reversals
    from periods p
    left join settle_reversals_scoped sr on sr.reversal_business_date between p.d_from and p.d_to
    group by p.label
  ),
  settle_cte as (
    select
      badge.label,
      badge.batches_count, badge.cancelled_count, badge.variance_count,
      coalesce(ec.expected_recognized, 0) + coalesce(un.expected_undo, 0) as expected,
      coalesce(ac.actual_from_movements, 0) + coalesce(rc.actual_from_reversals, 0) + coalesce(un.actual_undo, 0) as actual,
      (coalesce(ac.actual_from_movements, 0) + coalesce(rc.actual_from_reversals, 0) + coalesce(un.actual_undo, 0))
        - (coalesce(ec.expected_recognized, 0) + coalesce(un.expected_undo, 0)) as variance
    from settle_badges_cte badge
    left join settle_expected_cte ec on ec.label = badge.label
    left join settle_undo_cte un on un.label = badge.label
    left join settle_actual_cte ac on ac.label = badge.label
    left join settle_reversal_cte rc on rc.label = badge.label
  ),
  combined as (
    select
      p.label,
      coalesce(s.orders_count, 0) as orders_count,
      coalesce(s.sales_revenue, 0) as sales_revenue,
      coalesce(s.sales_gross_profit, 0) as sales_gross_profit,
      coalesce(s.sales_payment_fees, 0) as sales_payment_fees,
      coalesce(s.net_sales_profit_original, 0) as net_sales_profit_original,
      coalesce(ra.returns_count, 0) as returns_count,
      coalesce(ra.revenue_reversal, 0) as return_revenue_reversal,
      coalesce(ra.net_profit_reversal, 0) as return_net_profit_reversal,
      coalesce(ra.payment_fee_reversal, 0) as return_payment_fee_reversal,
      coalesce(ru.revenue_reversal_undo, 0) as return_revenue_reversal_undo,
      coalesce(ru.net_profit_reversal_undo, 0) as return_net_profit_reversal_undo,
      coalesce(ru.payment_fee_reversal_undo, 0) as return_payment_fee_reversal_undo,
      coalesce(rf.refund_cash_issued, 0) as refund_cash_issued,
      coalesce(rfu.refund_cash_reversed, 0) as refund_cash_reversed,
      coalesce(sh.shipments_count, 0) as shipments_count,
      coalesce(sh.customer_charges, 0) as shipping_customer_charges,
      coalesce(sh.carrier_cost_effect, 0) as shipping_carrier_cost_effect,
      coalesce(sh.net_shipping_result, 0) as net_shipping_result,
      coalesce(aa.adjustments_count, 0) as adjustments_count,
      coalesce(aa.customer_charge, 0) as adj_customer_charge,
      coalesce(aa.direct_cost, 0) as adj_direct_cost,
      coalesce(aa.payment_fee, 0) as adj_payment_fee,
      coalesce(aa.gross_profit, 0) as adj_gross_profit,
      coalesce(aa.net_profit, 0) as adj_net_profit,
      coalesce(ar.customer_charge_reversal, 0) as adj_customer_charge_reversal,
      coalesce(ar.direct_cost_reversal, 0) as adj_direct_cost_reversal,
      coalesce(ar.payment_fee_reversal, 0) as adj_payment_fee_reversal,
      coalesce(ar.gross_profit_reversal, 0) as adj_gross_profit_reversal,
      coalesce(ar.net_profit_reversal, 0) as adj_net_profit_reversal,
      coalesce(st.batches_count, 0) as settlement_batches_count,
      coalesce(st.expected, 0) as settlement_expected,
      coalesce(st.actual, 0) as settlement_actual,
      coalesce(st.variance, 0) as settlement_variance,
      coalesce(st.cancelled_count, 0) as settlement_cancelled_count,
      coalesce(st.variance_count, 0) as settlement_variance_count
    from periods p
    left join sales_cte s on s.label = p.label
    left join returns_appr_cte ra on ra.label = p.label
    left join returns_undo_cte ru on ru.label = p.label
    left join refund_cte rf on rf.label = p.label
    left join refund_undo_cte rfu on rfu.label = p.label
    left join shipping_movements_cte sh on sh.label = p.label
    left join adj_appr_cte aa on aa.label = p.label
    left join adj_rev_cte ar on ar.label = p.label
    left join settle_cte st on st.label = p.label
  )
  select jsonb_object_agg(combined.label, to_jsonb(combined) - 'label') into v_raw from combined;

  -- Open-business-day indicator (§69) -- operational, no financial data.
  select exists (
    select 1
    from generate_series(p_date_from, least(p_date_to, public.business_today()), interval '1 day') d(bd)
    cross join unnest(v_stores) s(store_id)
    where not exists (
      select 1 from public.daily_closings dc
      where dc.store_id = s.store_id and dc.business_date = d.bd::date
    )
  ) into v_open_day;

  v_c := coalesce(v_raw -> 'current', '{}'::jsonb);
  v_p := coalesce(v_raw -> 'previous', '{}'::jsonb);

  -- ---- current period derived numerics ----
  v_cur_orders_count := (v_c ->> 'orders_count')::numeric;
  v_cur_sales_revenue := (v_c ->> 'sales_revenue')::numeric;
  v_cur_gross_profit := (v_c ->> 'sales_gross_profit')::numeric;
  v_cur_payment_fees := (v_c ->> 'sales_payment_fees')::numeric;
  v_cur_net_sales_profit_original := (v_c ->> 'net_sales_profit_original')::numeric;
  v_cur_returns_count := (v_c ->> 'returns_count')::numeric;
  v_cur_return_revenue_reversal := (v_c ->> 'return_revenue_reversal')::numeric;
  v_cur_return_net_profit_reversal := (v_c ->> 'return_net_profit_reversal')::numeric;
  v_cur_return_payment_fee_reversal := (v_c ->> 'return_payment_fee_reversal')::numeric;
  v_cur_return_revenue_reversal_undo := (v_c ->> 'return_revenue_reversal_undo')::numeric;
  v_cur_return_net_profit_reversal_undo := (v_c ->> 'return_net_profit_reversal_undo')::numeric;
  v_cur_return_payment_fee_reversal_undo := (v_c ->> 'return_payment_fee_reversal_undo')::numeric;
  v_cur_return_financial_impact := v_cur_return_net_profit_reversal - v_cur_return_net_profit_reversal_undo;
  v_cur_effective_net_sales_profit := v_cur_net_sales_profit_original + v_cur_return_financial_impact;
  v_cur_refund_cash_issued := (v_c ->> 'refund_cash_issued')::numeric;
  v_cur_refund_cash_reversed := (v_c ->> 'refund_cash_reversed')::numeric;
  v_cur_actual_refunded_cash := v_cur_refund_cash_issued - v_cur_refund_cash_reversed;
  v_cur_shipments_count := (v_c ->> 'shipments_count')::numeric;
  v_cur_shipping_customer_charges := (v_c ->> 'shipping_customer_charges')::numeric;
  v_cur_shipping_carrier_cost_effect := (v_c ->> 'shipping_carrier_cost_effect')::numeric;
  v_cur_net_shipping_result := (v_c ->> 'net_shipping_result')::numeric;
  v_cur_adjustments_count := (v_c ->> 'adjustments_count')::numeric;
  v_cur_adj_customer_charge := (v_c ->> 'adj_customer_charge')::numeric;
  v_cur_adj_direct_cost := (v_c ->> 'adj_direct_cost')::numeric;
  v_cur_adj_payment_fee := (v_c ->> 'adj_payment_fee')::numeric;
  v_cur_adj_gross_profit := (v_c ->> 'adj_gross_profit')::numeric;
  v_cur_adj_net_profit := (v_c ->> 'adj_net_profit')::numeric;
  v_cur_adj_customer_charge_reversal := (v_c ->> 'adj_customer_charge_reversal')::numeric;
  v_cur_adj_direct_cost_reversal := (v_c ->> 'adj_direct_cost_reversal')::numeric;
  v_cur_adj_payment_fee_reversal := (v_c ->> 'adj_payment_fee_reversal')::numeric;
  v_cur_adj_gross_profit_reversal := (v_c ->> 'adj_gross_profit_reversal')::numeric;
  v_cur_adj_net_profit_reversal := (v_c ->> 'adj_net_profit_reversal')::numeric;
  v_cur_net_adjustments_result := v_cur_adj_net_profit + v_cur_adj_net_profit_reversal;
  v_cur_net_operating_return := v_cur_effective_net_sales_profit + v_cur_net_shipping_result + v_cur_net_adjustments_result;
  v_cur_settlement_batches_count := (v_c ->> 'settlement_batches_count')::numeric;
  v_cur_settlement_expected := (v_c ->> 'settlement_expected')::numeric;
  v_cur_settlement_actual := (v_c ->> 'settlement_actual')::numeric;
  v_cur_settlement_variance := (v_c ->> 'settlement_variance')::numeric;
  v_cur_settlement_cancelled_count := (v_c ->> 'settlement_cancelled_count')::numeric;
  v_cur_settlement_variance_count := (v_c ->> 'settlement_variance_count')::numeric;

  -- ---- previous period derived numerics (identical formulas) ----
  v_prev_orders_count := (v_p ->> 'orders_count')::numeric;
  v_prev_sales_revenue := (v_p ->> 'sales_revenue')::numeric;
  v_prev_gross_profit := (v_p ->> 'sales_gross_profit')::numeric;
  v_prev_payment_fees := (v_p ->> 'sales_payment_fees')::numeric;
  v_prev_net_sales_profit_original := (v_p ->> 'net_sales_profit_original')::numeric;
  v_prev_returns_count := (v_p ->> 'returns_count')::numeric;
  v_prev_return_revenue_reversal := (v_p ->> 'return_revenue_reversal')::numeric;
  v_prev_return_net_profit_reversal := (v_p ->> 'return_net_profit_reversal')::numeric;
  v_prev_return_payment_fee_reversal := (v_p ->> 'return_payment_fee_reversal')::numeric;
  v_prev_return_revenue_reversal_undo := (v_p ->> 'return_revenue_reversal_undo')::numeric;
  v_prev_return_net_profit_reversal_undo := (v_p ->> 'return_net_profit_reversal_undo')::numeric;
  v_prev_return_payment_fee_reversal_undo := (v_p ->> 'return_payment_fee_reversal_undo')::numeric;
  v_prev_return_financial_impact := v_prev_return_net_profit_reversal - v_prev_return_net_profit_reversal_undo;
  v_prev_effective_net_sales_profit := v_prev_net_sales_profit_original + v_prev_return_financial_impact;
  v_prev_refund_cash_issued := (v_p ->> 'refund_cash_issued')::numeric;
  v_prev_refund_cash_reversed := (v_p ->> 'refund_cash_reversed')::numeric;
  v_prev_actual_refunded_cash := v_prev_refund_cash_issued - v_prev_refund_cash_reversed;
  v_prev_shipments_count := (v_p ->> 'shipments_count')::numeric;
  v_prev_shipping_customer_charges := (v_p ->> 'shipping_customer_charges')::numeric;
  v_prev_shipping_carrier_cost_effect := (v_p ->> 'shipping_carrier_cost_effect')::numeric;
  v_prev_net_shipping_result := (v_p ->> 'net_shipping_result')::numeric;
  v_prev_adjustments_count := (v_p ->> 'adjustments_count')::numeric;
  v_prev_adj_customer_charge := (v_p ->> 'adj_customer_charge')::numeric;
  v_prev_adj_direct_cost := (v_p ->> 'adj_direct_cost')::numeric;
  v_prev_adj_payment_fee := (v_p ->> 'adj_payment_fee')::numeric;
  v_prev_adj_gross_profit := (v_p ->> 'adj_gross_profit')::numeric;
  v_prev_adj_net_profit := (v_p ->> 'adj_net_profit')::numeric;
  v_prev_adj_customer_charge_reversal := (v_p ->> 'adj_customer_charge_reversal')::numeric;
  v_prev_adj_direct_cost_reversal := (v_p ->> 'adj_direct_cost_reversal')::numeric;
  v_prev_adj_payment_fee_reversal := (v_p ->> 'adj_payment_fee_reversal')::numeric;
  v_prev_adj_gross_profit_reversal := (v_p ->> 'adj_gross_profit_reversal')::numeric;
  v_prev_adj_net_profit_reversal := (v_p ->> 'adj_net_profit_reversal')::numeric;
  v_prev_net_adjustments_result := v_prev_adj_net_profit + v_prev_adj_net_profit_reversal;
  v_prev_net_operating_return := v_prev_effective_net_sales_profit + v_prev_net_shipping_result + v_prev_net_adjustments_result;
  v_prev_settlement_batches_count := (v_p ->> 'settlement_batches_count')::numeric;
  v_prev_settlement_expected := (v_p ->> 'settlement_expected')::numeric;
  v_prev_settlement_actual := (v_p ->> 'settlement_actual')::numeric;
  v_prev_settlement_variance := (v_p ->> 'settlement_variance')::numeric;
  v_prev_settlement_cancelled_count := (v_p ->> 'settlement_cancelled_count')::numeric;
  v_prev_settlement_variance_count := (v_p ->> 'settlement_variance_count')::numeric;

  -- =========================================================================
  -- Assemble the redacted result. Base envelope (no financial data at all).
  -- =========================================================================
  v_result := jsonb_build_object(
    'date_from', p_date_from,
    'date_to', p_date_to,
    'previous_date_from', v_prev_from,
    'previous_date_to', v_prev_to,
    'store_ids', to_jsonb(v_stores),
    'basis', 'current_effective_impact_within_period',
    'contains_open_business_day', v_open_day
  );

  if v_can_sales then
    v_result := v_result || jsonb_build_object('sales', jsonb_build_object(
      'orders_count', v_cur_orders_count::int, 'previous_orders_count', v_prev_orders_count::int,
      'orders_count_change', (v_cur_orders_count - v_prev_orders_count)::int,
      'orders_count_pct_change', public.report_pct_change(v_cur_orders_count, v_prev_orders_count),
      'sales_revenue', v_cur_sales_revenue::text, 'previous_sales_revenue', v_prev_sales_revenue::text,
      'sales_revenue_change', (v_cur_sales_revenue - v_prev_sales_revenue)::text,
      'sales_revenue_pct_change', public.report_pct_change(v_cur_sales_revenue, v_prev_sales_revenue)
    ) || (case when v_can_sales_profit and v_can_financials then jsonb_build_object(
      'gross_profit', v_cur_gross_profit::text, 'previous_gross_profit', v_prev_gross_profit::text,
      'gross_profit_change', (v_cur_gross_profit - v_prev_gross_profit)::text,
      'gross_profit_pct_change', public.report_pct_change(v_cur_gross_profit, v_prev_gross_profit),
      'payment_fees', v_cur_payment_fees::text, 'previous_payment_fees', v_prev_payment_fees::text,
      'payment_fees_change', (v_cur_payment_fees - v_prev_payment_fees)::text,
      'payment_fees_pct_change', public.report_pct_change(v_cur_payment_fees, v_prev_payment_fees),
      'net_sales_profit_original', v_cur_net_sales_profit_original::text, 'previous_net_sales_profit_original', v_prev_net_sales_profit_original::text,
      'net_sales_profit_original_change', (v_cur_net_sales_profit_original - v_prev_net_sales_profit_original)::text,
      'net_sales_profit_original_pct_change', public.report_pct_change(v_cur_net_sales_profit_original, v_prev_net_sales_profit_original),
      'effective_net_sales_profit', v_cur_effective_net_sales_profit::text, 'previous_effective_net_sales_profit', v_prev_effective_net_sales_profit::text,
      'effective_net_sales_profit_change', (v_cur_effective_net_sales_profit - v_prev_effective_net_sales_profit)::text,
      'effective_net_sales_profit_pct_change', public.report_pct_change(v_cur_effective_net_sales_profit, v_prev_effective_net_sales_profit)
    ) else '{}'::jsonb end));
  end if;

  if v_can_returns then
    v_result := v_result || jsonb_build_object('returns', jsonb_build_object(
      'returns_count', v_cur_returns_count::int, 'previous_returns_count', v_prev_returns_count::int,
      'returns_count_change', (v_cur_returns_count - v_prev_returns_count)::int,
      'returns_count_pct_change', public.report_pct_change(v_cur_returns_count, v_prev_returns_count)
    ) || (case when v_can_financials then jsonb_build_object(
      'actual_refunded_cash', v_cur_actual_refunded_cash::text, 'previous_actual_refunded_cash', v_prev_actual_refunded_cash::text,
      'actual_refunded_cash_change', (v_cur_actual_refunded_cash - v_prev_actual_refunded_cash)::text,
      'actual_refunded_cash_pct_change', public.report_pct_change(v_cur_actual_refunded_cash, v_prev_actual_refunded_cash)
    ) else '{}'::jsonb end)
      || (case when v_can_sales_profit and v_can_financials then jsonb_build_object(
      'return_financial_impact', v_cur_return_financial_impact::text, 'previous_return_financial_impact', v_prev_return_financial_impact::text,
      'return_financial_impact_change', (v_cur_return_financial_impact - v_prev_return_financial_impact)::text,
      'return_financial_impact_pct_change', public.report_pct_change(v_cur_return_financial_impact, v_prev_return_financial_impact)
    ) else '{}'::jsonb end));
  end if;

  -- Patch 8.1 §1/§4-8: Shipping — customer_shipping_charges stays gated by
  -- dashboard.view_financials ALONE (operational/customer-facing charge,
  -- §1); carrier_cost_effect/net_shipping_result (the movements-basis
  -- replacement for the old "actual_carrier_cost"/net_shipping_result, §8:
  -- never call the movements figure "actual_carrier_cost") ADDITIONALLY
  -- require sales.view_profit, matching get_shipping_report()'s (0203)
  -- ALREADY-CORRECT row-level gate exactly.
  if v_can_shipments then
    v_result := v_result || jsonb_build_object('shipping', jsonb_build_object(
      'shipments_count', v_cur_shipments_count::int, 'previous_shipments_count', v_prev_shipments_count::int,
      'shipments_count_change', (v_cur_shipments_count - v_prev_shipments_count)::int,
      'shipments_count_pct_change', public.report_pct_change(v_cur_shipments_count, v_prev_shipments_count),
      'basis', 'movements_during_period'
    ) || (case when v_can_financials then jsonb_build_object(
      'customer_shipping_charges', v_cur_shipping_customer_charges::text, 'previous_customer_shipping_charges', v_prev_shipping_customer_charges::text,
      'customer_shipping_charges_change', (v_cur_shipping_customer_charges - v_prev_shipping_customer_charges)::text,
      'customer_shipping_charges_pct_change', public.report_pct_change(v_cur_shipping_customer_charges, v_prev_shipping_customer_charges)
    ) else '{}'::jsonb end)
      || (case when v_can_financials and v_can_sales_profit then jsonb_build_object(
      'carrier_cost_effect', v_cur_shipping_carrier_cost_effect::text, 'previous_carrier_cost_effect', v_prev_shipping_carrier_cost_effect::text,
      'carrier_cost_effect_change', (v_cur_shipping_carrier_cost_effect - v_prev_shipping_carrier_cost_effect)::text,
      'carrier_cost_effect_pct_change', public.report_pct_change(v_cur_shipping_carrier_cost_effect, v_prev_shipping_carrier_cost_effect),
      'net_shipping_result', v_cur_net_shipping_result::text, 'previous_net_shipping_result', v_prev_net_shipping_result::text,
      'net_shipping_result_change', (v_cur_net_shipping_result - v_prev_net_shipping_result)::text,
      'net_shipping_result_pct_change', public.report_pct_change(v_cur_net_shipping_result, v_prev_net_shipping_result)
    ) else '{}'::jsonb end));
  end if;

  -- Patch 8.1 §1: Adjustments — customer_charges stays gated by
  -- dashboard.view_financials ALONE (operational, §1); direct_costs/
  -- net_adjustments_result ADDITIONALLY require sales.view_profit, matching
  -- get_adjustments_report()'s (0203) ALREADY-CORRECT row-level gate.
  if v_can_adjustments then
    v_result := v_result || jsonb_build_object('adjustments', jsonb_build_object(
      'adjustments_count', v_cur_adjustments_count::int, 'previous_adjustments_count', v_prev_adjustments_count::int,
      'adjustments_count_change', (v_cur_adjustments_count - v_prev_adjustments_count)::int,
      'adjustments_count_pct_change', public.report_pct_change(v_cur_adjustments_count, v_prev_adjustments_count)
    ) || (case when v_can_financials then jsonb_build_object(
      'customer_charges', (v_cur_adj_customer_charge + v_cur_adj_customer_charge_reversal)::text,
      'previous_customer_charges', (v_prev_adj_customer_charge + v_prev_adj_customer_charge_reversal)::text
    ) else '{}'::jsonb end)
      || (case when v_can_financials and v_can_sales_profit then jsonb_build_object(
      'direct_costs', (v_cur_adj_direct_cost + v_cur_adj_direct_cost_reversal)::text,
      'previous_direct_costs', (v_prev_adj_direct_cost + v_prev_adj_direct_cost_reversal)::text,
      'net_adjustments_result', v_cur_net_adjustments_result::text, 'previous_net_adjustments_result', v_prev_net_adjustments_result::text,
      'net_adjustments_result_change', (v_cur_net_adjustments_result - v_prev_net_adjustments_result)::text,
      'net_adjustments_result_pct_change', public.report_pct_change(v_cur_net_adjustments_result, v_prev_net_adjustments_result)
    ) else '{}'::jsonb end));
  end if;

  if v_can_settlements then
    v_result := v_result || jsonb_build_object('settlements', jsonb_build_object(
      'batches_count', v_cur_settlement_batches_count::int, 'previous_batches_count', v_prev_settlement_batches_count::int,
      'cancelled_count', v_cur_settlement_cancelled_count::int
    ) || (case when v_can_settlements_financials and v_can_financials then jsonb_build_object(
      'variance_count', v_cur_settlement_variance_count::int,
      'expected', v_cur_settlement_expected::text, 'previous_expected', v_prev_settlement_expected::text,
      'expected_change', (v_cur_settlement_expected - v_prev_settlement_expected)::text,
      'expected_pct_change', public.report_pct_change(v_cur_settlement_expected, v_prev_settlement_expected),
      'actual', v_cur_settlement_actual::text, 'previous_actual', v_prev_settlement_actual::text,
      'actual_change', (v_cur_settlement_actual - v_prev_settlement_actual)::text,
      'actual_pct_change', public.report_pct_change(v_cur_settlement_actual, v_prev_settlement_actual),
      'variance', v_cur_settlement_variance::text, 'previous_variance', v_prev_settlement_variance::text,
      'variance_change', (v_cur_settlement_variance - v_prev_settlement_variance)::text
    ) else '{}'::jsonb end));
  end if;

  -- Net Operating Return (§13/§20/§81) -- cross-domain, requires ALL
  -- constituent domain financial permissions or is omitted entirely.
  -- (Already required v_can_sales_profit — unaffected by this patch.)
  if v_can_financials and v_can_sales_profit and v_can_shipments and v_can_adjustments then
    v_result := v_result || jsonb_build_object('net_operating_return', jsonb_build_object(
      'effective_net_sales_profit', v_cur_effective_net_sales_profit::text,
      'net_shipping_result', v_cur_net_shipping_result::text,
      'net_adjustments_result', v_cur_net_adjustments_result::text,
      'net_operating_return', v_cur_net_operating_return::text,
      'previous_net_operating_return', v_prev_net_operating_return::text,
      'net_operating_return_change', (v_cur_net_operating_return - v_prev_net_operating_return)::text,
      'net_operating_return_pct_change', public.report_pct_change(v_cur_net_operating_return, v_prev_net_operating_return),
      'formula', 'effective_net_sales_profit + net_shipping_result + net_adjustments_result = net_operating_return'
    ));
  end if;

  return v_result;
end;
$$;

comment on function public.get_dashboard_summary(date, date, uuid[]) is
  'Phase 8 §12/§13/§18/§20/§92/§93; Patch 8.1 §1-3/§4-8 — Executive Summary. Financial Privacy Matrix: Shipping carrier_cost_effect/net_shipping_result and Adjustments direct_costs/net_adjustments_result require dashboard.view_financials AND sales.view_profit (matching get_shipping_report()/get_adjustments_report()''s row-level gate exactly) — customer_shipping_charges/customer_charges (operational/customer-facing) remain gated by dashboard.view_financials alone. Shipping money now sourced from _report_shipping_profit_movements() (event-dated, §84/§85) instead of the shipment cohort-by-shipment_date cache. Settlements unaffected (never required sales.view_profit). net_operating_return unaffected (already required ALL four permissions). SECURITY DEFINER.';

revoke execute on function public.get_dashboard_summary(date, date, uuid[]) from public;
grant execute on function public.get_dashboard_summary(date, date, uuid[]) to authenticated;

-- ---------------------------------------------------------------------------
-- Part D (§1-3, §9-10, §4-8) — get_dashboard_trends(): privacy matrix fix +
-- effective_start/effective_end clipping + shipping movements ledger.
-- ---------------------------------------------------------------------------
create or replace function public.get_dashboard_trends(
  p_date_from date,
  p_date_to date,
  p_store_ids uuid[] default null,
  p_granularity text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_actor uuid := auth.uid();
  v_can_sales boolean; v_can_sales_profit boolean; v_can_returns boolean;
  v_can_shipments boolean; v_can_adjustments boolean; v_can_settlements boolean; v_can_settlements_financials boolean;
  v_can_financials boolean;
  v_stores uuid[];
  v_gran text;
  v_raw jsonb;
  v_result jsonb;
  v_bucket jsonb;
  v_out jsonb := '[]'::jsonb;
begin
  if v_actor is null or not public.has_permission('dashboard.view') then
    raise exception 'ليست لديك صلاحية عرض لوحة التحكم' using errcode = 'P0001';
  end if;

  perform public._report_validate_date_range(p_date_from, p_date_to);

  v_can_financials := public.has_permission('dashboard.view_financials');
  v_can_sales := public.has_permission('sales.view');
  v_can_sales_profit := v_can_sales and public.has_permission('sales.view_profit');
  v_can_returns := public.has_permission('returns.view');
  v_can_shipments := public.has_permission('shipments.view');
  v_can_adjustments := public.has_permission('adjustments.view');
  v_can_settlements := public.has_permission('settlements.view');
  v_can_settlements_financials := v_can_settlements and public.has_permission('settlements.view_financials');

  v_stores := public._report_resolve_store_filter(v_actor, p_store_ids);
  v_gran := coalesce(p_granularity, public.report_trend_granularity(p_date_from, p_date_to));

  with buckets as (
    select bucket_start, bucket_end, bucket_label, effective_start, effective_end
    from public.report_date_buckets(p_date_from, p_date_to, v_gran)
  ),
  sales_cte as (
    select b.bucket_start,
      count(so.id) as orders_count,
      coalesce(sum(so.subtotal), 0) as sales_revenue,
      coalesce(sum(so.net_sales_profit), 0) as net_sales_profit_original
    from buckets b
    left join public.sales_orders so
      on so.sale_date between b.effective_start and b.effective_end and so.store_id = any (v_stores)
    group by b.bucket_start
  ),
  returns_appr_cte as (
    select b.bucket_start,
      count(sr.id) as returns_count,
      coalesce(sum(sr.net_sales_profit_adjustment), 0) as net_profit_reversal
    from buckets b
    left join public.sales_returns sr
      on sr.return_date between b.effective_start and b.effective_end
      and sr.status in ('approved', 'reversed')
      and sr.processed_store_id = any (v_stores)
    group by b.bucket_start
  ),
  returns_undo_cte as (
    select b.bucket_start,
      coalesce(sum(sr.net_sales_profit_adjustment), 0) as net_profit_reversal_undo
    from buckets b
    left join public.sales_returns sr
      on sr.reversal_business_date between b.effective_start and b.effective_end
      and sr.status = 'reversed'
      and sr.processed_store_id = any (v_stores)
    group by b.bucket_start
  ),
  -- §4-8: shipping movements ledger, event-dated, clipped to effective_*.
  shipping_cte as (
    select b.bucket_start,
      coalesce(sum(m.net_shipping_effect), 0) as net_shipping_result
    from buckets b
    left join lateral public._report_shipping_profit_movements(b.effective_start, b.effective_end, v_stores) m on true
    group by b.bucket_start
  ),
  adj_appr_cte as (
    select b.bucket_start,
      coalesce(sum(a.net_adjustment_profit), 0) as net_profit
    from buckets b
    left join public.sales_order_adjustments a
      on a.adjustment_date between b.effective_start and b.effective_end
      and a.status = 'approved'
      and a.processing_store_id = any (v_stores)
      and exists (select 1 from public.sales_orders so2 where so2.id = a.sales_order_id and so2.store_id = any (v_stores))
    group by b.bucket_start
  ),
  adj_rev_cte as (
    select b.bucket_start,
      coalesce(sum(r.net_profit_reversal_amount), 0) as net_profit_reversal
    from buckets b
    left join (
      public.sales_order_adjustment_reversals r
      join public.sales_order_adjustments a2 on a2.id = r.sales_order_adjustment_id
        and a2.processing_store_id = any (v_stores)
        and exists (select 1 from public.sales_orders so3 where so3.id = a2.sales_order_id and so3.store_id = any (v_stores))
    ) on r.reversal_business_date between b.effective_start and b.effective_end
    group by b.bucket_start
  ),
  settle_batch_scope as (
    select bt.id, bt.status, bt.settlement_date, bt.expected_bank_settlement
    from public.settlement_batches bt
    where public._report_settlement_batch_in_store_scope(bt.id, v_stores) and bt.status in ('finalized', 'reconciled')
  ),
  settle_cancellations_scoped as (
    select sf.id, sf.expected_bank_settlement, cx.cancellation_business_date,
      coalesce((select sum(e.amount) from public.settlement_bank_movement_events e where e.settlement_batch_id = sf.id), 0)
        + coalesce((
            select sum(rv.amount_impact)
            from public.settlement_bank_movement_reversals rv
            join public.settlement_bank_movement_events e2 on e2.id = rv.bank_movement_event_id
            where e2.settlement_batch_id = sf.id
          ), 0) as live_actual_at_cancel
    from settle_batch_scope sf
    join public.settlement_batch_cancellations cx on cx.settlement_batch_id = sf.id
    where sf.expected_bank_settlement is not null
  ),
  settle_expected_cte as (
    select b.bucket_start, coalesce(sum(sf.expected_bank_settlement), 0) as expected_recognized
    from buckets b
    left join settle_batch_scope sf on sf.settlement_date between b.effective_start and b.effective_end
    group by b.bucket_start
  ),
  settle_undo_cte as (
    select b.bucket_start,
      coalesce(sum(-sc.expected_bank_settlement), 0) as expected_undo,
      coalesce(sum(-sc.live_actual_at_cancel), 0) as actual_undo
    from buckets b
    left join settle_cancellations_scoped sc on sc.cancellation_business_date between b.effective_start and b.effective_end
    group by b.bucket_start
  ),
  settle_movements_scoped as (
    select e.settlement_batch_id, e.movement_business_date, e.amount
    from public.settlement_bank_movement_events e
    join settle_batch_scope sf on sf.id = e.settlement_batch_id
  ),
  settle_reversals_scoped as (
    select e.settlement_batch_id, rv.reversal_business_date, rv.amount_impact
    from public.settlement_bank_movement_reversals rv
    join public.settlement_bank_movement_events e on e.id = rv.bank_movement_event_id
    join settle_batch_scope sf on sf.id = e.settlement_batch_id
  ),
  settle_actual_cte as (
    select b.bucket_start, coalesce(sum(sm.amount), 0) as actual_from_movements
    from buckets b
    left join settle_movements_scoped sm on sm.movement_business_date between b.effective_start and b.effective_end
    group by b.bucket_start
  ),
  settle_reversal_cte as (
    select b.bucket_start, coalesce(sum(sr2.amount_impact), 0) as actual_from_reversals
    from buckets b
    left join settle_reversals_scoped sr2 on sr2.reversal_business_date between b.effective_start and b.effective_end
    group by b.bucket_start
  ),
  combined as (
    select
      b.bucket_start, b.bucket_end, b.bucket_label,
      coalesce(s.orders_count, 0) as orders_count,
      coalesce(s.sales_revenue, 0) as sales_revenue,
      coalesce(s.net_sales_profit_original, 0) as net_sales_profit_original,
      coalesce(ra.returns_count, 0) as returns_count,
      coalesce(ra.net_profit_reversal, 0) as return_net_profit_reversal,
      coalesce(ru.net_profit_reversal_undo, 0) as return_net_profit_reversal_undo,
      coalesce(sh.net_shipping_result, 0) as net_shipping_result,
      coalesce(aa.net_profit, 0) as adj_net_profit,
      coalesce(ar.net_profit_reversal, 0) as adj_net_profit_reversal,
      coalesce(ec.expected_recognized, 0) + coalesce(un.expected_undo, 0) as settlement_expected,
      coalesce(ac.actual_from_movements, 0) + coalesce(rc.actual_from_reversals, 0) + coalesce(un.actual_undo, 0) as settlement_actual
    from buckets b
    left join sales_cte s on s.bucket_start = b.bucket_start
    left join returns_appr_cte ra on ra.bucket_start = b.bucket_start
    left join returns_undo_cte ru on ru.bucket_start = b.bucket_start
    left join shipping_cte sh on sh.bucket_start = b.bucket_start
    left join adj_appr_cte aa on aa.bucket_start = b.bucket_start
    left join adj_rev_cte ar on ar.bucket_start = b.bucket_start
    left join settle_expected_cte ec on ec.bucket_start = b.bucket_start
    left join settle_undo_cte un on un.bucket_start = b.bucket_start
    left join settle_actual_cte ac on ac.bucket_start = b.bucket_start
    left join settle_reversal_cte rc on rc.bucket_start = b.bucket_start
    order by b.bucket_start
  )
  select coalesce(jsonb_agg(to_jsonb(combined) order by combined.bucket_start), '[]'::jsonb) into v_raw from combined;

  for v_bucket in select * from jsonb_array_elements(v_raw)
  loop
    v_result := jsonb_build_object(
      'bucket_start', v_bucket ->> 'bucket_start',
      'bucket_end', v_bucket ->> 'bucket_end',
      'bucket_label', v_bucket ->> 'bucket_label'
    );

    if v_can_sales then
      v_result := v_result || jsonb_build_object(
        'orders_count', (v_bucket ->> 'orders_count')::int,
        'sales_revenue', (v_bucket ->> 'sales_revenue')::numeric::text
      );
      if v_can_sales_profit and v_can_financials then
        v_result := v_result || jsonb_build_object(
          'effective_net_sales_profit',
          ((v_bucket ->> 'net_sales_profit_original')::numeric
            + (v_bucket ->> 'return_net_profit_reversal')::numeric
            - (v_bucket ->> 'return_net_profit_reversal_undo')::numeric)::text
        );
      end if;
    end if;

    if v_can_returns then
      v_result := v_result || jsonb_build_object('returns_count', (v_bucket ->> 'returns_count')::int);
    end if;

    -- Patch 8.1 §2: shipping/adjustments net-result trend points ADDITIONALLY
    -- require sales.view_profit now (matching the Dashboard summary fix).
    if v_can_shipments and v_can_financials and v_can_sales_profit then
      v_result := v_result || jsonb_build_object('net_shipping_result', (v_bucket ->> 'net_shipping_result')::numeric::text);
    end if;

    if v_can_adjustments and v_can_financials and v_can_sales_profit then
      v_result := v_result || jsonb_build_object(
        'net_adjustments_result',
        ((v_bucket ->> 'adj_net_profit')::numeric + (v_bucket ->> 'adj_net_profit_reversal')::numeric)::text
      );
    end if;

    if v_can_settlements_financials and v_can_financials then
      v_result := v_result || jsonb_build_object(
        'settlement_variance',
        ((v_bucket ->> 'settlement_actual')::numeric - (v_bucket ->> 'settlement_expected')::numeric)::text
      );
    end if;

    if v_can_financials and v_can_sales_profit and v_can_shipments and v_can_adjustments then
      v_result := v_result || jsonb_build_object(
        'net_operating_return',
        (
          ((v_bucket ->> 'net_sales_profit_original')::numeric
            + (v_bucket ->> 'return_net_profit_reversal')::numeric
            - (v_bucket ->> 'return_net_profit_reversal_undo')::numeric)
          + (v_bucket ->> 'net_shipping_result')::numeric
          + ((v_bucket ->> 'adj_net_profit')::numeric + (v_bucket ->> 'adj_net_profit_reversal')::numeric)
        )::text
      );
    end if;

    v_out := v_out || jsonb_build_array(v_result);
  end loop;

  return jsonb_build_object('granularity', v_gran, 'date_from', p_date_from, 'date_to', p_date_to, 'buckets', v_out);
end;
$$;

comment on function public.get_dashboard_trends(date, date, uuid[], text) is
  'Phase 8 §19/§73/§39; Patch 8.1 §1-3/§4-8/§9-10 — zero-filled trend series. Data predicates now use report_date_buckets()''s effective_start/effective_end (clipped into [date_from,date_to]) instead of the calendar-anchored bucket_start/bucket_end, so a Custom Range starting mid-week/mid-month never pulls in activity from before date_from (§9 CRITICAL fix). Shipping now sourced from _report_shipping_profit_movements() (event-dated). net_shipping_result/net_adjustments_result trend points additionally require sales.view_profit (§1-3 privacy matrix, matching the Dashboard summary). Requires dashboard.view. SECURITY DEFINER.';

revoke execute on function public.get_dashboard_trends(date, date, uuid[], text) from public;
grant execute on function public.get_dashboard_trends(date, date, uuid[], text) to authenticated;

commit;
