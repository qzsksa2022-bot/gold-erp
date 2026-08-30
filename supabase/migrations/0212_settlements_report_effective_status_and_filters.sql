-- ============================================================================
-- Phase 8 — Integrity Patch 8.1 — §41: get_settlements_report() effective
-- status (a real, working "Cancelled" filter) + full filter set.
-- ============================================================================
-- Migrations 0001-0211 are FROZEN. This migration only ADDS 0212+. Rebuilds
-- get_settlements_report() (originally 0204) via DROP FUNCTION IF EXISTS
-- <old exact signature> + CREATE FUNCTION (new params change identity).
--
-- Problem (§41): settlement_batches.status is structurally CHECK-constrained
-- to ('draft', 'finalized', 'reconciled') ONLY (0172) -- there is no
-- 'cancelled' value and never can be; a batch's cancellation is a SEPARATE,
-- append-only fact recorded by the mere EXISTENCE of a row in
-- settlement_batch_cancellations (already correctly read into is_cancelled
-- by 0204, but never exposed as a filterable status). A caller filtering
-- status='cancelled' therefore always gets zero rows -- not a working
-- filter, a silently broken one.
--
-- Fix: compute effective_status server-side per batch as
--   case when is_cancelled then 'cancelled' else b.status end
-- (b.status here is always 'finalized' or 'reconciled' -- 'draft' batches
-- are never in this report's scope, unchanged from 0204's original design)
-- and add p_effective_status as the new, correctly documented filter that
-- actually matches 'cancelled'. p_status (the old raw-status filter) is
-- KEPT unchanged for backward compatibility -- never removed -- but
-- p_effective_status is now the recommended way to filter, including for
-- "Cancelled".
--
-- §41 also asks for the full missing filter set. settlement_batches (0172)
-- already snapshots payment_method_id_snapshot / collection_channel_id_
-- snapshot / shipping_carrier_id_snapshot / route_kind_snapshot /
-- provider_statement_reference directly on the batch row -- so every new
-- filter below reads the batch's OWN snapshot columns, needing no join to
-- settlement_routes and no risk of a later route-config change silently
-- altering a historical batch's filter membership: p_route_kind,
-- p_payment_method_id, p_collection_channel_id, p_shipping_carrier_id,
-- p_has_variance (true/false, computed from live_variance -- gated behind
-- settlements.view_financials since it is a financial computation; a
-- caller without that permission gets p_has_variance silently ignored
-- rather than an error, since the underlying field is absent for them
-- anyway), p_provider_statement_reference (exact/ilike search).
--
-- §60: v_limit cap raised 500 -> 5000.
-- ============================================================================
begin;

drop function if exists public.get_settlements_report(date, date, uuid[], uuid, text, text, text, integer, integer);

create function public.get_settlements_report(
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
  v_stores := public._report_resolve_store_filter(v_actor, p_store_ids);

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
    where public._report_settlement_batch_in_store_scope(b.id, v_stores)
      and b.status in ('finalized', 'reconciled')
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
      -- §41: the effective_status a "Cancelled" filter can actually match --
      -- status is structurally never 'cancelled' (0172's CHECK constraint),
      -- so this is computed here, never read off a column.
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
  rows_in_range as (
    select *, (live_actual - coalesce(expected_bank_settlement, 0)) as live_variance
    from settle_batch_eff
    where settlement_date between p_date_from and p_date_to
      and (p_effective_status is null or effective_status = p_effective_status)
      and (
        p_has_variance is null
        or not v_can_financials
        or (p_has_variance = true and expected_bank_settlement is not null and (live_actual - coalesce(expected_bank_settlement, 0)) <> 0)
        or (p_has_variance = false and (expected_bank_settlement is null or (live_actual - coalesce(expected_bank_settlement, 0)) = 0))
      )
  ),
  row_summary as (
    select
      count(*) as batches_count,
      count(*) filter (where is_cancelled) as cancelled_count,
      count(*) filter (where not is_cancelled and expected_bank_settlement is not null and live_variance <> 0) as variance_count
    from rows_in_range
  ),
  -- Movements-ledger summary (§85), byte-identical formula to
  -- get_dashboard_summary()'s settle_cte for this single [date_from,date_to]
  -- window (no previous-period comparison needed here). Deliberately scoped
  -- from settle_batch_scope (pre-row-filter set) so the summary ledger
  -- always reflects the SAME batch population the new filters select --
  -- never silently including a batch the filters excluded.
  settle_finalized_scoped as (
    select b.id, b.settlement_date, b.expected_bank_settlement
    from settle_batch_scope b
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
  'Phase 8 §33/§39/§45/§63/§83/§85; Patch 8.1 §41 -- Settlements Report, dual basis unchanged (rows Current Effective, summary Movements-during-Period). Adds effective_status (draft/finalized/reconciled/cancelled, computed server-side from settlement_batch_cancellations existence -- status itself can NEVER be ''cancelled'', 0172''s CHECK constraint) as the correct, WORKING cancelled filter (p_effective_status); p_status (raw status) kept unchanged for backward compatibility. Adds p_route_kind/p_payment_method_id/p_collection_channel_id/p_shipping_carrier_id (read from the batch''s own snapshot columns, 0172 -- never a join to settlement_routes, so a later route-config change never alters a historical batch''s filter membership), p_has_variance (financial, gated), p_provider_statement_reference. Whole-batch store scope (§9). Financial fields require settlements.view_financials. Requires reports.view + settlements.view. SECURITY DEFINER.';

revoke execute on function public.get_settlements_report(date, date, uuid[], uuid, text, text, text, integer, integer, text, uuid, uuid, uuid, text, boolean, text) from public;
grant execute on function public.get_settlements_report(date, date, uuid[], uuid, text, text, text, integer, integer, text, uuid, uuid, uuid, text, boolean, text) to authenticated;

commit;
