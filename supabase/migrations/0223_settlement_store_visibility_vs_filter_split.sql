-- ============================================================================
-- Phase 8 — Final Closure Hotfix 8.1.2 — §16-18 CRITICAL:
-- Split settlement-batch VISIBILITY (is this actor even allowed to see this
-- batch at all) from an explicit store FILTER (does this batch match the
-- store(s) the actor specifically asked to narrow down to) -- these are two
-- different questions with two different correct semantics, and every
-- report/dashboard reader of settlement_batches was answering both of them
-- with the SAME single ALL-lines check, which is only correct for the first.
-- ============================================================================
-- Migrations 0001-0222 are FROZEN. This migration only ADDS 0223+.
--
-- §16 CRITICAL bug: _report_settlement_batch_in_store_scope(batch_id,
-- store_ids) (0200, fixed for zero-lines by 0220) checks that EVERY line's
-- primary_store_id (and secondary_store_id, when set) is within store_ids --
-- correct for "is this batch fully VISIBLE to an actor whose own visible
-- scope is store_ids" (a batch touching even ONE store outside what the
-- actor can see must never appear to them at all). But every call site fed
-- this SAME function the output of _report_resolve_store_filter(actor,
-- p_store_ids) (0199), which returns EITHER the actor's full visible scope
-- (no filter given) OR the actor's narrower, explicitly CHOSEN filter (a
-- filter given) -- and reused the ALL-lines check for BOTH cases alike.
--
-- That conflation is wrong for the second case. Worked example (§16's own
-- cross-store scenario): an actor whose visible scope is {Store A, Store B}
-- requests this report FILTERED to just Store A. A cross-store settlement
-- batch with one line at Store A and one line at Store B is fully VISIBLE to
-- this actor (both A and B are within their {A,B} scope) -- it must not be
-- silently hidden just because they narrowed the view to A. But the OLD code
-- passed the narrow filter {A} itself into the ALL-lines check, and since
-- the batch's OTHER line is at B (not in {A}), the check failed and the
-- batch vanished from the Store-A-filtered report entirely -- even though it
-- has real, visible activity at Store A. The correct semantic for "does this
-- batch match a Store-A filter" is "does AT LEAST ONE line touch Store A" --
-- an ANY-line check, never the ALL-lines one.
--
-- §17/§18 fix: two INDEPENDENT checks now, never conflated again:
--   1. VISIBILITY -- _report_settlement_batch_in_store_scope() (UNCHANGED,
--      0200/0220), now always called against the actor's TRUE, UNRESTRICTED
--      full scope (_report_actor_full_store_scope(), new below) -- NEVER
--      against whatever narrower filter they happened to choose this time.
--   2. FILTER MATCH -- _report_settlement_batch_matches_store_filter() (new
--      below), an ANY-line check, called against the RAW p_store_ids the
--      caller actually passed (NULL/empty = no filter = matches everything,
--      exactly mirroring _report_resolve_store_filter()'s own "no filter"
--      contract) -- only applied when the actor actually chose a filter.
-- A batch must pass BOTH to appear in a filtered result; it needs only #1 to
-- appear when no filter was given at all (in which case #2 is vacuously true
-- for every batch, by construction, since p_store_ids is NULL in that case).
--
-- _report_resolve_store_filter() itself is UNTOUCHED (still the single place
-- that validates a filter never names a store outside the actor's scope,
-- rejecting outright rather than silently narrowing -- §8, unaffected by
-- this fix) and v_stores (its return value) is STILL used, exactly as
-- before, for every OTHER (single-store-column) domain in these same
-- functions (sales_orders.store_id, shipments.store_id, etc.) -- this fix is
-- scoped ONLY to the settlement-batch dual-store (primary/secondary) case,
-- the one place a single store_ids array was ever being asked two different
-- questions at once.
--
-- Touches (body-only CREATE OR REPLACE, §0, no signature changes):
--   get_dashboard_summary() (0205), get_dashboard_trends() (0205),
--   get_settlements_report() (0218), get_cod_report() (0216).
-- get_payment_methods_report() (0217) ALSO calls
-- _report_settlement_batch_in_store_scope() and has the same bug, but is
-- deliberately NOT touched here -- it is already scheduled for a signature
-- change in this same hotfix (§31-33, a new p_payment_method_id parameter),
-- so its store-scope fix is combined into THAT DROP+CREATE migration
-- instead of touching the function's body twice in one hotfix (project
-- convention: touch each function once per hotfix wherever possible).
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- _report_actor_full_store_scope() (internal, §17) -- the actor's TRUE,
-- unrestricted visible store scope, independent of any filter they may have
-- chosen. Identical selection logic to what _report_resolve_store_filter()
-- (0199) already computes internally for its own "no filter" branch --
-- factored out here as its own callable so settlement-batch VISIBILITY can
-- be checked against it directly, without regard to the current filter.
-- ---------------------------------------------------------------------------
create or replace function public._report_actor_full_store_scope(p_actor uuid)
returns uuid[]
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(array_agg(sid), array[]::uuid[]) from public.user_visible_store_ids(p_actor) sid;
$$;

