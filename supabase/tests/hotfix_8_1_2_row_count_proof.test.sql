-- ============================================================================
-- Hotfix 8.1.2 §37-39 — DB-BACKED >500-row proof for get_items_report()/
-- get_adjustments_report().
-- ============================================================================
-- Hotfix 8.1.1's own row-count coverage (§11-14/§60, "total_count=%i"
-- boundary test in tests/reports-export-route-integration.test.ts) proves
-- the EXPORT pipeline never truncates a large result set — but it does so
-- entirely with a MOCKED Supabase RPC response (hand-built row objects),
-- never real Postgres rows. It never actually proves get_items_report()/
-- get_adjustments_report() THEMSELVES genuinely return >500 real rows with
-- a total_count that matches reality.
--
-- This test closes that gap at the SQL layer: 550 REAL sales orders (via
-- the real create_sales_order() RPC, each with its own uniquely-named
-- item so get_items_report()'s item-identity GROUP BY does not collapse
-- them into fewer rows) and 550 REAL approved adjustments (via the real
-- create_sales_order_adjustment()/approve_sales_order_adjustment() RPCs,
-- one per order) are inserted through the actual production write path —
-- never a raw INSERT, never seeded/fixture-shortcut data pretending to be
-- real. Both report RPCs are then called twice: once with p_limit=5000
-- (comfortably above 550 — proves total_count AND rows.length both
-- genuinely reach 550, no silent cap), and once with p_limit=500 (below
-- 550 — proves total_count STILL correctly reports the true 550 even
-- while rows.length is legitimately page-capped at 500, the exact
-- "total_count must never lie about how much data actually exists"
-- contract §13/§37-39 exists to prove).
--
-- Test-only fixture data, never production seed content — this entire
-- script runs inside one transaction and ends with ROLLBACK (matching
-- every other golden-scenario test in this suite), so nothing it inserts
-- is ever persisted.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- Actor + minimal master data (own dedicated UUID namespace,
-- 81200000-...-...., distinct from every other hotfix/phase fixture's own
-- range so this can run alongside them with zero collision risk).
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('81200000-0000-4000-8000-000000000001', 'h812t-rowproof@example.invalid')
on conflict (id) do nothing;

update public.profiles set full_name = 'H812T Row-Count-Proof Actor', status = 'active', store_access_scope = 'all'
  where id = '81200000-0000-4000-8000-000000000001';

insert into public.user_roles (user_id, role_id)
  select '81200000-0000-4000-8000-000000000001', r.id from public.roles r where r.key = 'super_admin'
on conflict do nothing;

insert into public.stores (id, code, name_ar, status) values
  ('81200000-0000-4000-8000-000000000010', 'H812T-RP', 'متجر إثبات العدد - اختبار 8.1.2', 'active')
on conflict (id) do nothing;

insert into public.karats (id, code, purity_per_mille, name_ar, name_en, sort_order, status) values
  ('81200000-0000-4000-8000-000000000012', 'H812T-RP-K', 875.000, 'عيار إثبات العدد', 'Row Proof Karat', 982, 'active')
on conflict (id) do nothing;

insert into public.product_categories (id, code, name_ar, sort_order, status) values
  ('81200000-0000-4000-8000-000000000013', 'H812T-RP-CAT', 'فئة إثبات العدد', 982, 'active')
on conflict (id) do nothing;

insert into public.payment_methods (id, key, name_ar, fee_model, status, supports_refunds, refund_fee_policy) values
  ('81200000-0000-4000-8000-000000000014', 'h812t-rp-cash', 'نقدًا - إثبات العدد', 'percentage', 'active', true, 'full_reversal')
on conflict (id) do nothing;

insert into public.collection_channels (id, key, name_ar, status) values
  ('81200000-0000-4000-8000-000000000016', 'h812t-rp-direct', 'مباشر - إثبات العدد', 'active')
on conflict (id) do nothing;

insert into public.adjustment_types (id, code, name_ar, status) values
  ('81200000-0000-4000-8000-000000000019', 'H812T-RP-ADJ', 'خدمة إثبات العدد', 'active')
on conflict (id) do nothing;

