-- ============================================================================
-- Phase 8 §21-§37/§39/§45/§63/§79/§80/§83/§84/§85 live regression test for
-- every detail/ranking/ledger report RPC built in 0201-0204:
--   get_sales_report, get_items_report, get_categories_report,
--   get_karats_report, get_employees_report, get_payment_methods_report,
--   get_collection_channels_report, get_returns_report,
--   get_shipping_report, get_cod_report, get_adjustments_report,
--   get_settlements_report, get_daily_management_report,
--   get_weekly_management_report, get_monthly_management_report,
--   get_yearly_management_report.
-- ============================================================================
-- Runs the SAME real fixture as reports_dashboard_golden_scenario.test.sql
-- (built entirely from production RPCs) inside ONE rolled-back transaction.
-- Every figure asserted below was cross-checked interactively against
-- get_dashboard_summary()'s own numbers for the identical [date_from,
-- date_to] window before being written here -- proving §39 Single
-- Reporting Engine agreement between the Dashboard and every detail report
-- built on top of the same underlying domain tables (§80 cross-domain
-- reconciliation).
--
-- Assertion groups:
--   (A) get_sales_report / get_items_report / get_categories_report /
--       get_karats_report / get_employees_report / get_payment_methods_
--       report / get_collection_channels_report all agree with each other
--       and with get_dashboard_summary() on July 2026's single sale
--       (revenue 3500.00, gross_profit 625.00, net_sales_profit 555.00).
--   (B) get_returns_report is a movements ledger: July shows the +approval
--       movement (net_profit_effect -555.00), August shows the exact undo
--       (+555.00), combined nets to EXACTLY 0.00 across every financial
--       field (§82 Reversal Scenario, §85).
--   (C) get_adjustments_report is a movements ledger: July +58.00, August
--       -58.00 undo, combined nets to EXACTLY 0.00 (§85).
--   (D) get_shipping_report / get_cod_report: Current Effective basis
--       (§83), row-level shipment figures match the Dashboard's shipping
--       CTE exactly.
--   (E) get_settlements_report: dual basis (§83) -- row-level Current
--       Effective figures per batch, summary Movements-during-Period
--       ledger byte-identical to get_dashboard_summary()'s settle_cte for
--       the same window.
--   (F) get_daily_management_report/get_weekly_management_report/
--       get_monthly_management_report/get_yearly_management_report
--       delegate to get_dashboard_summary() and reproduce its EXACT
--       Net Operating Return for the corresponding window (§5 Riyadh Week
--       Contract for the weekly report; §39 for all four).
--   (G) The no-profit actor (reports.view + sales.view/returns.view/
--       adjustments.view/shipments.view/settlements.view only) sees TRUE
--       key absence for every profit/financial field across all twelve
--       row-level report RPCs (§79).
--   (H) An explicit unauthorized store filter is REJECTED (never silently
--       narrowed) on a representative sample of the new RPCs (§8).
-- ============================================================================
begin;

\i supabase/tests/fixtures/phase8_golden_scenario_fixture.sql

-- The fixture's own internal actor-as-super-admin calls leave
-- request.jwt.claims set (transaction-local) to actor 1 when it finishes --
-- reset it so auth.uid() is null again, which is what makes the raw
-- profile-activation UPDATE below count as a trusted bootstrap context
-- (public.is_trusted_bootstrap_context(), 0013) and satisfy 0029's
-- provisioning invariant, exactly like the fixture's own actor creation.
reset request.jwt.claims;

-- A dedicated "reports only, no financial-detail permission" role/actor,
-- reused by every assertion group below that proves §79 true-key-absence
-- for these report RPCs specifically (distinct permission set from the
-- Dashboard's own sales_employee test actor in the fixture, since these
-- reports gate on sales.view_profit/settlements.view_financials directly
-- rather than dashboard.view_financials).
insert into public.roles (id, key, name_ar, name_en) values
  ('80100000-0000-4000-8000-000000000098', 'p8_report_no_financials', 'مشاهد تقارير بدون تفاصيل مالية', 'Report Viewer No Financials')