comment on function public._report_actor_full_store_scope(uuid) is
  'Hotfix 8.1.2 §16-18 (internal) -- the actor''s full, unrestricted visible store scope (user_visible_store_ids(), unaffected by any filter the actor may have chosen this call). Used ONLY for settlement-batch VISIBILITY checks (_report_settlement_batch_in_store_scope) -- never for a store FILTER match, which must instead use the caller''s own raw p_store_ids via _report_settlement_batch_matches_store_filter(). Not directly callable by authenticated.';

revoke execute on function public._report_actor_full_store_scope(uuid) from public;

-- ---------------------------------------------------------------------------
-- _report_settlement_batch_matches_store_filter() (internal, §16-18) -- ANY-
-- line match: does this batch touch at least one of the EXPLICITLY chosen
-- filter stores. NULL/empty p_store_ids (no filter chosen) is vacuously
-- TRUE for every batch -- mirrors _report_resolve_store_filter()'s own "no
-- filter = everything" contract exactly, so a caller that never applies a
-- filter sees no behavior change from this migration at all.
-- ---------------------------------------------------------------------------
create or replace function public._report_settlement_batch_matches_store_filter(p_settlement_batch_id uuid, p_store_ids uuid[])
returns boolean
language sql
stable
as $$
  select case
    when p_store_ids is null or array_length(p_store_ids, 1) is null then true
    else exists (
      select 1 from public.settlement_batch_lines l
      where l.settlement_batch_id = p_settlement_batch_id
        and (
          l.primary_store_id = any (p_store_ids)
          or (l.secondary_store_id is not null and l.secondary_store_id = any (p_store_ids))
        )
    )
  end;
$$;

comment on function public._report_settlement_batch_matches_store_filter(uuid, uuid[]) is
  'Hotfix 8.1.2 §16-18 (internal) -- true iff settlement batch p_settlement_batch_id has AT LEAST ONE line (primary or secondary store) within the EXPLICIT filter p_store_ids -- the correct semantic for "does this batch match a chosen store filter" (as opposed to _report_settlement_batch_in_store_scope()''s ALL-lines VISIBILITY semantic). NULL/empty p_store_ids (no filter) is vacuously true for every batch, mirroring _report_resolve_store_filter()''s own "no filter = everything" contract. A zero-line (draft) batch never matches a non-empty filter (nothing store-specific to match yet) but always matches "no filter". Not directly callable by authenticated.';

revoke execute on function public._report_settlement_batch_matches_store_filter(uuid, uuid[]) from public;

