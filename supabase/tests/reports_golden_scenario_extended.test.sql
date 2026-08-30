-- ============================================================================
-- Phase 8 Patch 8.1 §57-67 — Golden Scenario EXTENDED regression test.
-- ============================================================================
-- Runs the ORIGINAL golden scenario fixture (phase8_golden_scenario_
-- fixture.sql, unchanged) PLUS the multi-store extension
-- (phase8_golden_scenario_multistore_extension.sql) inside ONE rolled-back
-- transaction, then proves two things no existing golden-scenario test
-- covers:
--   (H/I/J) Store-scoping (§8) against REAL cross-store data -- not a
--       synthetic single-store dataset, and not just an explicit-rejection
--       check with nothing to leak. A store-2-scoped actor sees ONLY
--       store 2's real sale; the same actor is REJECTED for explicitly
--       naming store 1; the all-stores super admin sees the TRUE COMBINED
--       total across both real stores (3500.00 + 500.00 = 4000.00) --
--       proving no double-counting and no silent narrowing either.
--   (K) §79 true key-absence extended to every row-level report RPC NOT
--       already sampled by reports_detail_golden_scenario.test.sql's own
--       (G) block (which covers sales/items/employees/returns/adjustments/
--       shipping/settlements) -- cod/categories/karats/payment_methods/
--       collection_channels/daily_management, closing the remaining gap
--       across all 21 report RPCs (§44).
-- ============================================================================
begin;

\i supabase/tests/fixtures/phase8_golden_scenario_fixture.sql
\i supabase/tests/fixtures/phase8_golden_scenario_multistore_extension.sql