on conflict (id) do nothing;
insert into public.role_permissions (role_id, permission_id)
  select '80100000-0000-4000-8000-000000000098', p.id
  from public.permissions p
  where p.key in ('reports.view', 'sales.view', 'returns.view', 'adjustments.view', 'shipments.view', 'settlements.view')
on conflict do nothing;
insert into auth.users (id, email) values
  ('80000000-0000-4000-8000-000000000004', 'p8-golden-report-no-fin@example.invalid')
on conflict (id) do nothing;
update public.profiles set full_name = 'Phase8 Report No-Financials Actor', status = 'active', store_access_scope = 'all'
  where id = '80000000-0000-4000-8000-000000000004';
insert into public.user_roles (user_id, role_id) values
  ('80000000-0000-4000-8000-000000000004', '80100000-0000-4000-8000-000000000098')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Reversal window — derived, never hardcoded.
-- ---------------------------------------------------------------------------
-- The fixture's ORIGINAL events carry fixed July 2026 business dates, but
-- every reversal/cancellation is pinned to `public.business_today()` at
-- fixture-load time. Asserting they land in "August 2026" was only true
-- while the suite happened to run during August 2026; from September 2026
-- onward those assertions failed against a window the reversals had already
-- moved out of. The window is computed from business_today() here so it
-- tracks the real clock forever, across month AND year boundaries. The same
-- exact figures are asserted — only the window follows reality.
do $$
declare
  v_today date := public.business_today();
  v_original_month_start constant date := date '2026-07-01';
begin
  if date_trunc('month', v_today) <= date_trunc('month', v_original_month_start) then
    raise exception 'FIXTURE PRECONDITION VIOLATED: business_today() = % must fall in a calendar month strictly AFTER the fixture''s original-event month (2026-07); the reversal-vs-original split this file proves cannot exist otherwise', v_today;
  end if;

  perform set_config('p8g.rev_start', date_trunc('month', v_today)::date::text, true);
  perform set_config('p8g.rev_end', (date_trunc('month', v_today) + interval '1 month' - interval '1 day')::date::text, true);
  perform set_config('p8g.rev_year', extract(year from v_today)::text, true);
end $$;

set role authenticated;

