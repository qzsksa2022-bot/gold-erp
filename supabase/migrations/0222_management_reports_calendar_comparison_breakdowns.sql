-- ============================================================================
-- Phase 8 — Final Closure Hotfix 8.1.2 — §6-15:
-- Weekly/Monthly/Yearly Management Reports gain a real period breakdown
-- (currently missing entirely) and ALL FOUR Management Reports (Daily/
-- Weekly/Monthly/Yearly) switch from get_dashboard_summary() to the new
-- calendar-aware get_dashboard_summary_with_comparison() (0221), so their
-- own previous-period comparison is calendar-correct (§1) instead of the
-- generic equal-length-preceding range.
-- ============================================================================
-- Migrations 0001-0221 are FROZEN. This migration only ADDS 0222+.
--
-- Body-only change for all four functions -- NONE of their parameter lists
-- change, so every one is CREATE OR REPLACE directly (§0, no DROP needed).
--
-- §7 breakdown contract: reuses get_dashboard_trends() (0205) UNCHANGED --
-- no new aggregation formula, no duplicated financial logic, exactly the
-- same "delegate to an already-verified function" discipline §39/§92/§94
-- established for these reports from the start.
--   - Weekly  -> get_dashboard_trends(week_start,  week_end,  stores, 'day')   => 7 day buckets (Sat..Fri)
--   - Monthly -> get_dashboard_trends(month_start, month_end, stores, 'day')   => all days in that month (28-31)
--   - Yearly  -> get_dashboard_trends(year_start,  year_end,  stores, 'month') => 12 month buckets
--   - Daily has no breakdown (a single business_date IS the smallest report
--     unit already -- nothing to break down further).
--
-- §1/§8 comparison contract: each report now calls
-- get_dashboard_summary_with_comparison(date_from, date_to, p_period_preset,
-- store_ids) with the SAME preset synonym report_calendar_comparison_period()
-- (0221) already recognises for that unit ('weekly'/'monthly'/'yearly';
-- 'daily' intentionally falls to that function's default branch --
-- report_previous_period()'s immediately-preceding-equal-length-range is
-- already exactly right for a single day, no new branch needed, mirroring
-- §1's own "Today/Yesterday...already get the right answer" carve-out).
-- The comparison wrapper's own envelope keys (date_from/date_to/
-- previous_date_from/previous_date_to/period_preset/comparison_mode/basis)
-- are merged in via `||` AFTER this report's own envelope object -- their
-- values are identical to what this report's own v_*_start/v_*_end already
-- computed, so nothing is lost or contradicted, and §41's "explicit basis
-- indicator" requirement is satisfied for free (comparison wrapper already
-- forwards get_dashboard_summary()'s own top-level "basis" key verbatim).
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- get_daily_management_report() (§34, unchanged breakdown-wise -- §6-15)
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
  v_result := public.get_dashboard_summary_with_comparison(v_date, v_date, 'daily', p_store_ids);
  return jsonb_build_object('report_type', 'daily', 'business_date', v_date) || v_result;
end;
$$;

comment on function public.get_daily_management_report(date, uuid[]) is
  'Phase 8 §34/§39; Hotfix 8.1.2 §1/§6-15 -- Daily Management Report: get_dashboard_summary_with_comparison() (0221, period_preset=''daily'') for a single business_date, verbatim -- calendar-aware wrapper collapses to report_previous_period()''s equal-length-preceding range for a single day, already correct. No breakdown (daily IS the smallest unit). SECURITY DEFINER (delegates enforcement to get_dashboard_summary()).';

revoke execute on function public.get_daily_management_report(date, uuid[]) from public;
grant execute on function public.get_daily_management_report(date, uuid[]) to authenticated;

-- ---------------------------------------------------------------------------
-- get_weekly_management_report() (§35/§5) + §6-15 daily breakdown
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
  v_breakdown jsonb;
