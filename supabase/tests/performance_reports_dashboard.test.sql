-- ============================================================================
-- Phase 8 Patch 8.1 §50-51 / §71 — Reports & Dashboard performance
-- regression test.
-- ============================================================================
-- Loads supabase/tests/fixtures/phase8_performance_fixture.sql (10,500 real
-- sales orders across a 365-day window, plus the proportional returns/
-- shipments/adjustments/settlement batches it produces via the real
-- production RPCs -- never raw inserts, so every trigger-computed/snapshot
-- column is exactly as realistic as what production would actually store)
-- inside ONE rolled-back transaction, ANALYZEs the affected tables so the
-- planner has real statistics to work with (a fresh/empty-table plan is not
-- representative of anything), then calls every reporting/dashboard RPC
-- across the full 365-day window as the fixture's own super-admin actor and
-- asserts each call completes within a generous ceiling.
--
-- This is a REGRESSION FLOOR, not a performance target: the thresholds below
-- are set high enough that a correct, reasonably-indexed implementation
-- passes comfortably, while a real regression (a missing index, an
-- accidental N+1, a sequential scan introduced by a careless later edit)
-- would blow through them. Actual measured timings are RAISE NOTICE'd so a
-- human reviewing test output sees the real numbers, not just pass/fail.
--
-- Separately, PERFORMANCE_RESULTS_PATCH_8_1.md captures real
-- EXPLAIN (ANALYZE, BUFFERS) plans for the same calls, for human review of
-- *how* each result was reached (index usage, row estimates, etc.), not
-- just *whether* it was fast enough.
-- ============================================================================
begin;

\i supabase/tests/fixtures/phase8_performance_fixture.sql

-- Real planner statistics for the tables this fixture just populated at
-- volume -- without this, every EXPLAIN below reflects the planner's
-- pre-fixture (near-empty) row-count assumptions, not reality.
analyze public.sales_orders;
analyze public.sales_order_items;
analyze public.sales_returns;
analyze public.sales_return_items;
analyze public.sales_return_refund_events;
analyze public.shipments;
analyze public.shipment_cod_events;
analyze public.shipment_financial_events;
analyze public.shipment_status_events;
analyze public.sales_order_adjustments;
analyze public.settlement_batches;
analyze public.settlement_batch_lines;
analyze public.settlement_bank_movement_events;
analyze public.settlement_batch_cancellations;

set role authenticated;