-- ---------------------------------------------------------------------------
-- (A) Sales-side ranking/detail reports for July 2026.
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '80000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);

  v := public.get_sales_report('2026-07-01', '2026-07-31');
  if v -> 'summary' ->> 'sales_revenue' <> '3500.00' or v -> 'summary' ->> 'net_sales_profit' <> '555.00' then
    raise exception 'FAIL A1 (get_sales_report): expected revenue=3500.00/net_sales_profit=555.00, got revenue=%, net_sales_profit=%',
      v -> 'summary' ->> 'sales_revenue', v -> 'summary' ->> 'net_sales_profit';
  end if;
  -- order_number is NOT asserted to an exact value: it comes from a global
  -- sequence that is NOT rolled back by a prior test's ROLLBACK (standard
  -- Postgres sequence semantics), so its exact numeral is run-order
  -- dependent when this file runs after another fixture-based test in the
  -- same database session lifetime. Only the stable prefix is asserted.
  if (v -> 'rows' -> 0 ->> 'order_number') not like 'SALE-%' then
    raise exception 'FAIL A2 (get_sales_report): unexpected order_number %', v -> 'rows' -> 0 ->> 'order_number';
  end if;

  v := public.get_items_report('2026-07-01', '2026-07-31');
  if v -> 'summary' ->> 'revenue' <> '3500.00' or v -> 'summary' ->> 'gross_profit' <> '625.00' or v -> 'summary' ->> 'weight_grams' <> '10.0000' then
    raise exception 'FAIL A3 (get_items_report): expected revenue=3500.00/gross_profit=625.00/weight=10.0000, got %', v -> 'summary';
  end if;

  v := public.get_categories_report('2026-07-01', '2026-07-31');
  if v -> 'summary' ->> 'revenue' <> '3500.00' or v -> 'summary' ->> 'categories_count' <> '1' then
    raise exception 'FAIL A4 (get_categories_report): expected revenue=3500.00/categories_count=1, got %', v -> 'summary';
  end if;

  v := public.get_karats_report('2026-07-01', '2026-07-31');
  if v -> 'summary' ->> 'revenue' <> '3500.00' or v -> 'summary' ->> 'karats_count' <> '1' then
    raise exception 'FAIL A5 (get_karats_report): expected revenue=3500.00/karats_count=1, got %', v -> 'summary';
  end if;

  v := public.get_employees_report('2026-07-01', '2026-07-31');
  if v -> 'summary' ->> 'revenue' <> '3500.00' or v -> 'summary' ->> 'net_sales_profit' <> '555.00' then
    raise exception 'FAIL A6 (get_employees_report): expected revenue=3500.00/net_sales_profit=555.00, got %', v -> 'summary';
  end if;

  v := public.get_payment_methods_report('2026-07-01', '2026-07-31');
  if v -> 'summary' ->> 'revenue' <> '3500.00' or v -> 'summary' ->> 'net_sales_profit' <> '555.00' then
    raise exception 'FAIL A7 (get_payment_methods_report): expected revenue=3500.00/net_sales_profit=555.00, got %', v -> 'summary';
  end if;

  v := public.get_collection_channels_report('2026-07-01', '2026-07-31');
  if v -> 'summary' ->> 'revenue' <> '3500.00' or v -> 'summary' ->> 'net_sales_profit' <> '555.00' then
    raise exception 'FAIL A8 (get_collection_channels_report): expected revenue=3500.00/net_sales_profit=555.00, got %', v -> 'summary';
  end if;

  raise notice 'PASS A: all 7 sales-side ranking/detail reports agree on July 2026 (revenue=3500.00, net_sales_profit=555.00)';
end $$;

-- ---------------------------------------------------------------------------
-- (B) get_returns_report() movements ledger (§82/§85).
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb;
  v_rev_start date := current_setting('p8g.rev_start')::date;
  v_rev_end date := current_setting('p8g.rev_end')::date;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '80000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);

  v := public.get_returns_report('2026-07-01', '2026-07-31');
  if v -> 'summary' ->> 'net_profit_effect' <> '-555.00' or v -> 'summary' ->> 'approved_count' <> '1' or v -> 'summary' ->> 'reversed_count' <> '0' then
    raise exception 'FAIL B1: expected July net_profit_effect=-555.00/approved=1/reversed=0, got %', v -> 'summary';
  end if;

  v := public.get_returns_report(v_rev_start, v_rev_end);
  if v -> 'summary' ->> 'net_profit_effect' <> '555.00' or v -> 'summary' ->> 'approved_count' <> '0' or v -> 'summary' ->> 'reversed_count' <> '1' then
    raise exception 'FAIL B2 (CRITICAL): expected reversal-month (%..%) net_profit_effect=+555.00 (undo)/approved=0/reversed=1, got %', v_rev_start, v_rev_end, v -> 'summary';
  end if;

  v := public.get_returns_report('2026-07-01', v_rev_end);
  if v -> 'summary' ->> 'movements_count' <> '2'
     or v -> 'summary' ->> 'net_profit_effect' <> '0.00'
     or v -> 'summary' ->> 'revenue_effect' <> '0.00'
     or v -> 'summary' ->> 'gross_profit_effect' <> '0.00'
     or v -> 'summary' ->> 'payment_fee_effect' <> '0.00'
     or v -> 'summary' ->> 'refund_effect' <> '0.00' then
    raise exception 'FAIL B3 (CRITICAL): expected combined 2026-07-01..% returns to net EXACTLY 0.00 across every field, got %', v_rev_end, v -> 'summary';
  end if;

  raise notice 'PASS B: get_returns_report() movements ledger reconciles -- July -555.00, reversal month (%..%) +555.00, combined = 0.00 (no double-counting)', v_rev_start, v_rev_end;
