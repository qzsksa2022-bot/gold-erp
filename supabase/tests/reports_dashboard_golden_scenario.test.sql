-- ============================================================================
-- Phase 8 §81 (Golden Financial Scenario) + §82 (Reversal Scenario) +
-- §92/§93 (Atomic Snapshot) + §39 (Single Reporting Engine) live regression
-- test for get_dashboard_summary()/get_dashboard_trends() (0200).
-- ============================================================================
-- Runs the real fixture (supabase/tests/fixtures/phase8_golden_scenario_
-- fixture.sql -- built entirely from production RPCs, never raw financial
-- inserts) inside ONE rolled-back transaction, then asserts:
--   (A) July 2026 alone: Net Operating Return reconciles to EXACTLY 68.00
--       (0.00 effective sales profit [full return] + 10.00 net shipping +
--       58.00 net adjustments), matching §81's "prove the formula, not an
--       arbitrary number" spirit.
--   (B) The REVERSAL MONTH alone -- i.e. the calendar month containing
--       business_today(), which is where every reversal/cancellation in this
--       fixture necessarily lands (the fixture passes business_today()
--       explicitly to reverse_sales_return()/reverse_sales_return_refund_
--       event()/reverse_sales_order_adjustment()/cancel_settlement_batch()).
--       This window is COMPUTED, never hardcoded, so it stays correct as the
--       real clock advances across months and years: the July return/
--       adjustment/settlement-B reversals land here, NOT in July -- §85
--       Event Date semantics proof.
--   (C) July + the reversal month COMBINED: every reversed/cancelled item's net
--       contribution collapses to exactly 0.00 (return, adjustment,
--       settlement B) while the untouched settlement A and shipment remain
--       fully intact -- proving no double-counting and no silent data loss
--       across the split.
--   (D) get_dashboard_trends() at month granularity reproduces the EXACT
--       same July/August figures as get_dashboard_summary() -- §39 Single
--       Reporting Engine: Screen (summary) total = Trend point, literally.
--   (E) The limited (sales_employee) actor sees ONLY orders_count/
--       sales_revenue/returns_count -- every profit/financial key and
--       every shipping/adjustments/settlements/net_operating_return
--       SECTION is truly ABSENT (§79), not null.
--   (F) An explicit store filter naming a store outside the actor's scope
--       is REJECTED (§8), never silently narrowed.
--   (G) date_from > date_to is REJECTED (§4).
-- ============================================================================
begin;

\i supabase/tests/fixtures/phase8_golden_scenario_fixture.sql

-- ---------------------------------------------------------------------------
-- Reversal window — derived, never hardcoded.
-- ---------------------------------------------------------------------------
-- The fixture's ORIGINAL events carry fixed July 2026 business dates, but
-- every reversal/cancellation is pinned to `public.business_today()` at
-- fixture-load time (see the fixture's reverse_sales_return() /
-- reverse_sales_return_refund_event() / reverse_sales_order_adjustment() /
-- cancel_settlement_batch() calls, all of which pass business_today()
-- explicitly). This file used to assert those reversals landed in
-- "August 2026", which was only ever true while the suite happened to be
-- run during August 2026 — from September 2026 onward assertion B2 failed
-- with `expected +555.00, got 0`, because the reversals had moved into the
-- new current month while the assertion had not.
--
-- The reversal window is therefore computed here from business_today()
-- itself, so it tracks the real clock forever, across both month AND year
-- boundaries. Nothing is weakened: the SAME exact figures are asserted, just
-- against the window the reversals genuinely belong to.
do $$
declare
  v_today date := public.business_today();
  v_original_month_start constant date := date '2026-07-01';
begin
  -- The whole §85 Event-Date proof rests on the reversals landing in a
  -- DIFFERENT calendar month than the originals. If business_today() ever
  -- shared July 2026 with them, sections A and B would silently overlap and
  -- both could pass while proving nothing. Fail loudly instead of quietly
  -- degrading into a meaningless test.
  if date_trunc('month', v_today) <= date_trunc('month', v_original_month_start) then
    raise exception 'FIXTURE PRECONDITION VIOLATED: business_today() = % must fall in a calendar month strictly AFTER the fixture''s original-event month (2026-07); the reversal-vs-original split this file proves cannot exist otherwise', v_today;
  end if;

  perform set_config('p8g.rev_start', date_trunc('month', v_today)::date::text, true);
  perform set_config('p8g.rev_end', (date_trunc('month', v_today) + interval '1 month' - interval '1 day')::date::text, true);
  perform set_config('p8g.rev_label', to_char(v_today, 'YYYY-MM'), true);