insert into public.daily_gold_prices (id, price_date, karat_id, price_per_gram, source_type, is_manual_override, created_by, updated_by)
select gen_random_uuid(), d::date, '81200000-0000-4000-8000-000000000012', 200.00, 'manual', true, '81200000-0000-4000-8000-000000000001', '81200000-0000-4000-8000-000000000001'
from generate_series(public.business_today() - 5, public.business_today(), interval '1 day') d
on conflict do nothing;

insert into public.manufacturing_fee_versions (id, karat_id, fee_per_gram, effective_from, status, created_by)
values (gen_random_uuid(), '81200000-0000-4000-8000-000000000012', 50.00, '2020-01-01', 'active', '81200000-0000-4000-8000-000000000001')
on conflict do nothing;

-- seed.sql already installs ONE open-ended (effective_to is null) active
-- vat_rate_versions row (vat_rate_versions_open_idx enforces uniqueness of
-- that open row) — this fixture's own version covers everything strictly
-- before it instead, resolved dynamically so it is never stale.
insert into public.vat_rate_versions (id, rate_percent, effective_from, effective_to, status, created_by)
select gen_random_uuid(), 15.00, '2020-01-01'::date, min(effective_from) - 1, 'active', '81200000-0000-4000-8000-000000000001'
from public.vat_rate_versions
where effective_to is null and status = 'active'
on conflict do nothing;

insert into public.payment_method_fee_versions (id, payment_method_id, percentage_fee, fixed_fee, effective_from, status, created_by)
values (gen_random_uuid(), '81200000-0000-4000-8000-000000000014', 2.00, 0.00, '2020-01-01', 'active', '81200000-0000-4000-8000-000000000001')
on conflict do nothing;