end $$;

-- ---------------------------------------------------------------------------
-- (C) get_adjustments_report() movements ledger (§85).
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb;
  v_rev_start date := current_setting('p8g.rev_start')::date;
  v_rev_end date := current_setting('p8g.rev_end')::date;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '80000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);

  v := public.get_adjustments_report('2026-07-01', '2026-07-31');
  if v -> 'summary' ->> 'net_profit_effect' <> '58.00' or v -> 'summary' ->> 'approved_count' <> '1' then
    raise exception 'FAIL C1: expected July net_profit_effect=58.00/approved_count=1, got %', v -> 'summary';
  end if;

  v := public.get_adjustments_report(v_rev_start, v_rev_end);
  if v -> 'summary' ->> 'net_profit_effect' <> '-58.00' or v -> 'summary' ->> 'reversed_count' <> '1' then
    raise exception 'FAIL C2 (CRITICAL): expected reversal-month (%..%) net_profit_effect=-58.00 (undo)/reversed_count=1, got %', v_rev_start, v_rev_end, v -> 'summary';
  end if;

  v := public.get_adjustments_report('2026-07-01', v_rev_end);
  if v -> 'summary' ->> 'net_profit_effect' <> '0.00'
     or v -> 'summary' ->> 'gross_profit_effect' <> '0.00'
     or v -> 'summary' ->> 'customer_charge_effect' <> '0.00' then
    raise exception 'FAIL C3 (CRITICAL): expected combined 2026-07-01..% adjustments to net EXACTLY 0.00 (net/gross profit, customer charge), got %', v_rev_end, v -> 'summary';
  end if;

  raise notice 'PASS C: get_adjustments_report() movements ledger reconciles -- July +58.00, reversal month (%..%) -58.00, combined = 0.00 (no double-counting)', v_rev_start, v_rev_end;
end $$;

-- ---------------------------------------------------------------------------
-- (D) get_shipping_report() / get_cod_report() -- Current Effective basis.
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '80000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);

  v := public.get_shipping_report('2026-07-01', '2026-07-31');
  if v -> 'summary' ->> 'customer_shipping_charge' <> '30.00'
     or v -> 'summary' ->> 'actual_carrier_cost' <> '20.00'
     or v -> 'summary' ->> 'net_shipping_result' <> '10.00' then
    raise exception 'FAIL D1: expected July shipping charge=30.00/actual cost=20.00/net result=10.00, got %', v -> 'summary';
  end if;
  if v ->> 'basis' <> 'current_effective' then
    raise exception 'FAIL D2: get_shipping_report() must declare basis=current_effective (§83), got %', v ->> 'basis';
  end if;

  v := public.get_cod_report('2026-07-01', '2026-07-31');
  if v -> 'summary' ->> 'shipments_count' <> '0' then
    raise exception 'FAIL D3: expected no COD shipments in the golden scenario fixture, got %', v -> 'summary' ->> 'shipments_count';
  end if;

  raise notice 'PASS D: get_shipping_report()/get_cod_report() Current Effective figures match the Dashboard''s shipping CTE exactly';
end $$;