end $$;

set role authenticated;

-- ---------------------------------------------------------------------------
-- (A) July 2026 alone.
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '80000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  v := public.get_dashboard_summary('2026-07-01', '2026-07-31', null);

  if v -> 'sales' ->> 'orders_count' <> '1' then
    raise exception 'FAIL A1: expected July orders_count=1, got %', v -> 'sales' ->> 'orders_count';
  end if;
  if v -> 'sales' ->> 'sales_revenue' <> '3500.00' then
    raise exception 'FAIL A2: expected July sales_revenue=3500.00, got %', v -> 'sales' ->> 'sales_revenue';
  end if;
  if v -> 'sales' ->> 'net_sales_profit_original' <> '555.00' then
    raise exception 'FAIL A3: expected July net_sales_profit_original=555.00, got %', v -> 'sales' ->> 'net_sales_profit_original';
  end if;
  if v -> 'sales' ->> 'effective_net_sales_profit' <> '0.00' then
    raise exception 'FAIL A4: expected July effective_net_sales_profit=0.00 (full return approved same month), got %', v -> 'sales' ->> 'effective_net_sales_profit';
  end if;
  if v -> 'returns' ->> 'return_financial_impact' <> '-555.00' then
    raise exception 'FAIL A5: expected July return_financial_impact=-555.00, got %', v -> 'returns' ->> 'return_financial_impact';
  end if;
  if v -> 'shipping' ->> 'net_shipping_result' <> '10.00' then
    raise exception 'FAIL A6: expected July net_shipping_result=10.00, got %', v -> 'shipping' ->> 'net_shipping_result';
  end if;
  if v -> 'adjustments' ->> 'net_adjustments_result' <> '58.00' then
    raise exception 'FAIL A7: expected July net_adjustments_result=58.00, got %', v -> 'adjustments' ->> 'net_adjustments_result';
  end if;
  if v -> 'settlements' ->> 'expected' <> '3513.00' or v -> 'settlements' ->> 'actual' <> '0' then
    raise exception 'FAIL A8: expected July settlements expected=3513.00/actual=0, got expected=%, actual=%', v -> 'settlements' ->> 'expected', v -> 'settlements' ->> 'actual';
  end if;
  if v -> 'net_operating_return' ->> 'net_operating_return' <> '68.00' then
    raise exception 'FAIL A9 (CRITICAL): expected July Net Operating Return=68.00 (0.00 + 10.00 + 58.00), got %', v -> 'net_operating_return' ->> 'net_operating_return';
  end if;
  raise notice 'PASS A: July 2026 Golden Scenario reconciles -- Net Operating Return = 68.00';
end $$;

-- ---------------------------------------------------------------------------
-- (B) The reversal month (the month containing business_today()) alone --
--     the reversal/undo events (§85).
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb;
  v_from date := current_setting('p8g.rev_start')::date;
  v_to date := current_setting('p8g.rev_end')::date;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '80000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  v := public.get_dashboard_summary(v_from, v_to, null);

  if v -> 'sales' ->> 'orders_count' <> '0' then
    raise exception 'FAIL B1: expected reversal-month (%..%) orders_count=0 (Sale was dated July 2026), got %', v_from, v_to, v -> 'sales' ->> 'orders_count';
  end if;
  if v -> 'returns' ->> 'return_financial_impact' <> '555.00' then
    raise exception 'FAIL B2 (CRITICAL): expected reversal-month (%..%) return_financial_impact=+555.00 (the undo of July''s -555.00), got %', v_from, v_to, v -> 'returns' ->> 'return_financial_impact';
  end if;
  if v -> 'adjustments' ->> 'net_adjustments_result' <> '-58.00' then
    raise exception 'FAIL B3 (CRITICAL): expected reversal-month (%..%) net_adjustments_result=-58.00 (the undo of July''s +58.00), got %', v_from, v_to, v -> 'adjustments' ->> 'net_adjustments_result';
  end if;
  if v -> 'settlements' ->> 'expected' <> '-88.00' then
    raise exception 'FAIL B4 (CRITICAL): expected reversal-month (%..%) settlements expected=-88.00 (batch B''s cancellation undo), got %', v_from, v_to, v -> 'settlements' ->> 'expected';
  end if;
  if v -> 'settlements' ->> 'actual' <> '3425.00' then
    raise exception 'FAIL B5: expected reversal-month (%..%) settlements actual=3425.00 (batch A''s bank movement, dated today), got %', v_from, v_to, v -> 'settlements' ->> 'actual';
  end if;
  if v -> 'net_operating_return' ->> 'net_operating_return' <> '497.00' then
    raise exception 'FAIL B6 (CRITICAL): expected reversal-month (%..%) Net Operating Return=497.00 (555.00 + 0 + -58.00), got %', v_from, v_to, v -> 'net_operating_return' ->> 'net_operating_return';
  end if;
  raise notice 'PASS B: the reversal month (%..%) correctly carries every reversal/cancellation undo dated by its OWN business date (§85), never July''s', v_from, v_to;