-- ---------------------------------------------------------------------------
-- get_dashboard_summary() (0205) -- body-only fix: settle_batch_scope now
-- checks VISIBILITY against the actor's full scope and FILTER MATCH against
-- the caller's raw p_store_ids, instead of one conflated ALL-lines check
-- against v_stores (§16-18).
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
  v_full_scope uuid[];
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
  v_full_scope := public._report_actor_full_store_scope(v_actor);
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
    where public._report_settlement_batch_in_store_scope(b.id, v_full_scope)
      and public._report_settlement_batch_matches_store_filter(b.id, p_store_ids)
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
  'Phase 8 §12/§13/§18/§20/§92/§93; Patch 8.1 §1-3/§4-8; Hotfix 8.1.2 §16-18 — Executive Summary. Settlement-batch scope now checks VISIBILITY (_report_settlement_batch_in_store_scope, ALL-lines) against the actor''s FULL store scope and store FILTER MATCH (_report_settlement_batch_matches_store_filter, ANY-line) against the caller''s raw p_store_ids separately — a cross-store batch is no longer wrongly hidden when the actor narrows to just one of its stores. Financial Privacy Matrix unchanged from Patch 8.1. SECURITY DEFINER.';

revoke execute on function public.get_dashboard_summary(date, date, uuid[]) from public;
grant execute on function public.get_dashboard_summary(date, date, uuid[]) to authenticated;

-- ---------------------------------------------------------------------------
-- get_dashboard_trends() (0205) -- same §16-18 fix at its own settlement CTE.
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
  v_full_scope uuid[];
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
  v_full_scope := public._report_actor_full_store_scope(v_actor);
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
    where public._report_settlement_batch_in_store_scope(bt.id, v_full_scope)
      and public._report_settlement_batch_matches_store_filter(bt.id, p_store_ids)
      and bt.status in ('finalized', 'reconciled')
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
  'Phase 8 §19/§73/§39; Patch 8.1 §1-3/§4-8/§9-10; Hotfix 8.1.2 §16-18 — zero-filled trend series. Settlement-batch scope now checks VISIBILITY against the actor''s FULL store scope and store FILTER MATCH against the caller''s raw p_store_ids separately (same fix as get_dashboard_summary()). Requires dashboard.view. SECURITY DEFINER.';

revoke execute on function public.get_dashboard_trends(date, date, uuid[], text) from public;
grant execute on function public.get_dashboard_trends(date, date, uuid[], text) to authenticated;

