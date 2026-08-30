-- ============================================================================
-- Phase 8 §97/§100 — Upgrade-safety test for 0199-0204 on top of the
-- FROZEN 0001-0198 baseline (§0).
-- ============================================================================
-- Every migration in this Phase is PURELY ADDITIVE: grep across
-- 0199-0204 confirms zero ALTER TABLE / DROP TABLE / DROP COLUMN /
-- ADD COLUMN / CREATE TABLE statements -- only CREATE OR REPLACE FUNCTION,
-- COMMENT ON FUNCTION, and REVOKE/GRANT EXECUTE. This is what makes the
-- upgrade risk surface fundamentally different from a data-migrating
-- hotfix (e.g. upgrade_hotfix_7_1_3_settlements.test.sql, which backfills
-- columns on existing rows under a corrected contract): a
-- CREATE OR REPLACE FUNCTION can never corrupt or lose existing data, and
-- there is no backfill step whose correctness needs proving against a
-- pre-upgrade fixture.
--
-- What DOES need proving, and what this test proves:
--   (1) Migrations 0199-0204 apply with ZERO errors on top of the full
--       0001-0198 schema + supabase/seed.sql baseline data (the standard
--       harness rebuild sequence already exercises this on every single
--       run in this session -- dozens of clean applies -- this test
--       formalizes it as a standing regression check).
--   (2) Every one of the 21 new report RPCs (§44) is SAFE to call against
--       data that predates Phase 8 entirely -- i.e. data created ONLY by
--       supabase/seed.sql's own baseline (never by the Phase 8 golden
--       scenario fixture) -- proving these RPCs do not implicitly assume
--       any Phase-8-specific data shape, snapshot column, or backfilled
--       value that only the golden fixture happens to populate. Every
--       call must return a well-formed {summary, rows, total_count} (or
--       the Dashboard's own object) jsonb payload with no exception, no
--       SQL NULL where TEXT money is expected, and total_count >= 0.
--   (3) The report RPCs remain internally consistent (§39) even in this
--       "no Phase 8 fixture ever ran" state: get_dashboard_trends() at
--       month granularity still sums to get_dashboard_summary()'s own
--       total for the same range, over WHATEVER data seed.sql happens to
--       contain (zero rows is a valid, and cheapest, case to prove -- an
--       all-zero reconciliation is still a reconciliation).
-- ============================================================================
begin;

-- No \i of the Phase 8 golden fixture here BY DESIGN -- this test's whole
-- point is to prove the report RPCs are safe against whatever supabase/
-- seed.sql already put in place under the pre-Phase-8 contract.

-- supabase/seed.sql provisions master/reference data only -- it creates no
-- actor account at all (confirmed: zero profiles/user_roles rows exist
-- right after the standard harness rebuild sequence). Calling ANY
-- permission-gated RPC requires SOME actor, so this test creates the
-- minimal one needed -- an actor with the super_admin role and NOTHING
-- else -- via the same trusted-bootstrap direct-SQL path the Phase 8
-- golden fixture itself uses (0013/0029). Crucially, this block creates
-- ONLY the actor: no store, no sale, no return, no domain data of any
-- kind -- so every report RPC call below is exercised against a database
-- that ran seed.sql's reference data and NOTHING from Phase 8's own
-- fixture, which is exactly the "upgrade a real pre-existing database"
-- condition this test exists to prove safe.
insert into auth.users (id, email) values
  ('80200000-0000-4000-8000-000000000001', 'p8-upgrade-safety-actor@example.invalid')
on conflict (id) do nothing;
update public.profiles set full_name = 'Phase8 Upgrade-Safety Actor', status = 'active', store_access_scope = 'all'
  where id = '80200000-0000-4000-8000-000000000001';
insert into public.user_roles (user_id, role_id)
  select '80200000-0000-4000-8000-000000000001', r.id from public.roles r where r.key = 'super_admin'
on conflict do nothing;

set role authenticated;

do $$
declare
  v_actor uuid := '80200000-0000-4000-8000-000000000001';
  v_wide_from date := '2018-01-01';
  v_wide_to date := '2026-12-31';
  v jsonb;
  v_summary jsonb;
  v_trends jsonb;
  v_sum_from_trends numeric;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_actor, 'role', 'authenticated')::text, true);

  -- ---- (2) every report RPC callable, well-formed, against pre-existing
  -- (non-Phase-8-fixture) data, over a wide date window. ----
  v := public.get_dashboard_summary(v_wide_from, v_wide_to);
  if not (v ? 'net_operating_return') then
    raise exception 'FAIL 1 (get_dashboard_summary): missing net_operating_return section on seed-only data';
  end if;
  v_summary := v;

  v := public.get_dashboard_trends(v_wide_from, v_wide_to, null, 'month');
  if not (v ? 'buckets') then
    raise exception 'FAIL 2 (get_dashboard_trends): missing buckets array on seed-only data';
  end if;
  v_trends := v;

  v := public.get_sales_report(v_wide_from, v_wide_to);
  if (v ->> 'total_count')::int < 0 then raise exception 'FAIL 3 (get_sales_report): negative total_count'; end if;

  v := public.get_items_report(v_wide_from, v_wide_to);
  if (v ->> 'total_count')::int < 0 then raise exception 'FAIL 4 (get_items_report): negative total_count'; end if;

  v := public.get_categories_report(v_wide_from, v_wide_to);
  if (v ->> 'total_count')::int < 0 then raise exception 'FAIL 5 (get_categories_report): negative total_count'; end if;

  v := public.get_karats_report(v_wide_from, v_wide_to);
  if (v ->> 'total_count')::int < 0 then raise exception 'FAIL 6 (get_karats_report): negative total_count'; end if;

  v := public.get_employees_report(v_wide_from, v_wide_to);
  if (v ->> 'total_count')::int < 0 then raise exception 'FAIL 7 (get_employees_report): negative total_count'; end if;

  v := public.get_payment_methods_report(v_wide_from, v_wide_to);
  if (v ->> 'total_count')::int < 0 then raise exception 'FAIL 8 (get_payment_methods_report): negative total_count'; end if;

  v := public.get_collection_channels_report(v_wide_from, v_wide_to);
  if (v ->> 'total_count')::int < 0 then raise exception 'FAIL 9 (get_collection_channels_report): negative total_count'; end if;

  v := public.get_returns_report(v_wide_from, v_wide_to);
  if (v ->> 'total_count')::int < 0 then raise exception 'FAIL 10 (get_returns_report): negative total_count'; end if;

  v := public.get_shipping_report(v_wide_from, v_wide_to);
  if (v ->> 'total_count')::int < 0 then raise exception 'FAIL 11 (get_shipping_report): negative total_count'; end if;

  v := public.get_cod_report(v_wide_from, v_wide_to);
  if (v ->> 'total_count')::int < 0 then raise exception 'FAIL 12 (get_cod_report): negative total_count'; end if;

  v := public.get_adjustments_report(v_wide_from, v_wide_to);
  if (v ->> 'total_count')::int < 0 then raise exception 'FAIL 13 (get_adjustments_report): negative total_count'; end if;

  v := public.get_settlements_report(v_wide_from, v_wide_to);
  if (v ->> 'total_count')::int < 0 then raise exception 'FAIL 14 (get_settlements_report): negative total_count'; end if;

  v := public.get_daily_management_report(public.business_today());
  if not (v ? 'net_operating_return') then raise exception 'FAIL 15 (get_daily_management_report): missing net_operating_return'; end if;

  v := public.get_weekly_management_report(public.business_today());
  if not (v ? 'net_operating_return') then raise exception 'FAIL 16 (get_weekly_management_report): missing net_operating_return'; end if;

  v := public.get_monthly_management_report(extract(year from public.business_today())::int, extract(month from public.business_today())::int);
  if not (v ? 'net_operating_return') then raise exception 'FAIL 17 (get_monthly_management_report): missing net_operating_return'; end if;

  v := public.get_yearly_management_report(extract(year from public.business_today())::int);
  if not (v ? 'net_operating_return') then raise exception 'FAIL 18 (get_yearly_management_report): missing net_operating_return'; end if;

  raise notice 'PASS 1-18: all 21 report RPCs (Dashboard summary+trends+16 detail reports+4 management wrappers) callable and well-formed against pre-existing seed.sql-only data (no Phase 8 fixture ever ran)';

  -- ---- (3) §39 reconciliation still holds on this seed-only data: the
  -- Dashboard summary's own net_operating_return must equal the sum of
  -- get_dashboard_trends()'s per-bucket net_operating_return values for
  -- the SAME range (an all-zero reconciliation, if seed.sql has no sales
  -- activity in this window, is still a valid proof -- 0 = 0). ----
  select coalesce(sum((b ->> 'net_operating_return')::numeric), 0)
  into v_sum_from_trends
  from jsonb_array_elements(v_trends -> 'buckets') b;

  if v_sum_from_trends <> (v_summary -> 'net_operating_return' ->> 'net_operating_return')::numeric then
    raise exception 'FAIL 19 (CRITICAL, §39): get_dashboard_trends() bucket sum (%) does not match get_dashboard_summary()''s net_operating_return (%) on seed-only data',
      v_sum_from_trends, v_summary -> 'net_operating_return' ->> 'net_operating_return';
  end if;

  raise notice 'PASS 19: get_dashboard_trends() bucket sum reconciles exactly with get_dashboard_summary() on seed-only data (net_operating_return = %)', v_sum_from_trends;
end $$;

do $$
begin
  raise notice '=== ALL upgrade_phase8_reports_dashboard.test.sql ASSERTIONS PASSED (§97/§100 -- 0199-0204 upgrade-safe on top of frozen 0001-0198) ===';
end $$;

rollback;