-- ---------------------------------------------------------------------------
-- Bootstrap a "can view, no financials" actor for block (K) below --
-- the original fixture's own limited actor (...002) is sales_employee,
-- which lacks reports.view/shipments.view entirely and so cannot call the
-- RPCs (K) exercises at all; a self-contained equivalent of
-- reports_detail_golden_scenario.test.sql's own p8_report_no_financials
-- role is built here (reports.view/sales.view/returns.view/
-- adjustments.view/shipments.view/settlements.view, deliberately WITHOUT
-- any *.view_profit/*.view_financials permission). Must run here, BEFORE
-- `set role authenticated` below -- the raw INSERT into auth.users/UPDATE
-- on profiles it needs is only permitted for the superuser this script
-- connects as.
-- ---------------------------------------------------------------------------
insert into public.roles (id, key, name_ar, name_en) values
  ('80100000-0000-4000-8000-000000000099', 'p8_ext_report_no_financials', 'مشاهد تقارير بدون تفاصيل مالية (امتداد)', 'Report Viewer No Financials (Extension)')
on conflict (id) do nothing;
insert into public.role_permissions (role_id, permission_id)
  select '80100000-0000-4000-8000-000000000099', p.id
  from public.permissions p
  where p.key in ('reports.view', 'sales.view', 'returns.view', 'adjustments.view', 'shipments.view', 'settlements.view', 'dashboard.view')
on conflict do nothing;
insert into auth.users (id, email) values
  ('80000000-0000-4000-8000-000000000006', 'p8-golden-ext-report-no-fin@example.invalid')
on conflict (id) do nothing;
-- Trusted-bootstrap-context requirement (public.is_trusted_bootstrap_
-- context(), migration 0013) again -- request.jwt.claims is still set to
-- the super admin from the multistore extension's own last RPC call
-- above; clear it back to NULL before this raw activation.
select set_config('request.jwt.claims', '', true);
update public.profiles set full_name = 'Phase8 Extended Report No-Financials Actor', status = 'active', store_access_scope = 'all'
  where id = '80000000-0000-4000-8000-000000000006';
insert into public.user_roles (user_id, role_id) values
  ('80000000-0000-4000-8000-000000000006', '80100000-0000-4000-8000-000000000099')
on conflict do nothing;

set role authenticated;

-- ---------------------------------------------------------------------------
-- (H) Store-2-scoped actor sees ONLY store 2's real sale (not store 1's).
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '80000000-0000-4000-8000-000000000005', 'role', 'authenticated')::text, true);
  v := public.get_sales_report('2026-07-01', '2026-07-31');

  if (v ->> 'total_count')::int <> 1 then
    raise exception 'FAIL H1: expected store-2-scoped actor to see exactly 1 order (their own store only), got total_count=%', v ->> 'total_count';
  end if;
  if v -> 'summary' ->> 'sales_revenue' <> '500.00' then
    raise exception 'FAIL H2: expected store-2-scoped actor sales_revenue=500.00 (their own store only, NOT store 1''s 3500.00), got %', v -> 'summary' ->> 'sales_revenue';
  end if;

  raise notice 'PASS H: store-2-scoped actor sees ONLY their own store''s real sale (revenue=500.00) -- no leakage of store 1''s 3500.00';
end $$;

-- ---------------------------------------------------------------------------
-- (I) The SAME store-2-scoped actor explicitly naming store 1 is REJECTED
-- (§8) -- proven here with a genuinely different, real second store, not a
-- synthetic single-store setup.
-- ---------------------------------------------------------------------------
do $$
declare
  v_rejected boolean := false;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '80000000-0000-4000-8000-000000000005', 'role', 'authenticated')::text, true);
  begin
    perform public.get_sales_report('2026-07-01', '2026-07-31', array['80100000-0000-4000-8000-000000000001']::uuid[]);
  exception when others then
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'FAIL I1: expected explicit store_ids=[store 1] to be REJECTED for a store-2-scoped actor, but it succeeded';
  end if;
  raise notice 'PASS I: store-2-scoped actor explicitly naming store 1 (outside their real scope) is correctly REJECTED (§8)';
end $$;

-- ---------------------------------------------------------------------------
-- (J) The all-stores super admin sees the TRUE COMBINED total across BOTH
-- real stores -- proves no double-counting AND no silent narrowing.
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb; v_summary jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '80000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  v := public.get_sales_report('2026-07-01', '2026-07-31');

  if (v ->> 'total_count')::int <> 2 then
    raise exception 'FAIL J1: expected all-stores actor to see exactly 2 orders (both real stores), got total_count=%', v ->> 'total_count';
  end if;
  if v -> 'summary' ->> 'sales_revenue' <> '4000.00' then
    raise exception 'FAIL J2: expected combined sales_revenue=4000.00 (3500.00 + 500.00 across both real stores), got %', v -> 'summary' ->> 'sales_revenue';
  end if;

  v_summary := public.get_dashboard_summary('2026-07-01', '2026-07-31', null);
  if (v_summary -> 'sales' ->> 'sales_revenue') <> '4000.00' then
    raise exception 'FAIL J3: expected dashboard combined sales_revenue=4000.00 across both real stores, got %', v_summary -> 'sales' ->> 'sales_revenue';
  end if;

  raise notice 'PASS J: all-stores super admin sees the TRUE COMBINED total (4000.00) across both real stores in both get_sales_report() and get_dashboard_summary() -- no double-counting, no silent narrowing';
end $$;

-- ---------------------------------------------------------------------------
-- (K) §79 true key-absence, extended to every row-level report RPC not
-- already sampled elsewhere (cod/categories/karats/payment_methods/
-- collection_channels/daily_management). Uses the "can view, no
-- financials" actor bootstrapped above (before `set role authenticated`),
-- for the same reason the multi-store extension's own actor had to be
-- bootstrapped before any role change -- a raw INSERT into auth.users/
-- UPDATE on profiles is only permitted for the superuser this script
-- connects as, never for the `authenticated` role.
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '80000000-0000-4000-8000-000000000006', 'role', 'authenticated')::text, true);

  v := public.get_cod_report('2026-07-01', '2026-07-31');
  if v -> 'summary' ? 'net_shipping_result' or v -> 'summary' ? 'cod_fee_result' then
    raise exception 'FAIL K1: get_cod_report() must NOT expose financial keys to a non-profit/non-shipping-financials actor, got summary=%', v -> 'summary';
  end if;

  v := public.get_categories_report('2026-07-01', '2026-07-31');
  if v -> 'summary' ? 'gross_profit' or (v -> 'rows' -> 0) ? 'gross_profit' then
    raise exception 'FAIL K2: get_categories_report() must NOT expose gross_profit key to a non-profit actor';
  end if;

  v := public.get_karats_report('2026-07-01', '2026-07-31');
  if v -> 'summary' ? 'gross_profit' or (v -> 'rows' -> 0) ? 'gross_profit' then
    raise exception 'FAIL K3: get_karats_report() must NOT expose gross_profit key to a non-profit actor';
  end if;

  v := public.get_payment_methods_report('2026-07-01', '2026-07-31');
  if v -> 'summary' ? 'net_sales_profit' or (v -> 'rows' -> 0) ? 'net_sales_profit' then
    raise exception 'FAIL K4: get_payment_methods_report() must NOT expose net_sales_profit key to a non-profit actor';
  end if;

  v := public.get_collection_channels_report('2026-07-01', '2026-07-31');
  if v -> 'summary' ? 'net_sales_profit' or (v -> 'rows' -> 0) ? 'net_sales_profit' then
    raise exception 'FAIL K5: get_collection_channels_report() must NOT expose net_sales_profit key to a non-profit actor';
  end if;

  v := public.get_daily_management_report('2026-07-15', null);
  if v ? 'net_operating_return' then
    raise exception 'FAIL K6: get_daily_management_report() must NOT expose the net_operating_return section at all to an actor without dashboard.view_financials';
  end if;

  raise notice 'PASS K: §79 true key-absence confirmed for the remaining 6 previously-unsampled report RPCs (cod/categories/karats/payment_methods/collection_channels/daily_management) -- all 21 report RPCs now covered across the golden-scenario suites';
end $$;

do $$
begin
  raise notice '=== ALL reports_golden_scenario_extended.test.sql ASSERTIONS PASSED (§8/§57-67/§79) ===';
end $$;

rollback;
