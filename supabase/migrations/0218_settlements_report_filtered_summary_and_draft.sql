-- ============================================================================
-- Phase 8 — Final Integrity Hotfix 8.1.1 — §28-31 CRITICAL:
-- get_settlements_report() Rows and the financial Summary must share the
-- SAME filtered batch population; a real, working Draft effective_status;
-- has_variance must be explicitly REJECTED (never silently ignored) for an
-- actor lacking settlements.view_financials.
-- ============================================================================
-- Migrations 0001-0217 are FROZEN. This migration only ADDS 0218+.
-- get_settlements_report()'s signature is UNCHANGED from 0212 -- this fix is
-- body-only, so CREATE OR REPLACE is used directly (no DROP needed, §0).
--
-- §28 CRITICAL: 0212's `rows_in_range` correctly applied p_effective_status/
-- p_has_variance, but the financial `ledger` (feeding `summary`'s expected/
-- actual/variance) was built from `settle_finalized_scoped`, itself derived
-- from `settle_batch_scope` -- the PRE-effective_status/has_variance-filter
-- set. Result: Rows could show "Cancelled only" while the Summary's
-- Expected/Actual/Variance still included every OTHER batch too. Screen
-- total must equal the filtered dataset (§28's own requirement).
--
-- Fix (§29): a single `filtered_batch_scope` CTE now applies EVERY filter
-- (route/route_kind/payment method/channel/carrier/provider ref/search/
-- effective_status/has_variance/store) exactly once; `rows_in_range` and the
-- financial ledger's batch source BOTH read from this ONE set of batch IDs
-- (`rows_in_range` further narrows by the settlement_date window; the
-- ledger additionally excludes any non-finalized/non-reconciled status --
-- see §30 below -- since a batch can only be in filtered_batch_scope with
-- status='draft' when p_effective_status='draft' was explicitly requested).
-- The ledger's own per-movement/reversal/cancellation EVENT dates are
-- untouched (§29: "Financial events remain Event-Date based -- do not
-- change their dates").
--
-- §30: settle_batch_scope's base status filter hardcoded
-- `b.status in ('finalized', 'reconciled')`, making p_effective_status=
-- 'draft' dead code (0 rows, always) even though it passed its own
-- value-list validation. Fixed: the base scope now includes status='draft'
-- batches ONLY when p_effective_status='draft' was explicitly requested
-- (never by default -- the pre-existing default population, finalized/
-- reconciled only, is unchanged for every other/no effective_status value).
-- A draft batch''s effective_status is 'draft' by construction (is_cancelled
-- is always false pre-finalize, so the existing `case when is_cancelled
-- then ''cancelled'' else status end` expression already yields ''draft''
-- correctly with no formula change needed). Draft batches structurally have
-- no settlement_bank_movement_events (recorded only from finalize onward)
-- and no expected_bank_settlement (computed at finalize) -- so restricting
-- the financial ledger''s batch source to status in (''finalized'',
-- ''reconciled'') (§29 above) makes "Draft contributes zero financial
-- total" both explicit/self-documenting AND structurally guaranteed, never
-- merely incidental.
--
-- §31: an actor without settlements.view_financials sending p_has_variance
-- (true or false) previously had the filter SILENTLY ignored (`or not
-- v_can_financials` inside the WHERE clause) -- the response gave no signal
-- the filter was dropped. Fixed: such a request is now explicitly REJECTED
-- (raise exception) rather than silently producing an unfiltered result
-- that could be misread as "no batches have variance."
-- ============================================================================
begin;

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
  -- §31: reject the permission-sensitive filter explicitly -- never let the
  -- response shape imply it was silently applied (or silently dropped).
  if p_has_variance is not null and not v_can_financials then
    raise exception 'ليست لديك صلاحية استخدام مرشح الفروقات المالية' using errcode = 'P0001';
  end if;
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
      -- §30: draft-status batches enter scope ONLY when explicitly
      -- requested via p_effective_status='draft' -- the default population
      -- (every other/no effective_status value) is unchanged: finalized/
      -- reconciled only, exactly as before this fix.
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
      -- §41 (Patch 8.1, preserved): effective_status a "Cancelled" filter can
      -- actually match -- status is structurally never 'cancelled' (0172's
      -- CHECK constraint), so this is computed here, never read off a
      -- column. For a draft batch (is_cancelled is always false pre-
      -- finalize), this correctly yields 'draft' with no formula change.
      (case when sbs.is_cancelled then 'cancelled' else sbs.status end) as effective_status,
      -- A draft batch structurally has no bank movement events yet (they
      -- are only ever recorded from finalize onward) -- this subquery
      -- naturally evaluates to 0 for one, which is correct, but the
      -- financial ledger below additionally EXCLUDES draft batches
      -- explicitly (§30) so "zero financial contribution" is guaranteed by
      -- construction, not merely incidental to today's event data.
      coalesce((select sum(e.amount) from public.settlement_bank_movement_events e where e.settlement_batch_id = sbs.id), 0)
        + coalesce((
            select sum(rv.amount_impact)
            from public.settlement_bank_movement_reversals rv
            join public.settlement_bank_movement_events e2 on e2.id = rv.bank_movement_event_id
            where e2.settlement_batch_id = sbs.id
          ), 0) as live_actual
    from settle_batch_scope sbs
  ),
  -- §28-29 CRITICAL FIX: ONE filtered population -- effective_status AND
  -- has_variance are applied exactly ONCE here -- consumed identically by
  -- both `rows_in_range` (date-windowed) and the financial ledger below
  -- (further restricted to non-draft status), so the Rows the user sees and
  -- the Summary total they're shown can never disagree about which batches
  -- are included.
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
  -- Movements-ledger summary (§85), byte-identical formula to
  -- get_dashboard_summary()'s settle_cte for this single [date_from,date_to]
  -- window. §30: explicitly restricted to finalized/reconciled batches --
  -- a status='draft' row can only ever be present in filtered_batch_scope
  -- when p_effective_status='draft' was requested, and must NEVER enter the
  -- financial ledger regardless (Draft = zero financial contribution,
  -- always, by construction -- not merely because no events exist yet).
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
  'Phase 8 §33/§39/§45/§63/§83/§85; Patch 8.1 §41; Hotfix 8.1.1 §28-31 CRITICAL -- Settlements Report. Rows and the financial Summary now share ONE filtered_batch_scope (route/route_kind/payment method/channel/carrier/provider ref/search/effective_status/has_variance/store applied exactly once) -- the screen total always equals the filtered dataset (§28). p_effective_status=''draft'' is now a real, working filter (base scope admits draft-status batches ONLY when explicitly requested); the financial ledger explicitly excludes any non-finalized/non-reconciled batch, so Draft NEVER contributes to Expected/Actual/Variance, by construction (§30). p_has_variance from an actor lacking settlements.view_financials is explicitly REJECTED (exception), never silently ignored (§31). Financial fields require settlements.view_financials. Requires reports.view + settlements.view. SECURITY DEFINER.';

revoke execute on function public.get_settlements_report(date, date, uuid[], uuid, text, text, text, integer, integer, text, uuid, uuid, uuid, text, boolean, text) from public;
grant execute on function public.get_settlements_report(date, date, uuid[], uuid, text, text, text, integer, integer, text, uuid, uuid, uuid, text, boolean, text) to authenticated;

commit;