begin
  v_week_start := public.riyadh_week_start(v_ref);
  v_week_end := public.riyadh_week_end(v_ref);
  v_result := public.get_dashboard_summary_with_comparison(v_week_start, v_week_end, 'weekly', p_store_ids);
  v_breakdown := public.get_dashboard_trends(v_week_start, v_week_end, p_store_ids, 'day');
  return jsonb_build_object('report_type', 'weekly', 'week_start', v_week_start, 'week_end', v_week_end) || v_result
    || jsonb_build_object('breakdown', v_breakdown -> 'buckets', 'breakdown_granularity', 'day');
end;
$$;

comment on function public.get_weekly_management_report(date, uuid[]) is
  'Phase 8 §35/§5/§39; Hotfix 8.1.2 §1/§6-15 -- Weekly Management Report: get_dashboard_summary_with_comparison() (0221, period_preset=''weekly'' -> full previous Riyadh week) over the Riyadh week (Sat->Fri, riyadh_week_start()/riyadh_week_end()) containing p_reference_date, plus a day-granularity breakdown (7 buckets) from get_dashboard_trends() (0205, unchanged -- no duplicated aggregation). SECURITY DEFINER.';

revoke execute on function public.get_weekly_management_report(date, uuid[]) from public;
grant execute on function public.get_weekly_management_report(date, uuid[]) to authenticated;

-- ---------------------------------------------------------------------------
-- get_monthly_management_report() (§36) + §6-15 daily breakdown
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
  v_breakdown jsonb;
begin
  if v_month < 1 or v_month > 12 then
    raise exception 'الشهر يجب أن يكون بين 1 و 12' using errcode = 'P0001';
  end if;
  v_month_start := make_date(v_year, v_month, 1);
  v_month_end := (v_month_start + interval '1 month - 1 day')::date;
  v_result := public.get_dashboard_summary_with_comparison(v_month_start, v_month_end, 'monthly', p_store_ids);
  v_breakdown := public.get_dashboard_trends(v_month_start, v_month_end, p_store_ids, 'day');
  return jsonb_build_object('report_type', 'monthly', 'year', v_year, 'month', v_month, 'month_start', v_month_start, 'month_end', v_month_end) || v_result
    || jsonb_build_object('breakdown', v_breakdown -> 'buckets', 'breakdown_granularity', 'day');
end;
$$;

comment on function public.get_monthly_management_report(integer, integer, uuid[]) is
  'Phase 8 §36/§39; Hotfix 8.1.2 §1/§6-15 -- Monthly Management Report: get_dashboard_summary_with_comparison() (0221, period_preset=''monthly'' -> full previous calendar month, any day-count) over the full calendar month [year,month], plus a day-granularity breakdown (one bucket per day in the month, 28-31) from get_dashboard_trends() (0205, unchanged). SECURITY DEFINER.';

revoke execute on function public.get_monthly_management_report(integer, integer, uuid[]) from public;
grant execute on function public.get_monthly_management_report(integer, integer, uuid[]) to authenticated;

-- ---------------------------------------------------------------------------
-- get_yearly_management_report() (§37) + §6-15 monthly breakdown
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
  v_breakdown jsonb;
begin
  v_year_start := make_date(v_year, 1, 1);
  v_year_end := make_date(v_year, 12, 31);
  v_result := public.get_dashboard_summary_with_comparison(v_year_start, v_year_end, 'yearly', p_store_ids);
  v_breakdown := public.get_dashboard_trends(v_year_start, v_year_end, p_store_ids, 'month');
  return jsonb_build_object('report_type', 'yearly', 'year', v_year, 'year_start', v_year_start, 'year_end', v_year_end) || v_result
    || jsonb_build_object('breakdown', v_breakdown -> 'buckets', 'breakdown_granularity', 'month');
end;
$$;

comment on function public.get_yearly_management_report(integer, uuid[]) is
  'Phase 8 §37/§39; Hotfix 8.1.2 §1/§6-15 -- Yearly Management Report: get_dashboard_summary_with_comparison() (0221, period_preset=''yearly'' -> full previous calendar year, any day-count/leap-year) over the full calendar year, plus a month-granularity breakdown (12 buckets) from get_dashboard_trends() (0205, unchanged). SECURITY DEFINER.';

revoke execute on function public.get_yearly_management_report(integer, uuid[]) from public;
grant execute on function public.get_yearly_management_report(integer, uuid[]) to authenticated;

commit;