end $$;

-- ---------------------------------------------------------------------------
-- (C) July + the reversal month combined -- everything reversed nets to
--     exactly zero.
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb;
  v_to date := current_setting('p8g.rev_end')::date;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '80000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  -- Spans from the originals' month through the end of the reversal month,
  -- however many empty months sit between them.
  v := public.get_dashboard_summary('2026-07-01', v_to, null);

  if v -> 'sales' ->> 'effective_net_sales_profit' <> '555.00' then
    raise exception 'FAIL C1: expected combined effective_net_sales_profit=555.00 (return fully undone), got %', v -> 'sales' ->> 'effective_net_sales_profit';
  end if;
  if v -> 'returns' ->> 'return_financial_impact' <> '0.00' then
    raise exception 'FAIL C2 (CRITICAL no-double-count): expected combined return_financial_impact=0.00, got %', v -> 'returns' ->> 'return_financial_impact';
  end if;
  if v -> 'returns' ->> 'actual_refunded_cash' <> '0.00' then
    raise exception 'FAIL C3: expected combined actual_refunded_cash=0.00 (issued then reversed), got %', v -> 'returns' ->> 'actual_refunded_cash';
  end if;
  if v -> 'adjustments' ->> 'net_adjustments_result' <> '0.00' then
    raise exception 'FAIL C4 (CRITICAL no-double-count): expected combined net_adjustments_result=0.00, got %', v -> 'adjustments' ->> 'net_adjustments_result';
  end if;
  if v -> 'settlements' ->> 'expected' <> '3425.00' or v -> 'settlements' ->> 'variance' <> '0.00' then
    raise exception 'FAIL C5 (CRITICAL): expected combined settlements expected=3425.00/variance=0.00 (batch A intact, batch B fully cancelled out), got expected=%, variance=%', v -> 'settlements' ->> 'expected', v -> 'settlements' ->> 'variance';
  end if;
  if v -> 'net_operating_return' ->> 'net_operating_return' <> '565.00' then
    raise exception 'FAIL C6 (CRITICAL): expected combined Net Operating Return=565.00 (555.00 + 10.00 + 0.00), got %', v -> 'net_operating_return' ->> 'net_operating_return';
  end if;
  raise notice 'PASS C: combined 2026-07-01..% nets every reversal to exactly 0.00 with no double-counting -- the untouched Sale/Shipment/Batch-A remain fully intact', v_to;
end $$;