do $$
declare
  v_actor uuid := '80300000-0000-4000-8000-000000000001';
  v_from date := public.business_today() - 364;
  v_to date := public.business_today();
  v_result jsonb;
  v_t0 timestamptz;
  v_ms numeric;

  -- Generous regression-floor ceilings (ms). Not a performance target --
  -- see header comment.
  c_dashboard_ceiling_ms constant numeric := 3000;
  c_detail_report_ceiling_ms constant numeric := 3000;
  c_management_report_ceiling_ms constant numeric := 4000;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_actor, 'role', 'authenticated')::text, true);

  raise notice 'Performance regression run -- window % .. % (365 days, 10,500 orders)', v_from, v_to;

  v_t0 := clock_timestamp();
  v_result := public.get_dashboard_summary(v_from, v_to, null);
  v_ms := extract(epoch from clock_timestamp() - v_t0) * 1000;
  if not (v_result -> 'net_operating_return' ? 'net_operating_return') then
    raise exception 'PERF SANITY FAIL: get_dashboard_summary did not return a net_operating_return section for the full-permission actor';
  end if;
  raise notice '  % : % ms (ceiling % ms)', rpad('get_dashboard_summary', 32), round(v_ms, 1), c_dashboard_ceiling_ms;
  if v_ms > c_dashboard_ceiling_ms then
    raise exception 'PERF FAIL: % took % ms, exceeding the % ms regression-floor ceiling', 'get_dashboard_summary', round(v_ms, 1), c_dashboard_ceiling_ms;
  end if;

  v_t0 := clock_timestamp();
  v_result := public.get_dashboard_trends(v_from, v_to, null, 'month');
  v_ms := extract(epoch from clock_timestamp() - v_t0) * 1000;
  if jsonb_array_length(v_result -> 'buckets') < 12 then
    raise exception 'PERF SANITY FAIL: get_dashboard_trends(month) returned % buckets over a 365-day window, expected >= 12', jsonb_array_length(v_result -> 'buckets');
  end if;
  raise notice '  % : % ms (ceiling % ms)', rpad('get_dashboard_trends(month)', 32), round(v_ms, 1), c_dashboard_ceiling_ms;
  if v_ms > c_dashboard_ceiling_ms then
    raise exception 'PERF FAIL: % took % ms, exceeding the % ms regression-floor ceiling', 'get_dashboard_trends(month)', round(v_ms, 1), c_dashboard_ceiling_ms;
  end if;

  v_t0 := clock_timestamp();
  v_result := public.get_sales_report(v_from, v_to, null, null, null, null, null, null, null, 'sale_date_desc', 50, 0);
  v_ms := extract(epoch from clock_timestamp() - v_t0) * 1000;
  raise notice '  % : % ms (ceiling % ms)', rpad('get_sales_report', 32), round(v_ms, 1), c_detail_report_ceiling_ms;
  if v_ms > c_detail_report_ceiling_ms then
    raise exception 'PERF FAIL: % took % ms, exceeding the % ms regression-floor ceiling', 'get_sales_report', round(v_ms, 1), c_detail_report_ceiling_ms;
  end if;

  v_t0 := clock_timestamp();
  v_result := public.get_returns_report(v_from, v_to, null, null, null, null, null, null, 'movement_date_desc', 50, 0);
  v_ms := extract(epoch from clock_timestamp() - v_t0) * 1000;
  raise notice '  % : % ms (ceiling % ms)', rpad('get_returns_report', 32), round(v_ms, 1), c_detail_report_ceiling_ms;
  if v_ms > c_detail_report_ceiling_ms then
    raise exception 'PERF FAIL: % took % ms, exceeding the % ms regression-floor ceiling', 'get_returns_report', round(v_ms, 1), c_detail_report_ceiling_ms;
  end if;

  v_t0 := clock_timestamp();
  v_result := public.get_shipping_report(v_from, v_to, null, null, null, null, null, null, null, 'shipment_date_desc', 50, 0);
  v_ms := extract(epoch from clock_timestamp() - v_t0) * 1000;
  raise notice '  % : % ms (ceiling % ms)', rpad('get_shipping_report', 32), round(v_ms, 1), c_detail_report_ceiling_ms;
  if v_ms > c_detail_report_ceiling_ms then
    raise exception 'PERF FAIL: % took % ms, exceeding the % ms regression-floor ceiling', 'get_shipping_report', round(v_ms, 1), c_detail_report_ceiling_ms;
  end if;

  v_t0 := clock_timestamp();
  v_result := public.get_cod_report(v_from, v_to, null, null, null, 'shipment_date_desc', 50, 0);
  v_ms := extract(epoch from clock_timestamp() - v_t0) * 1000;
  raise notice '  % : % ms (ceiling % ms)', rpad('get_cod_report', 32), round(v_ms, 1), c_detail_report_ceiling_ms;
  if v_ms > c_detail_report_ceiling_ms then
    raise exception 'PERF FAIL: % took % ms, exceeding the % ms regression-floor ceiling', 'get_cod_report', round(v_ms, 1), c_detail_report_ceiling_ms;
  end if;

  v_t0 := clock_timestamp();
  v_result := public.get_adjustments_report(v_from, v_to, null, null, null, 'movement_date_desc', 50, 0);
  v_ms := extract(epoch from clock_timestamp() - v_t0) * 1000;
  raise notice '  % : % ms (ceiling % ms)', rpad('get_adjustments_report', 32), round(v_ms, 1), c_detail_report_ceiling_ms;
  if v_ms > c_detail_report_ceiling_ms then
    raise exception 'PERF FAIL: % took % ms, exceeding the % ms regression-floor ceiling', 'get_adjustments_report', round(v_ms, 1), c_detail_report_ceiling_ms;
  end if;

  v_t0 := clock_timestamp();
  v_result := public.get_settlements_report(v_from, v_to, null, null, null, null, 'settlement_date_desc', 50, 0);
  v_ms := extract(epoch from clock_timestamp() - v_t0) * 1000;
  raise notice '  % : % ms (ceiling % ms)', rpad('get_settlements_report', 32), round(v_ms, 1), c_detail_report_ceiling_ms;
  if v_ms > c_detail_report_ceiling_ms then
    raise exception 'PERF FAIL: % took % ms, exceeding the % ms regression-floor ceiling', 'get_settlements_report', round(v_ms, 1), c_detail_report_ceiling_ms;
  end if;

  v_t0 := clock_timestamp();
  v_result := public.get_monthly_management_report(extract(year from v_to)::int, extract(month from v_to)::int, null);
  v_ms := extract(epoch from clock_timestamp() - v_t0) * 1000;
  raise notice '  % : % ms (ceiling % ms)', rpad('get_monthly_management_report', 32), round(v_ms, 1), c_management_report_ceiling_ms;
  if v_ms > c_management_report_ceiling_ms then
    raise exception 'PERF FAIL: % took % ms, exceeding the % ms regression-floor ceiling', 'get_monthly_management_report', round(v_ms, 1), c_management_report_ceiling_ms;
  end if;

  -- A second-page pull (offset 5000) on the largest detail report --
  -- proves pagination cost does not degrade catastrophically deep into a
  -- 10,500-row result set (a naive OFFSET-without-index-support plan would
  -- show up here as a multi-second outlier vs. the offset-0 call above).
  v_t0 := clock_timestamp();
  v_result := public.get_sales_report(v_from, v_to, null, null, null, null, null, null, null, 'sale_date_desc', 50, 5000);
  v_ms := extract(epoch from clock_timestamp() - v_t0) * 1000;
  raise notice '  % : % ms (ceiling % ms)', rpad('get_sales_report(offset 5000)', 32), round(v_ms, 1), c_detail_report_ceiling_ms;
  if v_ms > c_detail_report_ceiling_ms then
    raise exception 'PERF FAIL: % took % ms, exceeding the % ms regression-floor ceiling', 'get_sales_report(offset 5000)', round(v_ms, 1), c_detail_report_ceiling_ms;
  end if;

  raise notice 'PASS: all reporting/dashboard RPCs completed within their regression-floor ceilings over 10,500 orders / 365 days.';
end $$;

rollback;