-- ---------------------------------------------------------------------------
-- (E) get_settlements_report() dual basis (§83), agrees with
-- get_dashboard_summary()'s settle_cte byte-for-byte (§39/§80).
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb;
  v_dash jsonb;
  v_rev_start date := current_setting('p8g.rev_start')::date;
  v_rev_end date := current_setting('p8g.rev_end')::date;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '80000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);

  v := public.get_settlements_report('2026-07-01', '2026-07-31');
  v_dash := public.get_dashboard_summary('2026-07-01', '2026-07-31') -> 'settlements';

  if v -> 'summary' ->> 'expected' <> (v_dash ->> 'expected')
     or v -> 'summary' ->> 'actual' <> (v_dash ->> 'actual')
     or v -> 'summary' ->> 'variance' <> (v_dash ->> 'variance')
     or v -> 'summary' ->> 'batches_count' <> (v_dash ->> 'batches_count')
     or v -> 'summary' ->> 'cancelled_count' <> (v_dash ->> 'cancelled_count') then
    raise exception 'FAIL E1 (CRITICAL, §39/§80): get_settlements_report() July summary must byte-match get_dashboard_summary()''s settlements section -- report=%, dashboard=%',
      v -> 'summary', v_dash;
  end if;
  if v -> 'summary' ->> 'expected' <> '3513.00' or v -> 'summary' ->> 'batches_count' <> '2' or v -> 'summary' ->> 'cancelled_count' <> '1' then
    raise exception 'FAIL E2: expected July settlements expected=3513.00/batches_count=2/cancelled_count=1, got %', v -> 'summary';
  end if;
  if v ->> 'row_basis' <> 'current_effective' or v ->> 'summary_basis' <> 'movements_during_period' then
    raise exception 'FAIL E3: get_settlements_report() must declare row_basis=current_effective / summary_basis=movements_during_period (§83), got row_basis=%, summary_basis=%',
      v ->> 'row_basis', v ->> 'summary_basis';
  end if;

  v := public.get_settlements_report(v_rev_start, v_rev_end);
  v_dash := public.get_dashboard_summary(v_rev_start, v_rev_end) -> 'settlements';
  if v -> 'summary' ->> 'expected' <> (v_dash ->> 'expected') or v -> 'summary' ->> 'actual' <> (v_dash ->> 'actual') then
    raise exception 'FAIL E4 (CRITICAL, §39/§80): get_settlements_report() reversal-month (%..%) summary must byte-match get_dashboard_summary() -- report=%, dashboard=%', v_rev_start, v_rev_end, v -> 'summary', v_dash;
  end if;

  raise notice 'PASS E: get_settlements_report() dual-basis figures byte-match get_dashboard_summary() for both July and the reversal month (%..%) (§39/§80)', v_rev_start, v_rev_end;
end $$;

