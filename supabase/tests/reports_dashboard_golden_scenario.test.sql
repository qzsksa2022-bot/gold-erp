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
--   (B) August 2026 alone (contains business_today(), where every
--       reversal/cancellation in this fixture necessarily lands -- see the
--       fixture's own header comment): the July return/adjustment/
--       settlement-B reversals land here, NOT in July -- §85 Event Date
--       semantics proof.
--   (C) July+August COMBINED: every reversed/cancelled item's net
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
-- (B) August 2026 alone -- the reversal/undo events (§85).
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '80000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  v := public.get_dashboard_summary('2026-08-01', '2026-08-31', null);

  if v -> 'sales' ->> 'orders_count' <> '0' then
    raise exception 'FAIL B1: expected August orders_count=0 (Sale was dated July), got %', v -> 'sales' ->> 'orders_count';
  end if;
  if v -> 'returns' ->> 'return_financial_impact' <> '555.00' then
    raise exception 'FAIL B2 (CRITICAL): expected August return_financial_impact=+555.00 (the undo of July''s -555.00), got %', v -> 'returns' ->> 'return_financial_impact';
  end if;
  if v -> 'adjustments' ->> 'net_adjustments_result' <> '-58.00' then
    raise exception 'FAIL B3 (CRITICAL): expected August net_adjustments_result=-58.00 (the undo of July''s +58.00), got %', v -> 'adjustments' ->> 'net_adjustments_result';
  end if;
  if v -> 'settlements' ->> 'expected' <> '-88.00' then
    raise exception 'FAIL B4 (CRITICAL): expected August settlements expected=-88.00 (batch B''s cancellation undo), got %', v -> 'settlements' ->> 'expected';
  end if;
  if v -> 'settlements' ->> 'actual' <> '3425.00' then
    raise exception 'FAIL B5: expected August settlements actual=3425.00 (batch A''s bank movement, dated today), got %', v -> 'settlements' ->> 'actual';
  end if;
  if v -> 'net_operating_return' ->> 'net_operating_return' <> '497.00' then
    raise exception 'FAIL B6 (CRITICAL): expected August Net Operating Return=497.00 (555.00 + 0 + -58.00), got %', v -> 'net_operating_return' ->> 'net_operating_return';
  end if;
  raise notice 'PASS B: August 2026 correctly carries every reversal/cancellation undo dated by its OWN business date (§85), never July''s';
end $$;

-- ---------------------------------------------------------------------------
-- (C) July+August combined -- everything reversed nets to exactly zero.
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '80000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  v := public.get_dashboard_summary('2026-07-01', '2026-08-31', null);

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
  raise notice 'PASS C: combined July+August nets every reversal to exactly 0.00 with no double-counting -- the untouched Sale/Shipment/Batch-A remain fully intact';
end $$;

-- ---------------------------------------------------------------------------
-- (D) get_dashboard_trends() at month granularity == get_dashboard_summary()
--     per-period figures (§39 Single Reporting Engine).
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb;
  v_jul jsonb;
  v_aug jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '80000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  v := public.get_dashboard_trends('2026-07-01', '2026-08-31', null, 'month');

  select b into v_jul from jsonb_array_elements(v -> 'buckets') b where b ->> 'bucket_label' = '2026-07';
  select b into v_aug from jsonb_array_elements(v -> 'buckets') b where b ->> 'bucket_label' = '2026-08';

  if v_jul ->> 'net_operating_return' <> '68.00' then
    raise exception 'FAIL D1 (CRITICAL Single Reporting Engine): trend July net_operating_return expected 68.00, got %', v_jul ->> 'net_operating_return';
  end if;
  if v_aug ->> 'net_operating_return' <> '497.00' then
    raise exception 'FAIL D2 (CRITICAL Single Reporting Engine): trend August net_operating_return expected 497.00, got %', v_aug ->> 'net_operating_return';
  end if;
  if v_jul ->> 'effective_net_sales_profit' <> '0.00' or v_aug ->> 'effective_net_sales_profit' <> '555.00' then
    raise exception 'FAIL D3: trend effective_net_sales_profit mismatch -- July=%, August=%', v_jul ->> 'effective_net_sales_profit', v_aug ->> 'effective_net_sales_profit';
  end if;
  raise notice 'PASS D: get_dashboard_trends() reproduces get_dashboard_summary()''s exact figures for the same ranges (Screen total = Trend point)';
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

do $$
begin
  raise notice '=== ALL reports_dashboard_golden_scenario.test.sql ASSERTIONS PASSED (§81/§82/§85/§39/§79/§8/§4) ===';
end $$;

rollback;