-- ---------------------------------------------------------------------------
-- (D) get_dashboard_trends() at month granularity == get_dashboard_summary()
--     per-period figures (§39 Single Reporting Engine).
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb;
  v_jul jsonb;
  v_rev jsonb;
  v_rev_label text := current_setting('p8g.rev_label');
  v_to date := current_setting('p8g.rev_end')::date;
  v_stray text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '80000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  v := public.get_dashboard_trends('2026-07-01', v_to, null, 'month');

  select b into v_jul from jsonb_array_elements(v -> 'buckets') b where b ->> 'bucket_label' = '2026-07';
  select b into v_rev from jsonb_array_elements(v -> 'buckets') b where b ->> 'bucket_label' = v_rev_label;

  if v_jul is null or v_rev is null then
    raise exception 'FAIL D0: expected month buckets for 2026-07 and % to both exist, got labels: %',
      v_rev_label, (select jsonb_agg(b ->> 'bucket_label') from jsonb_array_elements(v -> 'buckets') b);
  end if;
  if v_jul ->> 'net_operating_return' <> '68.00' then
    raise exception 'FAIL D1 (CRITICAL Single Reporting Engine): trend July net_operating_return expected 68.00, got %', v_jul ->> 'net_operating_return';
  end if;
  if v_rev ->> 'net_operating_return' <> '497.00' then
    raise exception 'FAIL D2 (CRITICAL Single Reporting Engine): trend reversal-month (%) net_operating_return expected 497.00, got %', v_rev_label, v_rev ->> 'net_operating_return';
  end if;
  if v_jul ->> 'effective_net_sales_profit' <> '0.00' or v_rev ->> 'effective_net_sales_profit' <> '555.00' then
    raise exception 'FAIL D3: trend effective_net_sales_profit mismatch -- July=%, %=%', v_jul ->> 'effective_net_sales_profit', v_rev_label, v_rev ->> 'effective_net_sales_profit';
  end if;

  -- Every month BETWEEN the originals and the reversals must be genuinely
  -- empty. Under the old hardcoded July/August range no such month could
  -- exist, so this case went unproven; now that the window stretches to
  -- whatever month "today" falls in, it is a real assertion that no event
  -- leaked into an intervening month.
  -- Compared NUMERICALLY, not as text: a zero-filled bucket renders its
  -- net_operating_return as "0" (no scale), while a populated one renders
  -- "68.00"/"497.00". Testing `<> '0.00'` would therefore flag a genuinely
  -- empty month as a failure. The numeric comparison is exactly as strict --
  -- any non-zero value in an intervening month still fails.
  select string_agg(format('%s=%s', b ->> 'bucket_label', b ->> 'net_operating_return'), ', ')
    into v_stray
  from jsonb_array_elements(v -> 'buckets') b
  where b ->> 'bucket_label' not in ('2026-07', v_rev_label)
    and (b ->> 'net_operating_return')::numeric <> 0;

  if v_stray is not null then
    raise exception 'FAIL D4 (CRITICAL §85): months between the original events and their reversals must be exactly 0.00, got %', v_stray;
  end if;

  raise notice 'PASS D: get_dashboard_trends() reproduces get_dashboard_summary()''s exact figures for the same ranges (Screen total = Trend point), and every intervening month is exactly 0.00';
end $$;

-- ---------------------------------------------------------------------------
-- (E) Limited actor (sales_employee): true key-absence redaction (§79).
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '80000000-0000-4000-8000-000000000002', 'role', 'authenticated')::text, true);
  v := public.get_dashboard_summary('2026-07-01', '2026-07-31', null);

  if v ? 'shipping' or v ? 'adjustments' or v ? 'settlements' or v ? 'net_operating_return' then
    raise exception 'FAIL E1 (CRITICAL privacy): limited actor''s response must NOT contain shipping/adjustments/settlements/net_operating_return keys at all, got keys: %', (select jsonb_agg(k) from jsonb_object_keys(v) k);
  end if;
  if (v -> 'sales') ? 'gross_profit' or (v -> 'sales') ? 'net_sales_profit_original' or (v -> 'sales') ? 'effective_net_sales_profit' then
    raise exception 'FAIL E2 (CRITICAL privacy): limited actor''s sales section must NOT contain profit fields, got: %', v -> 'sales';
  end if;
  if not ((v -> 'sales') ? 'orders_count' and (v -> 'sales') ? 'sales_revenue') then
    raise exception 'FAIL E3: limited actor should still see orders_count/sales_revenue (non-profit), got: %', v -> 'sales';
  end if;
  if not ((v -> 'returns') ? 'returns_count') or (v -> 'returns') ? 'return_financial_impact' or (v -> 'returns') ? 'actual_refunded_cash' then
    raise exception 'FAIL E4 (CRITICAL privacy): limited actor should see returns_count only, no financial returns fields, got: %', v -> 'returns';
  end if;
  raise notice 'PASS E: sales_employee actor sees ONLY operational fields -- every profit/financial key and every unauthorized domain section is truly absent, not null';
end $$;

-- ---------------------------------------------------------------------------
-- (F) Explicit unauthorized store filter is REJECTED (§8), not silently
--     narrowed.
-- ---------------------------------------------------------------------------
do $$
declare
  v_bug boolean := false;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '80000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  begin
    perform public.get_dashboard_summary('2026-07-01', '2026-07-31', array['ffffffff-ffff-4fff-8fff-ffffffffffff'::uuid]);
    v_bug := true;
  exception when sqlstate 'P0001' then
    null;
  end;
  if v_bug then
    raise exception 'FAIL F (CRITICAL): an explicit store filter naming a store outside the actor''s visible scope must be REJECTED, not silently accepted';
  end if;
  raise notice 'PASS F: unauthorized explicit store filter correctly rejected';
end $$;