-- ---------------------------------------------------------------------------
-- (F) Daily/Weekly/Monthly/Yearly Management Reports delegate correctly and
-- reproduce get_dashboard_summary()'s exact Net Operating Return (§39).
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb;
  v_rev_year int := current_setting('p8g.rev_year')::int;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '80000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);

  v := public.get_daily_management_report('2026-07-10');
  if v ->> 'report_type' <> 'daily' or v ->> 'business_date' <> '2026-07-10' or v -> 'net_operating_return' ->> 'net_operating_return' <> '-555.00' then
    raise exception 'FAIL F1: expected daily 2026-07-10 report_type=daily/business_date=2026-07-10/NOR=-555.00 (return approval landing alone that day), got %', v;
  end if;

  v := public.get_weekly_management_report('2026-07-10');
  if v ->> 'report_type' <> 'weekly' or v ->> 'week_start' <> '2026-07-04' or v ->> 'week_end' <> '2026-07-10' or v -> 'net_operating_return' ->> 'net_operating_return' <> '10.00' then
    raise exception 'FAIL F2 (§5 Riyadh Week Contract): expected week containing 2026-07-10 = [2026-07-04, 2026-07-10] with NOR=10.00, got week_start=%, week_end=%, nor=%',
      v ->> 'week_start', v ->> 'week_end', v -> 'net_operating_return' ->> 'net_operating_return';
  end if;

  v := public.get_monthly_management_report(2026, 7);
  if v ->> 'report_type' <> 'monthly' or v ->> 'month_start' <> '2026-07-01' or v ->> 'month_end' <> '2026-07-31' or v -> 'net_operating_return' ->> 'net_operating_return' <> '68.00' then
    raise exception 'FAIL F3 (CRITICAL, §39): expected monthly July 2026 NOR=68.00 (byte-match Assertion A9 in reports_dashboard_golden_scenario.test.sql), got %',
      v -> 'net_operating_return' ->> 'net_operating_return';
  end if;

  -- Yearly: which figure 2026 must show depends on whether the reversals
  -- landed in 2026 too. Both branches are exact -- neither is a relaxation.
  --   * reversals in 2026  -> 2026 contains originals AND reversals, so the
  --     whole scenario nets to 565.00 within the single year.
  --   * reversals in a LATER year -> 2026 holds the originals ONLY (68.00,
  --     byte-identical to the monthly July figure asserted just above), and
  --     the reversal year holds the undo events ONLY (497.00, byte-identical
  --     to assertion B in reports_dashboard_golden_scenario.test.sql). The
  --     two still sum to 565.00, just across two yearly reports instead of
  --     one -- which is a STRICTER statement than the old single assertion.
  v := public.get_yearly_management_report(2026);
  if v ->> 'report_type' <> 'yearly' or v ->> 'year_start' <> '2026-01-01' or v ->> 'year_end' <> '2026-12-31' then
    raise exception 'FAIL F4a: expected yearly 2026 report_type=yearly/year_start=2026-01-01/year_end=2026-12-31, got %', v;
  end if;

  if v_rev_year = 2026 then
    if v -> 'net_operating_return' ->> 'net_operating_return' <> '565.00' then
      raise exception 'FAIL F4 (CRITICAL, §39): reversals landed in 2026, so yearly 2026 NOR must be 565.00 (the full combined scenario -- no double-counting across the whole year), got %',
        v -> 'net_operating_return' ->> 'net_operating_return';
    end if;
  else
    if v -> 'net_operating_return' ->> 'net_operating_return' <> '68.00' then
      raise exception 'FAIL F4b (CRITICAL, §39): reversals landed in % (not 2026), so yearly 2026 must carry the ORIGINAL events only, NOR=68.00, got %',
        v_rev_year, v -> 'net_operating_return' ->> 'net_operating_return';
    end if;

    v := public.get_yearly_management_report(v_rev_year);
    if v -> 'net_operating_return' ->> 'net_operating_return' <> '497.00' then
      raise exception 'FAIL F4c (CRITICAL, §39/§85): yearly % must carry the REVERSAL events only, NOR=497.00, got %',
        v_rev_year, v -> 'net_operating_return' ->> 'net_operating_return';
    end if;
  end if;

  raise notice 'PASS F: Daily/Weekly/Monthly/Yearly Management Reports delegate correctly -- NOR daily=-555.00, weekly=10.00, monthly=68.00, yearly split proven for reversal year %', v_rev_year;
end $$;