-- ---------------------------------------------------------------------------
-- get_settlements_report() (0218) -- same §16-18 fix at its own settle_batch_scope.
-- ---------------------------------------------------------------------------
create or replace function public.get_settlements_report(
  p_date_from date,
  p_date_to date,
  p_store_ids uuid[] default null,
  p_settlement_route_id uuid default null,
  p_status text default null,
  p_search text default null,
  p_sort text default 'settlement_date_desc',
  p_limit integer default 50,
  p_offset integer default 0,
  p_route_kind text default null,
  p_payment_method_id uuid default null,
  p_collection_channel_id uuid default null,
  p_shipping_carrier_id uuid default null,
  p_effective_status text default null,
  p_has_variance boolean default null,
  p_provider_statement_reference text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_actor uuid := auth.uid();
  v_can_financials boolean;
  v_stores uuid[];
  v_full_scope uuid[];
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 5000);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_result jsonb;
begin
  if v_actor is null or not public.has_permission('reports.view') or not public.has_permission('settlements.view') then
    raise exception 'ليست لديك صلاحية عرض تقرير التسويات البنكية' using errcode = 'P0001';
  end if;
  if p_effective_status is not null and p_effective_status not in ('draft', 'finalized', 'reconciled', 'cancelled') then
    raise exception 'حالة تقرير غير صالحة' using errcode = 'P0001';
  end if;
  perform public._report_validate_date_range(p_date_from, p_date_to);
  v_can_financials := public.has_permission('settlements.view_financials');
  if p_has_variance is not null and not v_can_financials then
    raise exception 'ليست لديك صلاحية استخدام مرشح الفروقات المالية' using errcode = 'P0001';
  end if;
  v_stores := public._report_resolve_store_filter(v_actor, p_store_ids);
  v_full_scope := public._report_actor_full_store_scope(v_actor);

  with settle_batch_scope as (
    select b.id, b.settlement_number, b.settlement_route_id, b.settlement_date, b.status,
      b.route_name_ar_snapshot, b.route_kind_snapshot,
      b.payment_method_id_snapshot, b.payment_method_name_snapshot,
      b.collection_channel_id_snapshot, b.collection_channel_name_snapshot,
      b.shipping_carrier_id_snapshot, b.shipping_carrier_name_snapshot,
      b.provider_statement_reference,
      b.expected_bank_settlement, b.finalized_at, b.reconciled_at,
      exists (select 1 from public.settlement_batch_cancellations c where c.settlement_batch_id = b.id) as is_cancelled
    from public.settlement_batches b
    where public._report_settlement_batch_in_store_scope(b.id, v_full_scope)
      and public._report_settlement_batch_matches_store_filter(b.id, p_store_ids)
      and (
        (p_effective_status = 'draft' and b.status = 'draft')
        or (coalesce(p_effective_status, '') <> 'draft' and b.status in ('finalized', 'reconciled'))
      )
      and (p_settlement_route_id is null or b.settlement_route_id = p_settlement_route_id)
      and (p_status is null or b.status = p_status)
      and (p_route_kind is null or b.route_kind_snapshot = p_route_kind)
      and (p_payment_method_id is null or b.payment_method_id_snapshot = p_payment_method_id)
      and (p_collection_channel_id is null or b.collection_channel_id_snapshot = p_collection_channel_id)
      and (p_shipping_carrier_id is null or b.shipping_carrier_id_snapshot = p_shipping_carrier_id)
      and (p_provider_statement_reference is null or btrim(p_provider_statement_reference) = '' or b.provider_statement_reference ilike '%' || btrim(p_provider_statement_reference) || '%')
      and (p_search is null or btrim(p_search) = '' or b.settlement_number ilike '%' || btrim(p_search) || '%')
  ),
  settle_batch_eff as (
    select sbs.*,
      (case when sbs.is_cancelled then 'cancelled' else sbs.status end) as effective_status,
      coalesce((select sum(e.amount) from public.settlement_bank_movement_events e where e.settlement_batch_id = sbs.id), 0)
        + coalesce((
            select sum(rv.amount_impact)
            from public.settlement_bank_movement_reversals rv
            join public.settlement_bank_movement_events e2 on e2.id = rv.bank_movement_event_id
            where e2.settlement_batch_id = sbs.id
          ), 0) as live_actual
    from settle_batch_scope sbs
  ),
  filtered_batch_scope as (
    select *, (live_actual - coalesce(expected_bank_settlement, 0)) as live_variance
    from settle_batch_eff
    where (p_effective_status is null or effective_status = p_effective_status)
      and (
        p_has_variance is null
        or (p_has_variance = true and expected_bank_settlement is not null and (live_actual - coalesce(expected_bank_settlement, 0)) <> 0)
        or (p_has_variance = false and (expected_bank_settlement is null or (live_actual - coalesce(expected_bank_settlement, 0)) = 0))
      )
  ),
  rows_in_range as (
    select * from filtered_batch_scope
    where settlement_date between p_date_from and p_date_to
  ),
  row_summary as (
    select
      count(*) as batches_count,
      count(*) filter (where is_cancelled) as cancelled_count,
      count(*) filter (where not is_cancelled and expected_bank_settlement is not null and live_variance <> 0) as variance_count
    from rows_in_range
  ),
  settle_finalized_scoped as (
    select id, settlement_date, expected_bank_settlement
    from filtered_batch_scope
    where status in ('finalized', 'reconciled')
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
  ledger as (
    select
      coalesce((select sum(sf.expected_bank_settlement) from settle_finalized_scoped sf where sf.settlement_date between p_date_from and p_date_to), 0)
        + coalesce((select sum(-sc.expected_bank_settlement) from settle_cancellations_scoped sc where sc.cancellation_business_date between p_date_from and p_date_to), 0) as expected,
      coalesce((select sum(sm.amount) from settle_movements_scoped sm where sm.movement_business_date between p_date_from and p_date_to), 0)
        + coalesce((select sum(sr.amount_impact) from settle_reversals_scoped sr where sr.reversal_business_date between p_date_from and p_date_to), 0)
        + coalesce((select sum(-sc.live_actual_at_cancel) from settle_cancellations_scoped sc where sc.cancellation_business_date between p_date_from and p_date_to), 0) as actual
  ),
  paged as (
    select * from rows_in_range
    order by
      case when p_sort = 'settlement_date_asc' then settlement_date end asc,
      settlement_date desc, settlement_number desc
    limit v_limit offset v_offset
  )
  select jsonb_build_object(
    'total_count', (select batches_count from row_summary),
    'limit', v_limit, 'offset', v_offset,
    'row_basis', 'current_effective',
    'summary_basis', 'movements_during_period',
    'summary', jsonb_build_object(
      'batches_count', (select batches_count from row_summary),
      'cancelled_count', (select cancelled_count from row_summary)
    ) || (case when v_can_financials then jsonb_build_object(
      'variance_count', (select variance_count from row_summary),
      'expected', (select expected::text from ledger),
      'actual', (select actual::text from ledger),
      'variance', (select (actual - expected)::text from ledger)
    ) else '{}'::jsonb end),
    'rows', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'settlement_batch_id', paged.id, 'settlement_number', paged.settlement_number,
        'settlement_date', paged.settlement_date, 'status', paged.status,
        'effective_status', paged.effective_status, 'is_cancelled', paged.is_cancelled,
        'route_name', paged.route_name_ar_snapshot, 'route_kind', paged.route_kind_snapshot,
        'payment_method_id', paged.payment_method_id_snapshot, 'payment_method_name', paged.payment_method_name_snapshot,
        'collection_channel_id', paged.collection_channel_id_snapshot, 'collection_channel_name', paged.collection_channel_name_snapshot,
        'shipping_carrier_id', paged.shipping_carrier_id_snapshot, 'shipping_carrier_name', paged.shipping_carrier_name_snapshot,
        'provider_statement_reference', paged.provider_statement_reference,
        'finalized_at', paged.finalized_at, 'reconciled_at', paged.reconciled_at
      ) || (case when v_can_financials then jsonb_build_object(
        'expected_bank_settlement', paged.expected_bank_settlement::text,
        'live_actual', paged.live_actual::text,
        'live_variance', paged.live_variance::text
      ) else '{}'::jsonb end) order by paged.settlement_date desc), '[]'::jsonb)
      from paged
    )
  ) into v_result;

  return v_result;
