-- ============================================================================
-- Phase 8 — Reports, Dashboard & Exports (0200)
-- Dashboard: get_dashboard_summary() (Executive Summary + Comparison Engine
-- + Net Operating Return reconciliation, §12/§13/§18/§20/§92/§93) and
-- get_dashboard_trends() (§19/§73 zero-filled trend series).
-- ============================================================================
-- FREEZE: migrations 0001-0199 untouched. This migration is purely additive.
--
-- Reporting Truth Model (§1/§2): every figure below is read from a stored
-- financial snapshot/append-only event column already committed by its
-- origin domain (Sales/Returns/Shipping/Adjustments/Settlements) — nothing
-- here recomputes gold cost, VAT, payment fees, or shipping rates from
-- CURRENT master data. See DELIVERY_REPORT.md's Phase 8 appendix for the
-- full canonical-source-per-domain explanation (§100 item 10).
--
-- Event Date semantics (§84/§85) — "movements during the period", not
-- "current status of records created in the period":
--   Sales           -> sales_orders.sale_date (permanent, sales orders are
--                      never voided/cancelled — confirmed by exhaustive
--                      schema search; only a Return reverses effect).
--   Returns         -> APPROVAL event dated sales_returns.return_date
--                      (status IN ('approved','reversed') — the approval
--                      happened at return_date regardless of a LATER
--                      reversal) MINUS an UNDO event dated
--                      sales_returns.reversal_business_date for returns
--                      whose status = 'reversed' (the reversal itself is a
--                      second, separately-dated movement that undoes the
--                      first). Actual Refund Cash uses the SAME two-event
--                      pattern on sales_return_refund_events.refund_business_date
--                      (issue) vs sales_return_refund_event_reversals.
--                      reversal_business_date (undo) — never the frozen
--                      legacy status/reversed_at columns on
--                      sales_return_refund_events itself (superseded by
--                      0106's append-only redesign).
--   Adjustments     -> APPROVAL event dated sales_order_adjustments.
--                      adjustment_date (status='approved' persists forever,
--                      even once reversed) PLUS the reversal's own signed
--                      impact columns (already correctly signed so the
--                      original nets to exactly 0.00) dated
--                      sales_order_adjustment_reversals.reversal_business_date.
--   Settlements     -> settlement_batches.settlement_date for the batch
--                      itself; effective_* contribution collapses to 0.00
--                      for any batch with a settlement_batch_cancellations
--                      row (§17), replicating get_settlement_batch()'s
--                      (0191) own original-vs-effective convention exactly.
--   Shipping        -> DOCUMENTED DESIGN CHOICE (see comment on
--                      _report_shipping_note below): shipments.shipment_date
--                      with the shipment's CURRENT cached net_shipping_actual/
--                      net_shipping_expected — not a separate movements
--                      ledger. shipment_financial_events/shipment_cod_events
--                      are amendments to the SAME operational record (no
--                      parallel signed-impact reversal ledger exists for
--                      them, unlike Returns/Adjustments/Settlements), so
--                      "current effective value as of the shipment's own
--                      business date" is the defensible V1 basis. Flagged
--                      explicitly in delivery for review.
--
-- Store scope (§8/§9): every domain join filters through v_stores =
-- _report_resolve_store_filter(actor, p_store_ids) (0199). Adjustments
-- require the DUAL-AND cross-store visibility already established in
-- Settlements (0198) — both the original Sale's store_id AND the
-- Adjustment's own processing_store_id must be in v_stores. Settlements
-- require ALL of a batch's lines' stores (primary AND secondary) to be in
-- v_stores (whole-batch all-or-nothing, mirroring _settlement_batch_
-- all_stores_visible's existing contract but parameterized by the caller's
-- explicit filter rather than just their full visible scope) — see
-- _report_settlement_batch_in_store_scope below.
--
-- Financial privacy (§10/§11/§61): dashboard.view gates the RPC itself.
-- Within it: a domain SECTION (sales/returns/shipping/adjustments/
-- settlements) is present in the output ONLY if the actor holds that
-- domain's own *.view permission (operational key absence, §10 "checked
-- existing permissions first"); profit/financial SUB-fields inside a
-- present section additionally require dashboard.view_financials AND the
-- domain's own financial-sensitivity permission (sales.view_profit for
-- Sales/Returns' profit figures; settlements.view_financials for
-- Settlements' amounts) — Shipping/Adjustments have no separate profit
-- permission in this project (confirmed by exhaustive seed.sql search), so
-- their money fields require dashboard.view_financials AND the domain's
-- own *.view only. Net Operating Return is a CROSS-domain aggregate, so it
-- is computed/returned ONLY when ALL of dashboard.view_financials,
-- sales.view_profit, shipments.view and adjustments.view hold — a partial
-- Net Operating Return would misrepresent the real total (§10: "one
-- permission must never unlock another domain").
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- Shared date-range validator (§4): date_from<=date_to, and a generous
-- (~10 years) sanity cap against a catastrophically unbounded range,
-- without hardcoding anything small enough to block a Yearly report.
-- ---------------------------------------------------------------------------
create or replace function public._report_validate_date_range(p_date_from date, p_date_to date)
returns void
language plpgsql
immutable
as $$
begin
  if p_date_from is null or p_date_to is null then
    raise exception 'date_from/date_to مطلوبة' using errcode = 'P0001';
  end if;
  if p_date_from > p_date_to then
    raise exception 'date_from يجب أن يكون قبل أو يساوي date_to' using errcode = 'P0001';
  end if;
  if (p_date_to - p_date_from) > 3660 then
    raise exception 'النطاق الزمني المطلوب كبير جدًا (الحد الأقصى تقريبًا 10 سنوات)' using errcode = 'P0001';
  end if;
end;
$$;

comment on function public._report_validate_date_range(date, date) is
  'Phase 8 §4 (internal) -- shared date_from<=date_to + ~10-year sanity-cap validation for every report/dashboard RPC. Not directly callable (revoked from public, no explicit grant).';

revoke execute on function public._report_validate_date_range(date, date) from public;

-- ---------------------------------------------------------------------------
-- Settlement store-scope helper (§8/§9 applied to Settlements): a batch is
-- "in scope" for an explicit store filter p_store_ids iff it has at least
-- one line AND no line names a primary/secondary store outside
-- p_store_ids. Whole-batch all-or-nothing, parameterized by an explicit
-- filter set rather than just the actor's full visible scope (unlike
-- _settlement_batch_all_stores_visible, 0186, which is visibility-only).
-- ---------------------------------------------------------------------------
create or replace function public._report_settlement_batch_in_store_scope(p_settlement_batch_id uuid, p_store_ids uuid[])
returns boolean
language sql
stable
as $$
  select exists (select 1 from public.settlement_batch_lines l where l.settlement_batch_id = p_settlement_batch_id)
     and not exists (
       select 1 from public.settlement_batch_lines l
       where l.settlement_batch_id = p_settlement_batch_id
         and (
           not (l.primary_store_id = any (p_store_ids))
           or (l.secondary_store_id is not null and not (l.secondary_store_id = any (p_store_ids)))
         )
     );
$$;

comment on function public._report_settlement_batch_in_store_scope(uuid, uuid[]) is
  'Phase 8 §8/§9 (internal) -- true iff settlement batch p_settlement_batch_id has >=1 line AND every line''s primary AND secondary store (when set) are within p_store_ids. Whole-batch all-or-nothing, reused by get_dashboard_summary() (0200) and get_settlements_report() (0204).';

revoke execute on function public._report_settlement_batch_in_store_scope(uuid, uuid[]) from public;

-- ---------------------------------------------------------------------------
-- get_dashboard_summary(): ONE atomic data-fetch query (§92/§93 -- a single
-- top-level SQL statement gets one consistent MVCC snapshot for every
-- domain it touches) computing BOTH the requested period AND its
-- immediately-preceding equal-length comparison period (§18) in the same
-- statement, followed by pure in-memory jsonb assembly (no further table
-- reads) that applies permission-gated true key-absence (§79, matching
-- get_sales_order's established jsonb || case-when pattern, 0079).
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
  v_cur_shipments_count numeric; v_cur_shipping_customer_charges numeric; v_cur_shipping_actual_carrier_cost numeric; v_cur_net_shipping_result numeric;
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
  v_prev_shipments_count numeric; v_prev_shipping_customer_charges numeric; v_prev_shipping_actual_carrier_cost numeric; v_prev_net_shipping_result numeric;
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
  shipping_cte as (
    select p.label,
      count(s.id) as shipments_count,
      coalesce(sum(s.customer_shipping_charge), 0) as customer_charges,
      coalesce(sum(s.actual_carrier_cost), 0) as actual_carrier_cost,
      coalesce(sum(coalesce(s.net_shipping_actual, s.net_shipping_expected)), 0) as net_shipping_result
    from periods p
    left join public.shipments s
      on s.shipment_date between p.d_from and p.d_to and s.store_id = any (v_stores)
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
  -- Settlements (§85): the EXPECTED/ACTUAL/VARIANCE figures below are a
  -- true movements-during-the-period ledger (distinct from the "current
  -- effective" convention 0191 uses for get_settlement_batch()'s own
  -- Screen display) -- §85 explicitly names cancellation_business_date as
  -- its own dated event, so a batch finalized in month M1 and cancelled in
  -- a LATER month M2 must show its original expected commitment in M1
  -- (a real fact that happened then) and the UNDO in M2 (when the
  -- cancellation itself happened) -- never silently vanish from M1 on a
  -- later re-run, and never double-subtract. batches_count/cancelled_count/
  -- variance_count remain CURRENT-STATE operational badges (same
  -- current-effective convention as 0191) for an at-a-glance read of "how
  -- many of this period's finalized batches are, right now, cancelled or
  -- in variance" -- documented explicitly as a different basis from the
  -- ledger figures beside it (§83 Report Basis).
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
    -- +expected recognized at settlement_date (permanent original fact).
    select p.label, coalesce(sum(sf.expected_bank_settlement), 0) as expected_recognized
    from periods p
    left join settle_finalized_scoped sf on sf.settlement_date between p.d_from and p.d_to
    group by p.label
  ),
  settle_undo_cte as (
    -- -expected AND -(actual recognized so far) at cancellation_business_date.
    select p.label,
      coalesce(sum(-sc.expected_bank_settlement), 0) as expected_undo,
      coalesce(sum(-sc.live_actual_at_cancel), 0) as actual_undo
    from periods p
    left join settle_cancellations_scoped sc on sc.cancellation_business_date between p.d_from and p.d_to
    group by p.label
  ),
  settle_actual_cte as (
    -- +amount at each bank movement's own movement_business_date.
    select p.label, coalesce(sum(sm.amount), 0) as actual_from_movements
    from periods p
    left join settle_movements_scoped sm on sm.movement_business_date between p.d_from and p.d_to
    group by p.label
  ),
  settle_reversal_cte as (
    -- already-signed amount_impact at each reversal's own reversal_business_date.
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
      coalesce(sh.actual_carrier_cost, 0) as shipping_actual_carrier_cost,
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
    left join shipping_cte sh on sh.label = p.label
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
  v_cur_shipping_actual_carrier_cost := (v_c ->> 'shipping_actual_carrier_cost')::numeric;
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
  v_prev_shipping_actual_carrier_cost := (v_p ->> 'shipping_actual_carrier_cost')::numeric;
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
      'shipments_count_pct_change', public.report_pct_change(v_cur_shipments_count, v_prev_shipments_count)
    ) || (case when v_can_financials then jsonb_build_object(
      'customer_shipping_charges', v_cur_shipping_customer_charges::text, 'previous_customer_shipping_charges', v_prev_shipping_customer_charges::text,
      'customer_shipping_charges_change', (v_cur_shipping_customer_charges - v_prev_shipping_customer_charges)::text,
      'customer_shipping_charges_pct_change', public.report_pct_change(v_cur_shipping_customer_charges, v_prev_shipping_customer_charges),
      'actual_carrier_cost', v_cur_shipping_actual_carrier_cost::text, 'previous_actual_carrier_cost', v_prev_shipping_actual_carrier_cost::text,
      'actual_carrier_cost_change', (v_cur_shipping_actual_carrier_cost - v_prev_shipping_actual_carrier_cost)::text,
      'actual_carrier_cost_pct_change', public.report_pct_change(v_cur_shipping_actual_carrier_cost, v_prev_shipping_actual_carrier_cost),
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
      'previous_customer_charges', (v_prev_adj_customer_charge + v_prev_adj_customer_charge_reversal)::text,
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
  'Phase 8 §12/§13/§18/§20/§92/§93 -- Executive Summary: one atomic multi-domain aggregation (current period + comparison period computed in a single statement) followed by permission-redacted jsonb assembly (true key absence, §79). Requires dashboard.view; each domain section additionally requires that domain''s own *.view; profit/financial sub-fields additionally require dashboard.view_financials + the domain''s financial permission (sales.view_profit / settlements.view_financials); net_operating_return requires ALL of dashboard.view_financials + sales.view_profit + shipments.view + adjustments.view. SECURITY DEFINER.';

revoke execute on function public.get_dashboard_summary(date, date, uuid[]) from public;
grant execute on function public.get_dashboard_summary(date, date, uuid[]) to authenticated;

-- ---------------------------------------------------------------------------
-- get_dashboard_trends(): the 8 required chart series (§19), zero-filled
-- (§73) via report_date_buckets() (0199), computed with the SAME
-- movement-ledger logic as get_dashboard_summary() (just grouped by bucket
-- instead of a 2-row current/previous period set) so a chart point and the
-- Dashboard card covering the same range always agree (§39 Single
-- Reporting Engine). One atomic query; permission redaction is uniform
-- across every bucket (a function of the actor only), so each bucket
-- object always has the same set of present/absent keys.
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
    select bucket_start, bucket_end, bucket_label from public.report_date_buckets(p_date_from, p_date_to, v_gran)
  ),
  sales_cte as (
    select b.bucket_start,
      count(so.id) as orders_count,
      coalesce(sum(so.subtotal), 0) as sales_revenue,
      coalesce(sum(so.net_sales_profit), 0) as net_sales_profit_original
    from buckets b
    left join public.sales_orders so
      on so.sale_date between b.bucket_start and b.bucket_end and so.store_id = any (v_stores)
    group by b.bucket_start
  ),
  returns_appr_cte as (
    select b.bucket_start,
      count(sr.id) as returns_count,
      coalesce(sum(sr.net_sales_profit_adjustment), 0) as net_profit_reversal
    from buckets b
    left join public.sales_returns sr
      on sr.return_date between b.bucket_start and b.bucket_end
      and sr.status in ('approved', 'reversed')
      and sr.processed_store_id = any (v_stores)
    group by b.bucket_start
  ),
  returns_undo_cte as (
    select b.bucket_start,
      coalesce(sum(sr.net_sales_profit_adjustment), 0) as net_profit_reversal_undo
    from buckets b
    left join public.sales_returns sr
      on sr.reversal_business_date between b.bucket_start and b.bucket_end
      and sr.status = 'reversed'
      and sr.processed_store_id = any (v_stores)
    group by b.bucket_start
  ),
  shipping_cte as (
    select b.bucket_start,
      coalesce(sum(coalesce(s.net_shipping_actual, s.net_shipping_expected)), 0) as net_shipping_result
    from buckets b
    left join public.shipments s
      on s.shipment_date between b.bucket_start and b.bucket_end and s.store_id = any (v_stores)
    group by b.bucket_start
  ),
  adj_appr_cte as (
    select b.bucket_start,
      coalesce(sum(a.net_adjustment_profit), 0) as net_profit
    from buckets b
    left join public.sales_order_adjustments a
      on a.adjustment_date between b.bucket_start and b.bucket_end
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
    ) on r.reversal_business_date between b.bucket_start and b.bucket_end
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
    left join settle_batch_scope sf on sf.settlement_date between b.bucket_start and b.bucket_end
    group by b.bucket_start
  ),
  settle_undo_cte as (
    select b.bucket_start,
      coalesce(sum(-sc.expected_bank_settlement), 0) as expected_undo,
      coalesce(sum(-sc.live_actual_at_cancel), 0) as actual_undo
    from buckets b
    left join settle_cancellations_scoped sc on sc.cancellation_business_date between b.bucket_start and b.bucket_end
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
    left join settle_movements_scoped sm on sm.movement_business_date between b.bucket_start and b.bucket_end
    group by b.bucket_start
  ),
  settle_reversal_cte as (
    select b.bucket_start, coalesce(sum(sr2.amount_impact), 0) as actual_from_reversals
    from buckets b
    left join settle_reversals_scoped sr2 on sr2.reversal_business_date between b.bucket_start and b.bucket_end
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

    if v_can_shipments and v_can_financials then
      v_result := v_result || jsonb_build_object('net_shipping_result', (v_bucket ->> 'net_shipping_result')::numeric::text);
    end if;

    if v_can_adjustments and v_can_financials then
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
  'Phase 8 §19/§73/§39 -- zero-filled trend series (orders/sales revenue/effective net sales profit/returns/net shipping/net adjustments/settlement variance/net operating return) at auto-derived or explicit granularity, computed with the SAME movement-ledger formulas as get_dashboard_summary() so a chart point and its Dashboard card always agree. Permission redaction (identical gating to get_dashboard_summary()) is uniform across every bucket. Requires dashboard.view. SECURITY DEFINER.';

revoke execute on function public.get_dashboard_trends(date, date, uuid[], text) from public;
grant execute on function public.get_dashboard_trends(date, date, uuid[], text) to authenticated;

commit;
