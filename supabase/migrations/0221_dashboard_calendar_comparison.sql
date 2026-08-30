-- ============================================================================
-- Phase 8 — Final Closure Hotfix 8.1.2 — §1-5 CRITICAL:
-- Calendar-aware Dashboard comparison periods + a canonical, non-duplicating
-- comparison wrapper.
-- ============================================================================
-- Migrations 0001-0220 are FROZEN. This migration only ADDS 0221+.
--
-- §1 CRITICAL bug: get_dashboard_summary() (0205) always compares a range
-- against report_previous_period()'s "immediately preceding EQUAL-LENGTH
-- range" -- correct for a genuine Custom Range / last_7/last_30, but WRONG
-- for the calendar presets the Dashboard actually offers:
--   - "This Week" (week-to-date, Sat..today) must compare against the FULL
--     PREVIOUS Riyadh week (Sat->Fri), not just the elapsed-so-far slice of
--     it.
--   - "This Month"/"Last Month" must compare against the full PREVIOUS
--     CALENDAR month (a different day-count is fine and expected -- March
--     (31) vs February (28/29)).
--   - "This Year"/"Last Year" must compare against the full PREVIOUS
--     CALENDAR year (365 vs 366 days in a leap year is fine and expected --
--     2024 must compare to 2023-01-01..2023-12-31, never a 366-day window
--     that bleeds into 2022).
--   - "Today"/"Yesterday"/"Last 7/30 days"/Custom already get the right
--     answer from equal-length-preceding (a 1-day range's equal-length
--     predecessor IS "the day before"), so those are left exactly as they
--     were -- no new branch needed for them.
--
-- §2: this fix does NOT touch get_dashboard_summary() itself (still used
-- standalone, still correct for the generic/custom case) and does NOT
-- duplicate a single line of its financial aggregation. Instead:
--   - report_calendar_comparison_period() (below) is PURE date arithmetic
--     (no table reads at all) -- independently unit-testable per §44's
--     calendar test matrix (A-H), and reused unchanged by the Weekly/
--     Monthly/Yearly Management Reports (0222) so a "weekly"/"monthly"/
--     "yearly" report unit and the Dashboard's own this_week/this_month/
--     this_year presets always agree on what "the previous period" means.
--   - get_dashboard_summary_with_comparison() (below) calls the CANONICAL
--     get_dashboard_summary() exactly TWICE -- once for the caller's
--     current range, once for the calendar-correct previous range computed
--     above -- and takes ONLY the "current-period" values back out of each
--     call (never that call's own internal previous/change/pct_change,
--     which reflects ITS OWN equal-length-preceding period, not the
--     calendar-aware one this wrapper computes). previous_<field>/
--     <field>_change/<field>_pct_change are then generically recomputed
--     from those two already-authorized numbers -- this wrapper never reads
--     sales_orders/sales_returns/shipments/etc. directly, and never
--     hardcodes a single domain formula (§2 item 7). Both RPC calls happen
--     inside this ONE outer SECURITY DEFINER STABLE function, so -- called
--     as a single top-level statement -- they share one MVCC snapshot
--     (§2 item "Snapshot DB متسقة").
--   - True key-absence (§2 item 6) is preserved structurally:
--     _report_recompute_comparison() only ever touches keys that are
--     ALREADY present in the current-period response (a field/domain the
--     actor lacks permission for was never in that jsonb object to begin
--     with, and stays absent).
--
-- §2's suggested literal signature `get_dashboard_summary_with_comparison(
-- current_date_from, current_date_to, previous_date_from, previous_date_to,
-- store_ids)` is deliberately NOT what ships here ("أو equivalent" is
-- explicitly sanctioned by the spec) -- taking the previous range as two
-- more raw dates would force the CALLER (TypeScript) to duplicate this same
-- calendar arithmetic to ever get calendar-correct dates in, risking silent
-- client/server disagreement (the exact class of bug this migration exists
-- to fix, just moved one layer up). Instead the wrapper takes the SAME
-- `p_period_preset` key the URL now carries (§3, wired in application code)
-- and resolves the previous range itself, in the one place all of this
-- project's other date logic already lives (SQL) -- one round trip, one
-- source of truth.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- report_calendar_comparison_period() (§1/§5) -- pure date arithmetic, no
-- table reads. p_preset accepts every Dashboard URL preset key
-- (today/yesterday/last7/last30/this_week/last_week/this_month/last_month/
-- this_year/last_year/custom) PLUS the four Management Report unit synonyms
-- (daily/weekly/monthly/yearly) so 0222's management reports can call this
-- SAME function. Any other/NULL preset falls back to the pre-existing
-- generic "immediately preceding equal-length range"
-- (report_previous_period, 0199) -- correct already for a single day and
-- for any genuine custom range.
--
-- p_date_from/p_date_to are the CALLER'S OWN already-resolved current
-- range (e.g. "this_week" = [riyadh_week_start(today), today] --
-- week-to-date, per period-presets.tsx) -- this function does not need to
-- re-derive "today"; it only needs to know which CALENDAR UNIT p_date_from
-- falls inside, which works identically whether the caller's current range
-- is partial (week/month/year-to-date) or a full closed calendar unit
-- (last_week/last_month/last_year) -- both start their range on the SAME
-- calendar boundary (a Saturday / the 1st of a month / January 1st), so
-- "the calendar unit immediately before the one p_date_from falls in" is
-- the right previous range for both this_X and last_X alike (§1's own
-- table: This Week -> Previous Riyadh Week; Last Week -> the week before
-- Last Week -- the SAME previous-week formula answers both).
-- ---------------------------------------------------------------------------
create or replace function public.report_calendar_comparison_period(
  p_preset text,
  p_date_from date,
  p_date_to date,
  out prev_date_from date,
  out prev_date_to date
)
language plpgsql
immutable
as $$
declare
  v_week_start date;
begin
  if p_date_from is null or p_date_to is null then
    raise exception 'date_from/date_to مطلوبة' using errcode = 'P0001';
  end if;

  case p_preset
    when 'this_week', 'last_week', 'weekly' then
      -- The full Riyadh week (Saturday->Friday, riyadh_week_start() 0199)
      -- immediately before the week p_date_from falls in.
      v_week_start := public.riyadh_week_start(p_date_from);
      prev_date_from := v_week_start - 7;
      prev_date_to := v_week_start - 1;
    when 'this_month', 'last_month', 'monthly' then
      -- The full calendar month immediately before the month p_date_from
      -- falls in -- correct regardless of either month's day count
      -- (March/February, leap-year February included).
      prev_date_from := (date_trunc('month', p_date_from - interval '1 day'))::date;
      prev_date_to := (date_trunc('month', p_date_from))::date - 1;
    when 'this_year', 'last_year', 'yearly' then
      -- The full calendar year immediately before the year p_date_from
      -- falls in -- correct regardless of either year's day count (a leap
      -- year's 366 days never bleeds one day into the year before that).
      prev_date_from := make_date(extract(year from p_date_from)::int - 1, 1, 1);
      prev_date_to := make_date(extract(year from p_date_from)::int - 1, 12, 31);
    else
      -- today/yesterday/last7/last30/daily/custom/NULL: the immediately
      -- preceding equal-length range is already exactly right for these
      -- (a single day's equal-length predecessor IS "the day before"; a
      -- genuine Custom Range has no calendar unit to align to).
      select rp.prev_date_from, rp.prev_date_to
        into prev_date_from, prev_date_to
      from public.report_previous_period(p_date_from, p_date_to) rp;
  end case;
end;
$$;

comment on function public.report_calendar_comparison_period(text, date, date) is
  'Hotfix 8.1.2 §1/§5 -- calendar-aware comparison period resolver. Pure date arithmetic (no table reads). this_week/last_week/weekly -> full previous Riyadh week (Sat->Fri). this_month/last_month/monthly -> full previous calendar month. this_year/last_year/yearly -> full previous calendar year. Any other preset (today/yesterday/last7/last30/daily/custom/NULL) -> report_previous_period()''s immediately-preceding equal-length range (0199), already correct for those. Reused verbatim by get_dashboard_summary_with_comparison() below and by the Weekly/Monthly/Yearly Management Reports (0222) so every caller agrees on what "the previous period" means for a given unit.';

revoke execute on function public.report_calendar_comparison_period(text, date, date) from public;
grant execute on function public.report_calendar_comparison_period(text, date, date) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- _report_recompute_comparison() (internal, §2) -- generic jsonb surgery
-- over ONE domain sub-object (e.g. the "sales"/"returns"/... value inside
-- get_dashboard_summary()'s own result, never the whole top-level envelope
-- -- the envelope's OWN previous_date_from/previous_date_to are metadata,
-- not a comparable numeric metric, and must never be run through this).
--
-- For every "previous_<base>" key already present in p_cur (i.e. every
-- metric get_dashboard_summary() itself tracks a comparison for), replace
-- its value with p_prev's OWN "<base>" value (that second call's "current"
-- figure for the SAME field) and, only when p_cur also already carries a
-- "<base>_change"/"<base>_pct_change" key (some fields intentionally have
-- neither, e.g. settlements.variance has no _pct_change; adjustments.
-- customer_charges has neither -- both left exactly as originally
-- structured), recompute that diff from the two now-current-period values.
-- The change value''s JSON type (string vs number) is preserved by
-- inspecting p_cur''s OWN existing type for that key -- money fields were
-- always written as text (§40/§41 no-JS-float contract), count fields as
-- integers -- this function never decides that itself, it only mirrors
-- what get_dashboard_summary() already chose.
--
-- Every OTHER key in p_cur (the domain''s own current-period figures, any
-- "_basis"/formula-label string, count-only fields with no previous_ pair
-- at all such as settlements.cancelled_count) is left completely untouched
-- -- v_result starts as a copy of p_cur, so absence/presence of every key
-- other than the previous_/change/pct_change triad is preserved exactly.
-- ---------------------------------------------------------------------------
create or replace function public._report_recompute_comparison(p_cur jsonb, p_prev jsonb)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_result jsonb := coalesce(p_cur, '{}'::jsonb);
  v_key text;
  v_base text;
  v_cur_val numeric;
  v_prev_val numeric;
  v_change_key text;
  v_pct_key text;
  v_ok boolean;
begin
  if p_cur is null then
    return '{}'::jsonb;
  end if;

  for v_key in select jsonb_object_keys(p_cur) loop
    if left(v_key, 9) = 'previous_' then
      v_base := substring(v_key from 10);
      continue when not (p_cur ? v_base);

      v_result := jsonb_set(v_result, array[v_key], coalesce(p_prev -> v_base, 'null'::jsonb), true);

      v_ok := true;
      begin
        v_cur_val := (p_cur ->> v_base)::numeric;
        v_prev_val := (p_prev ->> v_base)::numeric;
      exception when others then
        v_ok := false;
      end;

      if v_ok and v_cur_val is not null then
        v_change_key := v_base || '_change';
        if p_cur ? v_change_key then
          if jsonb_typeof(p_cur -> v_change_key) = 'string' then
            v_result := jsonb_set(v_result, array[v_change_key], to_jsonb((v_cur_val - coalesce(v_prev_val, 0))::text), true);
          else
            v_result := jsonb_set(v_result, array[v_change_key], to_jsonb((v_cur_val - coalesce(v_prev_val, 0))::int), true);
          end if;
        end if;

        v_pct_key := v_base || '_pct_change';
        if p_cur ? v_pct_key then
          -- report_pct_change() returns SQL NULL (not JSON null) when
          -- p_previous is NULL/0 (0199 §18/§43 null-safe contract), and
          -- to_jsonb(NULL) is itself SQL NULL -- jsonb_set() is STRICT, so
          -- passing that raw SQL NULL as new_value would silently collapse
          -- the ENTIRE v_result to NULL (poisoning every other key already
          -- written this iteration and every iteration after it), not just
          -- this one field. coalesce(..., 'null'::jsonb) converts that "no
          -- comparison possible" case into an explicit JSON null value
          -- instead, which jsonb_set accepts as a normal (non-strict-
          -- triggering) argument.
          v_result := jsonb_set(v_result, array[v_pct_key], coalesce(to_jsonb(public.report_pct_change(v_cur_val, v_prev_val)), 'null'::jsonb), true);
        end if;
      end if;
    end if;
  end loop;

  return v_result;
end;
$$;

comment on function public._report_recompute_comparison(jsonb, jsonb) is
  'Hotfix 8.1.2 §2 (internal) -- generic jsonb surgery over ONE domain sub-object: every "previous_<base>" key already present in p_cur is overwritten with p_prev''s own "<base>" value, and any co-present "<base>_change"/"<base>_pct_change" key is recomputed from the two now-current-period numbers (type-preserving: text vs number, mirroring whichever get_dashboard_summary() itself already chose). Every other key is left untouched -- true key-absence (§79/§2 item 6) is preserved structurally since only keys already in p_cur are ever touched. Not directly callable by authenticated.';

revoke execute on function public._report_recompute_comparison(jsonb, jsonb) from public;

-- ---------------------------------------------------------------------------
-- get_dashboard_summary_with_comparison() (§2) -- the single outer RPC the
-- Dashboard/Management Reports call. Delegates to the CANONICAL
-- get_dashboard_summary() exactly twice; recomputes nothing financial
-- itself.
-- ---------------------------------------------------------------------------
create or replace function public.get_dashboard_summary_with_comparison(
  p_date_from date,
  p_date_to date,
  p_period_preset text default null,
  p_store_ids uuid[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_prev_from date;
  v_prev_to date;
  v_current jsonb;
  v_previous jsonb;
  v_result jsonb;
  v_domain text;
begin
  -- No permission/date-range check of its OWN: both calls below run the
  -- canonical get_dashboard_summary(), which already enforces every one of
  -- those atomically for this exact actor -- duplicating the check here
  -- would be exactly the kind of parallel copy §2 forbids.
  select cp.prev_date_from, cp.prev_date_to
    into v_prev_from, v_prev_to
  from public.report_calendar_comparison_period(p_period_preset, p_date_from, p_date_to) cp;

  v_current := public.get_dashboard_summary(p_date_from, p_date_to, p_store_ids);
  v_previous := public.get_dashboard_summary(v_prev_from, v_prev_to, p_store_ids);

  v_result := jsonb_build_object(
    'date_from', p_date_from,
    'date_to', p_date_to,
    'period_preset', p_period_preset,
    'previous_date_from', v_prev_from,
    'previous_date_to', v_prev_to,
    'comparison_mode', 'calendar_aware',
    'store_ids', v_current -> 'store_ids',
    'basis', v_current -> 'basis',
    'contains_open_business_day', v_current -> 'contains_open_business_day'
  );

  foreach v_domain in array array['sales', 'returns', 'shipping', 'adjustments', 'settlements', 'net_operating_return'] loop
    if v_current ? v_domain then
      v_result := v_result || jsonb_build_object(v_domain, public._report_recompute_comparison(v_current -> v_domain, v_previous -> v_domain));
    end if;
  end loop;

  return v_result;
end;
$$;

comment on function public.get_dashboard_summary_with_comparison(date, date, text, uuid[]) is
  'Hotfix 8.1.2 §1-5 CRITICAL -- calendar-aware Dashboard/Management comparison. Calls the CANONICAL get_dashboard_summary() exactly twice (current range, then the calendar-correct previous range from report_calendar_comparison_period()) and restructures the two results via _report_recompute_comparison() -- never re-derives a single financial figure itself, never duplicates a domain formula. Both calls share one MVCC snapshot (single outer STABLE function, called as one top-level statement). Permission/redaction/store-scope enforcement is entirely delegated to get_dashboard_summary() (called twice, same actor, same result). SECURITY DEFINER.';

revoke execute on function public.get_dashboard_summary_with_comparison(date, date, text, uuid[]) from public;
grant execute on function public.get_dashboard_summary_with_comparison(date, date, text, uuid[]) to authenticated;

commit;
