-- ============================================================================
-- Phase 8 — Final Integrity Hotfix 8.1.1 — §23-26 CRITICAL: get_cod_report()
-- 'collection_transitions' basis must match the canonical Phase 7 Settlement
-- COD adapter's Reversal condition EXACTLY, and its Settlement block must
-- use the batch's own historical snapshot labels, never live master-data.
-- ============================================================================
-- Migrations 0001-0215 are FROZEN. This migration only ADDS 0216+.
-- get_cod_report()'s signature is UNCHANGED from 0209 -- both fixes are
-- body-only, so CREATE OR REPLACE is used directly (no DROP needed, §0).
--
-- §23-25 CRITICAL: 0209's `transitions` CTE computed Reversal as
--   when eo.prev_state = 'collected' then -ss.cod_expected_amount
-- which fires for ANY transition OUT of 'collected' -- including
-- collected->expected and collected->unknown, neither of which the
-- canonical Settlement COD adapter (0198, public._settlement_unsettled_
-- source_candidates, Candidate I "COD Reversal") treats as a reversal.
-- The canonical adapter's exact condition (re-read directly from 0198 for
-- this fix) is:
--   ct.state = 'not_collected' and ct.prev_state = 'collected'
-- i.e. a Reversal is STRICTLY collected -> not_collected. Every other
-- transition out of 'collected' (collected->expected, collected->unknown)
-- is not a financial source under the canonical policy = 0, matching the
-- Collection condition's own symmetry (state='collected' and prev IS
-- DISTINCT FROM 'collected' = +amount, unchanged, already correct).
--
-- §25 required test matrix (now satisfied by the corrected CASE below):
--   expected->collected              = +1  (Collection)
--   collected->collected             =  0  (same-state, not a source)
--   collected->expected              =  0  (was -1, THE BUG -- now fixed)
--   expected->collected (new)        = +1  (Collection, independent event)
--   collected->unknown               =  0  (was -1, THE BUG -- now fixed)
--   unknown->not_collected           =  0  (prev was not 'collected')
--   collected->not_collected         = -1  (Reversal, strict match)
--
-- Event dating (documented design decision, not left implicit): the
-- canonical adapter dates its Reversal candidate at
-- coalesce(ct.prev_business_date, ct.business_date) -- the PRIOR event's
-- date, chosen there because a Settlement source-of-truth needs the
-- reversal to fall in the SAME settlement window as the collection it
-- undoes whenever possible. This report, like every other movements ledger
-- in Phase 8 (§85 Event-Date Integrity -- Returns/Adjustments/Shipping all
-- date a reversal at ITS OWN business date, never a lookback date), keeps
-- dating the Reversal at the transition event's OWN business_date. §23-25's
-- complaint and worked matrix concern VALUE correctness only (which
-- transitions count, and their sign) -- never date placement -- so this
-- report matches the canonical adapter's condition/amount exactly while
-- keeping §85's own-date convention, a deliberate and transparent choice
-- rather than a silent divergence.
--
-- §26 CRITICAL: both bases' Settlement block (route_kind='cod_carrier')
-- joined LIVE public.settlement_routes/public.shipping_carriers for the
-- display route_name/carrier_name -- so renaming a carrier today silently
-- rewrites an already-reported historical period's label. settlement_
-- batches already snapshots route_name_ar_snapshot/shipping_carrier_name_
-- snapshot immutably at finalize time (0172) -- exactly the mechanism
-- get_settlements_report() (0212) already uses correctly for its own rows.
-- Fixed by reading the label from the IN-SCOPE batch's own snapshot columns
-- instead: when more than one batch for the same route carries a different
-- historical snapshot within the requested period (a mid-period rename),
-- the snapshot of the batch with the latest settlement_date (then id) wins
-- -- the same deterministic "label as of the end of the period" tie-break
-- already established for get_categories_report()/get_karats_report()
-- (0211, §37). Route/carrier IDENTITY (route_id, shipping_carrier_id) stays
-- the stable master-data reference throughout -- only the DISPLAY LABEL now
-- comes from the snapshot (§26's own instruction: "keeping stable route/
-- snapshot IDs for grouping identity").
-- ============================================================================
begin;

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
    -- 'collection_transitions' basis: canonical financial ledger from
    -- shipment_cod_events, per-shipment lag(state) chronology (§23-25).
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
          -- §23-25 CRITICAL FIX: a Reversal is STRICTLY collected ->
          -- not_collected (matching the canonical Phase 7 Settlement COD
          -- adapter's own condition, 0198, exactly) -- collected->expected
          -- and collected->unknown are NOT financial sources under the
          -- canonical policy (previously miscoded as -amount for ANY
          -- transition out of 'collected').
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

  -- ---- Settlement side (§31, §26 historical labels): cod_carrier routes
  -- ONLY, both bases. Route/carrier IDENTITY stays a stable master-data
  -- reference (route_scope, unchanged); DISPLAY LABELS now come from the
  -- IN-SCOPE batch's own snapshot columns (route_label), never a live join.
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
      where public._report_settlement_batch_in_store_scope(b.id, v_stores)
        and b.status in ('finalized', 'reconciled')
    ),
    -- §26: deterministic historical label -- the snapshot of the batch with
    -- the LATEST settlement_date (then id) WITHIN the requested period wins
    -- per route, when a mid-period rename produced more than one snapshot
    -- label for the same route_id (identical tie-break convention to
    -- get_categories_report()/get_karats_report(), 0211, §37).
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
  'Phase 8 §30/§39/§45/§63/§83; Hotfix 8.1.1 §23-26 -- COD DUAL BASIS report. p_basis=''collection_transitions'' Reversal condition FIXED to strictly state=not_collected AND prev_state=collected (matching the canonical Phase 7 Settlement COD adapter, 0198, exactly) -- collected->expected/collected->unknown are no longer miscounted as reversals. Own-event-date convention (§85) kept deliberately (documented) despite the canonical adapter''s lookback-date choice -- VALUE/condition parity only. Settlement block (route_kind=cod_carrier only) now reads route/carrier DISPLAY labels from the in-scope batch''s own historical snapshot columns (route_name_ar_snapshot/shipping_carrier_name_snapshot, latest-in-period wins on a mid-period rename) instead of a live join -- a later master-data rename never rewrites an already-reported period (§26). Requires reports.view + shipments.view. SECURITY DEFINER.';

revoke execute on function public.get_cod_report(date, date, uuid[], text, text, text, integer, integer, text) from public;
grant execute on function public.get_cod_report(date, date, uuid[], text, text, text, integer, integer, text) to authenticated;

commit;