-- Deliberately NOT `set role authenticated` -- this fixture needs plain
-- (non-RLS-filtered) SELECTs on sales_order_adjustments to read back
-- row_version between create/approve calls (matching phase8_golden_
-- scenario_fixture.sql/phase8_performance_fixture.sql's own established
-- convention: stay as the connecting superuser, and let every RPC's own
-- SECURITY DEFINER permission check resolve the acting actor purely from
-- `request.jwt.claims` below, exactly as it would for a real authenticated
-- request -- sales_order_adjustments has row-level security ENABLED with
-- NO permissive policies at all, so a direct SELECT under `authenticated`
-- would deterministically return zero rows / NULL, not real data).
-- ---------------------------------------------------------------------------
-- 550 REAL sales orders (each one distinct item -> 550 distinct
-- get_items_report() item-identity rows) + 550 REAL approved adjustments
-- (one per order -> 550 get_adjustments_report() rows), all on the SAME
-- business date/store so both reports' date-range/store filter stays
-- trivial — the point of this fixture is row COUNT fidelity, not scenario
-- variety (that is already covered elsewhere, e.g. reports_detail_golden_
-- scenario.test.sql).
-- ---------------------------------------------------------------------------
do $$
declare
  v_store uuid := '81200000-0000-4000-8000-000000000010';
  v_karat uuid := '81200000-0000-4000-8000-000000000012';
  v_cat uuid := '81200000-0000-4000-8000-000000000013';
  v_pm uuid := '81200000-0000-4000-8000-000000000014';
  v_ch uuid := '81200000-0000-4000-8000-000000000016';
  v_adjtype uuid := '81200000-0000-4000-8000-000000000019';
  v_date date := public.business_today();
  v_n integer := 550;
  v_order_id uuid;
  v_adj_id uuid;
  v_adj_version bigint;
  v jsonb;
  i integer;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '81200000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);

  for i in 1..v_n loop
    select t.id into v_order_id from public.create_sales_order(
      v_store, v_date, v_pm, v_ch,
      jsonb_build_array(jsonb_build_object(
        'category_id', v_cat, 'karat_id', v_karat,
        'weight_grams', 5.000, 'sale_price', 1000.00, 'item_name', 'H812T RowProof Item ' || i
      )),
      'H812T RowProof Customer ' || i, null, null
    ) as t;

    select t.id into v_adj_id from public.create_sales_order_adjustment(
      v_order_id, v_adjtype, v_store, v_date, v_pm, v_ch, true, 50.00, 20.00, 'H812T RowProof adjustment ' || i
    ) as t;
    select row_version into v_adj_version from public.sales_order_adjustments where id = v_adj_id;
    perform public.approve_sales_order_adjustment(v_adj_id, v_adj_version);
  end loop;

  -- -------------------------------------------------------------------------
  -- (A) get_items_report() — p_limit=5000 (>550): both total_count AND
  -- rows.length must genuinely reach 550. No mock, no fixture shortcut —
  -- these are the real 550 orders just created above, aggregated by the
  -- real production RPC.
  -- -------------------------------------------------------------------------
  v := public.get_items_report(v_date, v_date, array[v_store], null, null, null, 'revenue_desc', 5000, 0, null);
  if (v ->> 'total_count')::int <> v_n then
    raise exception 'FAIL A1: get_items_report() total_count expected % (real distinct items just inserted), got %', v_n, v ->> 'total_count';
  end if;
  if jsonb_array_length(v -> 'rows') <> v_n then
    raise exception 'FAIL A2: get_items_report() rows array expected % real rows (limit=5000 > total), got %', v_n, jsonb_array_length(v -> 'rows');
  end if;
  raise notice 'PASS A: get_items_report() genuinely returns % real DB rows (total_count AND rows.length both match, limit=5000)', v_n;

  -- -------------------------------------------------------------------------
  -- (B) get_items_report() — p_limit=500 (<550): total_count must STILL
  -- report the TRUE 550 while rows.length is legitimately page-capped at
  -- 500 -- proves total_count never silently narrows to match a truncated
  -- page (§13/§37-39's core anti-truncation claim).
  -- -------------------------------------------------------------------------
  v := public.get_items_report(v_date, v_date, array[v_store], null, null, null, 'revenue_desc', 500, 0, null);
  if (v ->> 'total_count')::int <> v_n then
    raise exception 'FAIL B1: get_items_report() total_count must still report the TRUE % even when p_limit=500 caps the page, got %', v_n, v ->> 'total_count';
  end if;
  if jsonb_array_length(v -> 'rows') <> 500 then
    raise exception 'FAIL B2: get_items_report() rows array expected exactly 500 (the page cap), got %', jsonb_array_length(v -> 'rows');
  end if;
  raise notice 'PASS B: get_items_report() total_count=% (true total) never collapses to rows.length=500 (the page cap) -- no silent truncation lie', v_n;

  -- -------------------------------------------------------------------------
  -- (C) get_adjustments_report() — p_limit=5000 (>550): same real-row
  -- proof as (A), for the second RPC named in §37-39.
  -- -------------------------------------------------------------------------
  v := public.get_adjustments_report(v_date, v_date, array[v_store], null, null, 'movement_date_desc', 5000, 0);
  if (v ->> 'total_count')::int <> v_n then
    raise exception 'FAIL C1: get_adjustments_report() total_count expected % (real approved adjustments just inserted), got %', v_n, v ->> 'total_count';
  end if;
  if jsonb_array_length(v -> 'rows') <> v_n then
    raise exception 'FAIL C2: get_adjustments_report() rows array expected % real rows (limit=5000 > total), got %', v_n, jsonb_array_length(v -> 'rows');
  end if;
  raise notice 'PASS C: get_adjustments_report() genuinely returns % real DB rows (total_count AND rows.length both match, limit=5000)', v_n;

  -- -------------------------------------------------------------------------
  -- (D) get_adjustments_report() — p_limit=500 (<550): same
  -- total_count-never-lies proof as (B), for the second RPC.
  -- -------------------------------------------------------------------------
  v := public.get_adjustments_report(v_date, v_date, array[v_store], null, null, 'movement_date_desc', 500, 0);
  if (v ->> 'total_count')::int <> v_n then
    raise exception 'FAIL D1: get_adjustments_report() total_count must still report the TRUE % even when p_limit=500 caps the page, got %', v_n, v ->> 'total_count';
  end if;
  if jsonb_array_length(v -> 'rows') <> 500 then
    raise exception 'FAIL D2: get_adjustments_report() rows array expected exactly 500 (the page cap), got %', jsonb_array_length(v -> 'rows');
  end if;
  raise notice 'PASS D: get_adjustments_report() total_count=% (true total) never collapses to rows.length=500 (the page cap) -- no silent truncation lie', v_n;
end $$;

do $$
begin
  raise notice '=== ALL hotfix_8_1_2_row_count_proof.test.sql ASSERTIONS PASSED (§37-39: genuine >500-real-row DB proof for get_items_report()/get_adjustments_report()) ===';
end $$;

rollback;