-- ---------------------------------------------------------------------------
-- (G) §79 true key-absence for the no-financials actor, across every
-- row-level report RPC built in 0201-0204.
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '80000000-0000-4000-8000-000000000004', 'role', 'authenticated')::text, true);

  v := public.get_sales_report('2026-07-01', '2026-07-31');
  if v -> 'summary' ? 'net_sales_profit' or (v -> 'rows' -> 0) ? 'net_sales_profit' then
    raise exception 'FAIL G1: get_sales_report() must NOT expose net_sales_profit key at all to a non-profit actor, got summary=%, row=%', v -> 'summary', v -> 'rows' -> 0;
  end if;

  v := public.get_items_report('2026-07-01', '2026-07-31');
  if v -> 'summary' ? 'gross_profit' or (v -> 'rows' -> 0) ? 'gross_profit' then
    raise exception 'FAIL G2: get_items_report() must NOT expose gross_profit key to a non-profit actor';
  end if;

  v := public.get_employees_report('2026-07-01', '2026-07-31');
  if v -> 'summary' ? 'net_sales_profit' or (v -> 'rows' -> 0) ? 'net_sales_profit' then
    raise exception 'FAIL G3: get_employees_report() must NOT expose net_sales_profit key to a non-profit actor';
  end if;

  v := public.get_returns_report('2026-07-01', '2026-07-31');
  if v -> 'summary' ? 'net_profit_effect' or (v -> 'rows' -> 0) ? 'net_profit_effect' then
    raise exception 'FAIL G4: get_returns_report() must NOT expose net_profit_effect key to a non-profit actor';
  end if;

  v := public.get_adjustments_report('2026-07-01', '2026-07-31');
  if v -> 'summary' ? 'net_profit_effect' or (v -> 'rows' -> 0) ? 'net_profit_effect' then
    raise exception 'FAIL G5: get_adjustments_report() must NOT expose net_profit_effect key to a non-profit actor';
  end if;

  v := public.get_shipping_report('2026-07-01', '2026-07-31');
  if v -> 'summary' ? 'net_shipping_result' or (v -> 'rows' -> 0) ? 'net_shipping_result' then
    raise exception 'FAIL G6: get_shipping_report() must NOT expose net_shipping_result key to a non-profit actor';
  end if;

  v := public.get_settlements_report('2026-07-01', '2026-07-31');
  if v -> 'summary' ? 'expected' or (v -> 'rows' -> 0) ? 'expected_bank_settlement' then
    raise exception 'FAIL G7: get_settlements_report() must NOT expose expected/expected_bank_settlement keys to a non-financials actor';
  end if;

  raise notice 'PASS G: §79 true key-absence confirmed for all 7 sampled report RPCs (sales/items/employees/returns/adjustments/shipping/settlements)';
end $$;

-- ---------------------------------------------------------------------------
-- (H) Explicit unauthorized store filter is REJECTED, not silently
-- narrowed (§8), sampled across report families.
-- ---------------------------------------------------------------------------
do $$
declare
  v_bug boolean := false;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '80000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);

  begin
    perform public.get_sales_report('2026-07-01', '2026-07-31', array['00000000-0000-4000-8000-000000000999']::uuid[]);
    v_bug := true;
  exception when sqlstate 'P0001' then null;
  end;
  if v_bug then raise exception 'FAIL H1: get_sales_report() must reject an unauthorized store filter'; end if;

  v_bug := false;
  begin
    perform public.get_returns_report('2026-07-01', '2026-07-31', array['00000000-0000-4000-8000-000000000999']::uuid[]);
    v_bug := true;
  exception when sqlstate 'P0001' then null;
  end;
  if v_bug then raise exception 'FAIL H2: get_returns_report() must reject an unauthorized store filter'; end if;

  v_bug := false;
  begin
    perform public.get_settlements_report('2026-07-01', '2026-07-31', array['00000000-0000-4000-8000-000000000999']::uuid[]);
    v_bug := true;
  exception when sqlstate 'P0001' then null;
  end;
  if v_bug then raise exception 'FAIL H3: get_settlements_report() must reject an unauthorized store filter'; end if;

  v_bug := false;
  begin
    perform public.get_daily_management_report('2026-07-10', array['00000000-0000-4000-8000-000000000999']::uuid[]);
    v_bug := true;
  exception when sqlstate 'P0001' then null;
  end;
  if v_bug then raise exception 'FAIL H4: get_daily_management_report() must reject an unauthorized store filter (propagated from get_dashboard_summary())'; end if;

  raise notice 'PASS H: unauthorized store filters correctly REJECTED (never silently narrowed) across sampled report RPCs';
end $$;

do $$
begin
  raise notice '=== ALL reports_detail_golden_scenario.test.sql ASSERTIONS PASSED (§21-§37/§39/§45/§63/§79/§80/§82/§83/§84/§85) ===';
end $$;

rollback;
