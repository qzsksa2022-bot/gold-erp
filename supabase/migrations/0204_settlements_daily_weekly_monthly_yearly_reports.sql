-- ============================================================================
-- Phase 8 — Reports, Dashboard & Exports (0204)
-- get_settlements_report() (§33) and the Daily/Weekly/Monthly/Yearly
-- Management Report family (§34-§37, §44).
-- ============================================================================
-- FREEZE: migrations 0001-0203 untouched. Purely additive.
--
-- get_settlements_report() (§33) uses an intentional DUAL BASIS, explicitly
-- documented per §83, exactly mirroring the split get_dashboard_summary()
-- already uses for this same domain (0200):
--   - Each ROW shows a batch's CURRENT EFFECTIVE facts (live_actual/
--     variance as of right now) -- the same basis list_settlement_batches()
--     (0191) already shows on the Settlements screen, so a user browsing
--     this report sees the same per-batch numbers they'd see there.
--   - The SUMMARY totals are the true MOVEMENTS-DURING-THE-PERIOD ledger
--     (expected recognized at settlement_date, minus/undo at
--     cancellation_business_date, actual from bank movements/reversals at
--     THEIR OWN dates) -- byte-identical formula to
--     get_dashboard_summary()'s settle_cte, so this report's summary and
--     the Dashboard's settlement figures for the same range always agree
--     (§39 Single Reporting Engine).
--
-- The Daily/Weekly/Monthly/Yearly Management Reports (§34-§37) are thin,
-- period-computing WRAPPERS around get_dashboard_summary() -- they compute
-- the correct [date_from, date_to] window for the requested unit (using
-- the canonical riyadh_week_start()/riyadh_week_end() helpers from 0199 for
-- the weekly report, per §5's Riyadh Week Contract) and return
-- get_dashboard_summary()'s own result verbatim (plus a small period-
-- identity envelope). This is a deliberate design choice, not a shortcut:
-- delegating to the ALREADY-VERIFIED Dashboard aggregation guarantees
-- these reports can never numerically drift from the Dashboard (§39) by
-- construction, and get_dashboard_summary() already atomically enforces
-- every permission/redaction/store-scope rule these reports need (§92/§94
-- -- calling it from inside another SECURITY DEFINER STABLE function does
-- not break its own atomic single-statement snapshot guarantee).
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- get_settlements_report() (§33)
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
  v_can_financials boolean;
  v_stores uuid[];
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 500);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_result jsonb;
begin
  if v_actor is null or not public.has_permission('reports.view') or not public.has_permission('settlements.view') then
    raise exception 'ليست لديك صلاحية عرض تقرير التسويات البنكية' using errcode = 'P0001';
  end if;
  perform public._report_validate_date_range(p_date_from, p_date_to);
  v_can_financials := public.has_permission('settlements.view_financials');
  v_stores := public._report_resolve_store_filter(v_actor, p_store_ids);

  with settle_batch_scope as (
    select b.id, b.settlement_number, b.settlement_route_id, b.settlement_date, b.status,
      b.route_name_ar_snapshot, b.route_kind_snapshot,
      b.payment_method_name_snapshot, b.collection_channel_name_snapshot, b.shipping_carrier_name_snapshot,
      b.expected_bank_settlement, b.finalized_at, b.reconciled_at,
      exists (select 1 from public.settlement_batch_cancellations c where c.settlement_batch_id = b.id) as is_cancelled
    from public.settlement_batches b
    where public._report_settlement_batch_in_store_scope(b.id, v_stores)
      and b.status in ('finalized', 'reconciled')
      and (p_settlement_route_id is null or b.settlement_route_id = p_settlement_route_id)
      and (p_status is null or b.status = p_status)
      and (p_search is null or btrim(p_search) = '' or b.settlement_number ilike '%' || btrim(p_search) || '%')
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
  rows_in_range as (
    select *, (live_actual - coalesce(expected_bank_settlement, 0)) as live_variance
    from settle_batch_eff
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
  -- window (no previous-period comparison needed here).
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
        'settlement_date', paged.settlement_date, 'status', paged.status, 'is_cancelled', paged.is_cancelled,
        'route_name', paged.route_name_ar_snapshot, 'route_kind', paged.route_kind_snapshot,
        'payment_method_name', paged.payment_method_name_snapshot,
        'collection_channel_name', paged.collection_channel_name_snapshot,
        'shipping_carrier_name', paged.shipping_carrier_name_snapshot,
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

comment on function public.get_settlements_report(date, date, uuid[], uuid, text, text, text, integer, integer) is
  'Phase 8 §33/§39/§45/§63/§83/§85 -- Settlements Report with an explicit DUAL basis: rows are Current Effective (matching list_settlement_batches()), summary totals are the Movements-during-Period ledger (byte-identical formula to get_dashboard_summary()). Whole-batch store scope (§9). Financial fields require settlements.view_financials. Requires reports.view + settlements.view. SECURITY DEFINER.';

revoke execute on function public.get_settlements_report(date, date, uuid[], uuid, text, text, text, integer, integer) from public;
grant execute on function public.get_settlements_report(date, date, uuid[], uuid, text, text, text, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- get_daily_management_report() (§34)
-- ---------------------------------------------------------------------------
create or replace function public.get_daily_management_report(
  p_date date default null,
  p_store_ids uuid[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_date date := coalesce(p_date, public.business_today());
  v_result jsonb;
begin
  v_result := public.get_dashboard_summary(v_date, v_date, p_store_ids);
  return jsonb_build_object('report_type', 'daily', 'business_date', v_date) || v_result;
end;
$$;

comment on function public.get_daily_management_report(date, uuid[]) is
  'Phase 8 §34/§39 -- Daily Management Report: get_dashboard_summary() for a single business_date, verbatim (guarantees numeric agreement with the Dashboard by construction). SECURITY DEFINER (delegates its own permission/redaction/store-scope enforcement to get_dashboard_summary()).';

revoke execute on function public.get_daily_management_report(date, uuid[]) from public;
grant execute on function public.get_daily_management_report(date, uuid[]) to authenticated;

-- ---------------------------------------------------------------------------
-- get_weekly_management_report() (§35) -- Riyadh Week Contract (§5):
-- Saturday -> Friday, via the single canonical riyadh_week_start()/
-- riyadh_week_end() helpers (0199).
-- ---------------------------------------------------------------------------
create or replace function public.get_weekly_management_report(
  p_reference_date date default null,
  p_store_ids uuid[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_ref date := coalesce(p_reference_date, public.business_today());
  v_week_start date;
  v_week_end date;
  v_result jsonb;
begin
  v_week_start := public.riyadh_week_start(v_ref);
  v_week_end := public.riyadh_week_end(v_ref);
  v_result := public.get_dashboard_summary(v_week_start, v_week_end, p_store_ids);
  return jsonb_build_object('report_type', 'weekly', 'week_start', v_week_start, 'week_end', v_week_end) || v_result;
end;
$$;

comment on function public.get_weekly_management_report(date, uuid[]) is
  'Phase 8 §35/§5/§39 -- Weekly Management Report: get_dashboard_summary() over the Riyadh week (Saturday->Friday, riyadh_week_start()/riyadh_week_end() from 0199) containing p_reference_date, verbatim. SECURITY DEFINER (delegates enforcement to get_dashboard_summary()).';

revoke execute on function public.get_weekly_management_report(date, uuid[]) from public;
grant execute on function public.get_weekly_management_report(date, uuid[]) to authenticated;

-- ---------------------------------------------------------------------------
-- get_monthly_management_report() (§36)
-- ---------------------------------------------------------------------------
create or replace function public.get_monthly_management_report(
  p_year integer default null,
  p_month integer default null,
  p_store_ids uuid[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today date := public.business_today();
  v_year integer := coalesce(p_year, extract(year from v_today)::integer);
  v_month integer := coalesce(p_month, extract(month from v_today)::integer);
  v_month_start date;
  v_month_end date;
  v_result jsonb;
begin
  if v_month < 1 or v_month > 12 then
    raise exception 'الشهر يجب أن يكون بين 1 و 12' using errcode = 'P0001';
  end if;
  v_month_start := make_date(v_year, v_month, 1);
  v_month_end := (v_month_start + interval '1 month - 1 day')::date;
  v_result := public.get_dashboard_summary(v_month_start, v_month_end, p_store_ids);
  return jsonb_build_object('report_type', 'monthly', 'year', v_year, 'month', v_month, 'month_start', v_month_start, 'month_end', v_month_end) || v_result;
end;
$$;

comment on function public.get_monthly_management_report(integer, integer, uuid[]) is
  'Phase 8 §36/§39 -- Monthly Management Report: get_dashboard_summary() over the full calendar month [year,month], verbatim. SECURITY DEFINER (delegates enforcement to get_dashboard_summary()).';

revoke execute on function public.get_monthly_management_report(integer, integer, uuid[]) from public;
grant execute on function public.get_monthly_management_report(integer, integer, uuid[]) to authenticated;

-- ---------------------------------------------------------------------------
-- get_yearly_management_report() (§37)
-- ---------------------------------------------------------------------------
create or replace function public.get_yearly_management_report(
  p_year integer default null,
  p_store_ids uuid[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_year integer := coalesce(p_year, extract(year from public.business_today())::integer);
  v_year_start date;
  v_year_end date;
  v_result jsonb;
begin
  v_year_start := make_date(v_year, 1, 1);
  v_year_end := make_date(v_year, 12, 31);
  v_result := public.get_dashboard_summary(v_year_start, v_year_end, p_store_ids);
  return jsonb_build_object('report_type', 'yearly', 'year', v_year, 'year_start', v_year_start, 'year_end', v_year_end) || v_result;
end;
$$;

comment on function public.get_yearly_management_report(integer, uuid[]) is
  'Phase 8 §37/§39 -- Yearly Management Report: get_dashboard_summary() over the full calendar year, verbatim. SECURITY DEFINER (delegates enforcement to get_dashboard_summary()).';

revoke execute on function public.get_yearly_management_report(integer, uuid[]) from public;
grant execute on function public.get_yearly_management_report(integer, uuid[]) to authenticated;

commit;
