-- ============================================================================
-- Phase 8 — Integrity Patch 8.1 — §30-32/§65: get_cod_report() canonical
-- COD financial event ledger + carrier settlement figures.
-- ============================================================================
-- Migrations 0001-0208 are FROZEN. This migration only ADDS 0209+. Rebuilds
-- get_cod_report() (originally 0203) via DROP FUNCTION IF EXISTS <old exact
-- signature> + CREATE FUNCTION (new p_basis + new params change identity).
--
-- Problem (§30): the existing get_cod_report() cohorts is_cod shipments by
-- shipment_date and reads shipments.cod_collection_state -- a CURRENT-STATE
-- CACHE, not the canonical append-only shipment_cod_events ledger Phase 7
-- already built. A COD shipment collected in August whose state was
-- corrected in September would misreport August's true collection activity.
--
-- Fix: mirror the EXACT dual-basis pattern already established for Shipping
-- (0206, §7-8) and Returns (0208, §26-29) -- a new p_basis parameter:
--
--   'current_effective' (default, byte-identical to 0203's existing
--   behaviour and numbers, only relabelled/annotated): unchanged cohort by
--   shipment_date + shipments.cod_collection_state cache. Gains one new
--   always-safe field, effective_cod_receivable (§31 "equivalent clearly-
--   defined current metric"): cod_expected_amount summed over shipments
--   whose CURRENT state is NOT 'collected' -- i.e. still outstanding.
--
--   'collection_transitions' (NEW): the canonical financial ledger built
--   from shipment_cod_events via lag(state) partition by shipment_id order
--   by business_date, created_at, id (§30's exact deterministic ordering,
--   identical convention to 0130/0131 and to 0205's shipping adapter):
--     - a transition INTO 'collected' from any state that is NOT 'collected'
--       (including the shipment's very first-ever event, where prev_state
--       is null) = +cod_expected_amount, dated the event's own business_date.
--     - a transition OUT OF 'collected' to any non-'collected' canonical
--       state ('expected'/'not_collected'/'unknown') = -cod_expected_amount,
--       dated the event's own business_date.
--     - a same-state event (state = prev_state) is NEVER a financial source
--       (§30 "same-state duplicates are not a financial source") = 0.
--     - a transition between two non-'collected' states (e.g.
--       expected -> unknown) is also not a financial source = 0.
--     This exact formula reproduces the spec's own §32 worked scenarios:
--       (A) collected -> collected           = one +Collection only.
--       (B) collected -> not_collected -> not_collected = +/- only (dup=0).
--       (C) collected -> not_collected -> collected      = +/-/+.
--     A COD sale's own Sale event is never part of this ledger (§32-D) --
--     this function only ever reads shipment_cod_events, never sales_orders
--     financial columns.
--
-- §31: both bases additionally carry a Settlement block (Expected/Actual/
-- Variance), sourced EXCLUSIVELY from route_kind='cod_carrier' settlement
-- routes (never payment_collection -- that is 0207's payment-methods report
-- settlement section) -- the identical movements-ledger formula already
-- proven in get_dashboard_summary() (0205) and get_payment_methods_report()
-- (0207): batch_scope (finalized/reconciled batches in store scope) +
-- cancellations (undo at cancellation_business_date) + movements
-- (settlement_bank_movement_events at their own movement_business_date) +
-- reversals (settlement_bank_movement_reversals at their own
-- reversal_business_date), gated on settlements.view + settlements.view_financials.
--
-- §65 required test scenarios (A-E) are proven in the golden-scenario test
-- expansion (§193 of the task list) -- this migration ships the mechanism.
-- ============================================================================
begin;

drop function if exists public.get_cod_report(date, date, uuid[], text, text, text, integer, integer);

create function public.get_cod_report(
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
    -- shipment_cod_events, per-shipment lag(state) chronology (§30).
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
          when eo.prev_state = 'collected' then -ss.cod_expected_amount
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

  -- ---- Settlement side (§31): cod_carrier routes ONLY, both bases ----
  if v_can_settlements then
    with route_scope as (
      select r.id as route_id, r.name_ar as route_name, r.shipping_carrier_id,
        sc.name_ar as carrier_name
      from public.settlement_routes r
      join public.shipping_carriers sc on sc.id = r.shipping_carrier_id
      where r.route_kind = 'cod_carrier'
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
      select rs.route_id, rs.route_name, rs.shipping_carrier_id, rs.carrier_name,
        (coalesce((select sum(expected_bank_settlement) from batch_scope where settlement_route_id = rs.route_id and settlement_date between p_date_from and p_date_to), 0)
          + coalesce((select sum(-expected_bank_settlement) from cancellations where settlement_route_id = rs.route_id and cancellation_business_date between p_date_from and p_date_to), 0)) as expected,
        (coalesce((select sum(amount) from movements where settlement_route_id = rs.route_id and movement_business_date between p_date_from and p_date_to), 0)
          + coalesce((select sum(amount_impact) from reversals where settlement_route_id = rs.route_id and reversal_business_date between p_date_from and p_date_to), 0)
          + coalesce((select sum(-live_actual_at_cancel) from cancellations where settlement_route_id = rs.route_id and cancellation_business_date between p_date_from and p_date_to), 0)) as actual,
        (select count(*) from batch_scope where settlement_route_id = rs.route_id and settlement_date between p_date_from and p_date_to) as batches_count
      from route_scope rs
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
  'Phase 8 §30/§39/§45/§63/§83; Patch 8.1 §30-32/§65 -- COD DUAL BASIS report. p_basis=''current_effective'' (default, byte-identical to 0203): cohort by shipment_date + shipments.cod_collection_state cache; gains effective_cod_receivable (shipments currently NOT collected). p_basis=''collection_transitions'' (NEW): canonical financial ledger from shipment_cod_events via lag(state) partition by shipment_id order by business_date/created_at/id -- a transition INTO collected = +amount, OUT OF collected to a non-collected canonical state = -amount, same-state duplicates and non-collected-to-non-collected transitions = 0 (never a financial source). Both bases append a Settlement block (Expected/Actual/Variance) restricted to route_kind=cod_carrier ONLY (never payment_collection), gated settlements.view/settlements.view_financials -- never double-counts the COD Sale itself as a Payment Collection cash source. Requires reports.view + shipments.view. SECURITY DEFINER.';

revoke execute on function public.get_cod_report(date, date, uuid[], text, text, text, integer, integer, text) from public;
grant execute on function public.get_cod_report(date, date, uuid[], text, text, text, integer, integer, text) to authenticated;

commit;