end;
$$;

comment on function public.get_settlements_report(date, date, uuid[], uuid, text, text, text, integer, integer, text, uuid, uuid, uuid, text, boolean, text) is
  'Phase 8 §33/§39/§45/§63/§83/§85; Patch 8.1 §41; Hotfix 8.1.1 §28-31; Hotfix 8.1.2 §16-18 -- Settlements Report. Settlement-batch scope now checks VISIBILITY (full store scope) and store FILTER MATCH (raw p_store_ids, ANY-line) separately, same fix as get_dashboard_summary(). Rows/Summary share ONE filtered_batch_scope (unchanged from 8.1.1). Financial fields require settlements.view_financials. Requires reports.view + settlements.view. SECURITY DEFINER.';

revoke execute on function public.get_settlements_report(date, date, uuid[], uuid, text, text, text, integer, integer, text, uuid, uuid, uuid, text, boolean, text) from public;
grant execute on function public.get_settlements_report(date, date, uuid[], uuid, text, text, text, integer, integer, text, uuid, uuid, uuid, text, boolean, text) to authenticated;

-- ---------------------------------------------------------------------------
-- get_cod_report() (0216) -- same §16-18 fix at its Settlement side batch_scope.
-- ---------------------------------------------------------------------------
create or replace function public.get_cod_report(
  p_date_from date,
  p_date_to date,
  p_store_ids uuid[] default null,
  p_cod_collection_state text default null,
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
  v_can_settlements boolean;
  v_can_settlements_financials boolean;
  v_stores uuid[];
  v_full_scope uuid[];
  v_basis text := coalesce(p_basis, 'current_effective');
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 5000);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_result jsonb;
begin
  if v_actor is null or not public.has_permission('reports.view') or not public.has_permission('shipments.view') then
    raise exception 'ليست لديك صلاحية عرض تقرير الدفع عند الاستلام' using errcode = 'P0001';
  end if;
  if v_basis not in ('current_effective', 'collection_transitions') then
    raise exception 'أساس تقرير غير صالح' using errcode = 'P0001';
  end if;
  perform public._report_validate_date_range(p_date_from, p_date_to);
  v_can_profit := public.has_permission('sales.view_profit');
  v_can_settlements := public.has_permission('settlements.view');
  v_can_settlements_financials := v_can_settlements and public.has_permission('settlements.view_financials');
  v_stores := public._report_resolve_store_filter(v_actor, p_store_ids);
  v_full_scope := public._report_actor_full_store_scope(v_actor);

  if v_basis = 'current_effective' then
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
        coalesce(sum(cod_expected_amount) filter (where cod_collection_state = 'collected'), 0) as cod_collected_amount,
        coalesce(sum(cod_expected_amount) filter (where cod_collection_state <> 'collected'), 0) as effective_cod_receivable
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
        'cod_collected_amount', (select cod_collected_amount::text from summary),
        'effective_cod_receivable', (select effective_cod_receivable::text from summary)
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
  else
    with scoped_shipments as (
      select sh.id, sh.shipment_number, sh.shipment_date, sh.store_id, s.name_ar as store_name,
        sh.current_status, sh.cod_expected_amount, so.order_number
      from public.shipments sh
      join public.sales_orders so on so.id = sh.sales_order_id
      join public.stores s on s.id = sh.store_id
      where sh.is_cod = true
        and sh.store_id = any (v_stores)
        and (p_search is null or btrim(p_search) = ''
             or sh.shipment_number ilike '%' || btrim(p_search) || '%'
             or so.order_number ilike '%' || btrim(p_search) || '%')
    ),
    events_ordered as (
      select ce.shipment_id, ce.state, ce.business_date, ce.created_at, ce.id, ce.reference,
        lag(ce.state) over (partition by ce.shipment_id order by ce.business_date, ce.created_at, ce.id) as prev_state
      from public.shipment_cod_events ce
      join scoped_shipments ss on ss.id = ce.shipment_id
    ),
    transitions as (
      select eo.shipment_id, eo.business_date as movement_date, eo.state as transition_state, eo.reference,
        (case
          when eo.state = eo.prev_state then 0
          when eo.state = 'collected' then ss.cod_expected_amount
          when eo.state = 'not_collected' and eo.prev_state = 'collected' then -ss.cod_expected_amount
          else 0
        end) as cod_effect
      from events_ordered eo
      join scoped_shipments ss on ss.id = eo.shipment_id
    ),
    filtered as (
      select t.*, ss.shipment_number, ss.shipment_date, ss.store_id, ss.store_name, ss.current_status, ss.order_number
      from transitions t
      join scoped_shipments ss on ss.id = t.shipment_id
      where t.movement_date between p_date_from and p_date_to
        and t.cod_effect <> 0
        and (p_cod_collection_state is null or t.transition_state = p_cod_collection_state)
    ),
    summary as (
      select
        count(*) as movements_count,
        count(distinct shipment_id) as shipments_count,
        coalesce(sum(cod_effect) filter (where cod_effect > 0), 0) as cod_collections,
        coalesce(sum(cod_effect) filter (where cod_effect < 0), 0) as cod_reversals,
        coalesce(sum(cod_effect), 0) as net_cod_collection_effect
      from filtered
    ),
    paged as (
      select * from filtered
      order by
        case when p_sort = 'shipment_date_asc' then movement_date end asc,
        movement_date desc, shipment_number desc
      limit v_limit offset v_offset
    )
    select jsonb_build_object(
      'total_count', (select movements_count from summary),
      'limit', v_limit, 'offset', v_offset,
      'basis', 'collection_transitions',
      'summary', jsonb_build_object(
        'movements_count', (select movements_count from summary),
        'shipments_count', (select shipments_count from summary)
      ) || (case when v_can_profit then jsonb_build_object(
        'cod_collections', (select cod_collections::text from summary),
        'cod_reversals', (select cod_reversals::text from summary),
        'net_cod_collection_effect', (select net_cod_collection_effect::text from summary)
      ) else '{}'::jsonb end),
      'rows', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'shipment_id', paged.shipment_id, 'shipment_number', paged.shipment_number,
          'movement_date', paged.movement_date, 'transition_state', paged.transition_state,
          'reference', paged.reference,
          'store_id', paged.store_id, 'store_name', paged.store_name, 'order_number', paged.order_number,
          'current_status', paged.current_status
        ) || (case when v_can_profit then jsonb_build_object(
          'cod_effect', paged.cod_effect::text
        ) else '{}'::jsonb end) order by paged.movement_date desc), '[]'::jsonb)
        from paged
      )
    ) into v_result;
  end if;

  if v_can_settlements then
    with route_scope as (
      select r.id as route_id, r.shipping_carrier_id
      from public.settlement_routes r
      where r.route_kind = 'cod_carrier'
    ),
    batch_scope as (
      select b.id, b.settlement_route_id, b.settlement_date, b.expected_bank_settlement,
        b.route_name_ar_snapshot, b.shipping_carrier_name_snapshot,
        exists (select 1 from public.settlement_batch_cancellations c where c.settlement_batch_id = b.id) as is_cancelled
      from public.settlement_batches b
      join route_scope rs on rs.route_id = b.settlement_route_id
      where public._report_settlement_batch_in_store_scope(b.id, v_full_scope)
        and public._report_settlement_batch_matches_store_filter(b.id, p_store_ids)
        and b.status in ('finalized', 'reconciled')
    ),
    route_label as (
      select distinct on (settlement_route_id) settlement_route_id,
        route_name_ar_snapshot as route_name, shipping_carrier_name_snapshot as carrier_name
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
      select rs.route_id, rl.route_name, rs.shipping_carrier_id, rl.carrier_name,
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
      select * from per_route where batches_count > 0
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
          'shipping_carrier_id', filtered.shipping_carrier_id, 'carrier_name', filtered.carrier_name,
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

comment on function public.get_cod_report(date, date, uuid[], text, text, text, integer, integer, text) is
  'Phase 8 §30/§39/§45/§63/§83; Hotfix 8.1.1 §23-26; Hotfix 8.1.2 §16-18 -- COD DUAL BASIS report. Settlement side batch_scope now checks VISIBILITY (full store scope) and store FILTER MATCH (raw p_store_ids, ANY-line) separately, same fix as get_dashboard_summary(). Requires reports.view + shipments.view. SECURITY DEFINER.';

revoke execute on function public.get_cod_report(date, date, uuid[], text, text, text, integer, integer, text) from public;
grant execute on function public.get_cod_report(date, date, uuid[], text, text, text, integer, integer, text) to authenticated;

commit;