-- ---------------------------------------------------------------------------
-- (G) date_from > date_to is rejected (§4).
-- ---------------------------------------------------------------------------
do $$
declare
  v_bug boolean := false;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '80000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  begin
    perform public.get_dashboard_summary('2026-07-31', '2026-07-01', null);
    v_bug := true;
  exception when sqlstate 'P0001' then
    null;
  end;
  if v_bug then
    raise exception 'FAIL G: date_from > date_to must be rejected';
  end if;
  raise notice 'PASS G: date_from > date_to correctly rejected';
end $$;

-- ---------------------------------------------------------------------------
-- (H) Phase 10 — expenses must NOT move the legacy figure, and the new
--     after-expenses figure must be independently correct.
-- ---------------------------------------------------------------------------
-- The whole backward-compatibility promise of Phase 10 is asserted here
-- against the SAME golden scenario the legacy value (68.00) is proven on
-- above: a real July expense is posted, and then BOTH numbers are checked.
-- Assertion A9's 68.00 must survive verbatim — an expense may never silently
-- change what net_operating_return has always meant — while the new
-- net_operating_result_after_expenses reflects it.
do $$
declare
  v_legacy jsonb;
  v_new jsonb;
  v_cat uuid;
  v_nor text;
  v_contribution text;
  v_expenses text;
  v_after text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '80000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);

  select id into v_cat from public.create_expense_category('P8G-EXP', 'مصروف السيناريو الذهبي');
  perform public.record_store_expense(
    '80100000-0000-4000-8000-000000000001'::uuid, v_cat, 18.00, date '2026-07-15', 'إيجار يوليو - سيناريو ذهبي'
  );

  -- 1) The LEGACY contract is untouched, with a real expense now on the books.
  v_legacy := public.get_dashboard_summary('2026-07-01', '2026-07-31', null);
  v_nor := v_legacy -> 'net_operating_return' ->> 'net_operating_return';
  if v_nor <> '68.00' then
    raise exception 'FAIL H1 (CRITICAL backward compatibility): July net_operating_return must STILL be 68.00 after an expense exists, got %', v_nor;
  end if;
  if v_legacy ? 'expenses' or (v_legacy -> 'net_operating_return') ? 'net_operating_result_after_expenses' then
    raise exception 'FAIL H2: the legacy get_dashboard_summary() leaked Phase 10 keys';
  end if;

  -- The calendar-aware wrapper (0221) is equally untouched.
  if public.get_dashboard_summary_with_comparison('2026-07-01', '2026-07-31', 'monthly', null)
       -> 'net_operating_return' ->> 'net_operating_return' <> '68.00' then
    raise exception 'FAIL H3 (CRITICAL backward compatibility): the comparison wrapper''s July net_operating_return changed';
  end if;

  -- 2) The NEW expense-aware view reports both numbers, independently.
  v_new := public.get_dashboard_summary_with_expenses('2026-07-01', '2026-07-31', 'monthly', null);
  v_contribution := v_new -> 'net_operating_return' ->> 'operating_contribution_before_expenses';
  v_expenses := v_new -> 'net_operating_return' ->> 'operating_expenses_total';
  v_after := v_new -> 'net_operating_return' ->> 'net_operating_result_after_expenses';

  if v_new -> 'net_operating_return' ->> 'net_operating_return' <> '68.00' then
    raise exception 'FAIL H4 (CRITICAL): the expense-aware RPC must still carry the legacy net_operating_return=68.00 verbatim, got %',
      v_new -> 'net_operating_return' ->> 'net_operating_return';
  end if;
  if v_contribution <> '68.00' then
    raise exception 'FAIL H5: expected operating_contribution_before_expenses=68.00, got %', v_contribution;
  end if;
  if v_expenses <> '18.00' then
    raise exception 'FAIL H6: expected operating_expenses_total=18.00, got %', v_expenses;
  end if;
  if v_after <> '50.00' then
    raise exception 'FAIL H7 (CRITICAL): expected net_operating_result_after_expenses=50.00 (68.00 - 18.00), got %', v_after;
  end if;

  raise notice 'PASS H: an 18.00 July expense leaves net_operating_return at 68.00 exactly, while the new after-expenses result reports 50.00 — both proven independently on the same golden scenario';
end $$;

do $$
begin
  raise notice '=== ALL reports_dashboard_golden_scenario.test.sql ASSERTIONS PASSED (§81/§82/§85/§39/§79/§8/§4 + Phase 10 §H) ===';
end $$;

rollback;
