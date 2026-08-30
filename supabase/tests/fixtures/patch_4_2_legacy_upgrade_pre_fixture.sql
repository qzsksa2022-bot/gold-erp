-- ============================================================================
-- FIXTURE — Patch 4.2 legacy-upgrade proof (spec item 10 / Section 12
-- "Missing Upgrade Tests"): pre-existing Returns data created with the OLD
-- (pre-0092, i.e. as-of-0091) Returns RPC signatures, on a database that has
-- ONLY migrations 0001-0091 + supabase/seed.sql applied — simulating a real
-- production database immediately before Patch 4.1/4.2 ever shipped.
-- ============================================================================
-- Run this file, THEN apply migrations 0092-latest on top, THEN run
-- supabase/tests/upgrade_patch_4_2_legacy_returns.test.sql (a SEPARATE psql
-- connection/invocation — see scripts/run_upgrade_test_patch_4_2.sh) to
-- verify the backfill/upgrade logic added by 0092-0105 correctly handles
-- data that predates all of it.
--
-- Uses COMMITTED inserts (no wrapping transaction / no rollback) — the
-- whole point is for this data to survive into the next psql invocation
-- that applies 0092-latest and re-reads it. scripts/run_upgrade_test_patch_
-- 4_2.sh always runs this against a throwaway, freshly-dropped-and-recreated
-- database, so nothing here needs cleanup.
--
-- Builds THREE tagged Sales+Returns using the OLD function signatures still
-- live at 0091 (verified by reading 0084/0085/0087/0088/0089 directly):
--   create_sales_return(p_sales_order_id, p_processed_store_id, p_return_date,
--     p_scenario, p_item_ids uuid[], p_scenario_notes default null,
--     p_closed_day_reason default null)   -- plain uuid[], no jsonb items,
--                                            no collection_state/
--                                            approved_refund_amount yet.
--   approve_sales_return(p_return_id, p_expected_version,
--     p_fee_reversal_override default null, p_closed_day_reason default null)
--   reverse_sales_return(p_return_id, p_expected_version, p_reversal_reason)
--     -- no business_date param yet.
--   record_sales_return_refund(p_return_id, p_amount, p_refund_method_id,
--     p_notes default null)   -- no business_date param yet.
--   update_sales_order(...)   -- unchanged since 0084, used to edit the Sale
--     AFTER the Pending return already exists (scenario P42-PENDING).
--
--   P42-PENDING  — Sale created at sale_price 1000.00, a Pending return
--                   created against it, THEN the Sale is edited (old
--                   update_sales_order()) to bump that item's sale_price to
--                   1200.00 — proving 0099's requires_sale_refresh backfill
--                   catches genuinely stale snapshot data (the item's
--                   sale_price_snapshot is still 1000.00 after upgrade),
--                   not merely a row_version mismatch.
--   P42-APPROVED — Sale at 800.00, return created and approved with the OLD
--                   approve_sales_return() — leaves returned_original_sale_
--                   amount/recovered_original_cost_amount/net_sales_profit_
--                   adjustment NULL (0099's three new columns; the old
--                   function never wrote them), proving 0099's backfill UPDATE
--                   populates them correctly after the fact.
--   P42-REVERSED — Sale at 600.00, return created, approved, then reversed
--                   with the OLD reverse_sales_return() — same NULL-backfill
--                   target as P42-APPROVED, but must NOT count toward
--                   adjusted_order_net_sales_profit after the fix (that
--                   computation only sums status='approved' returns).
--
-- Requires: migrations 0001-0091 applied + supabase/seed.sql applied. NOT
-- 0092+ yet.
-- ============================================================================

insert into auth.users (id, email) values
  ('db000000-0000-4000-8000-000000000001', 'test-p42-legacy-actor@example.invalid');

update public.profiles set full_name = 'Test Patch 4.2 Legacy Upgrade Actor', status = 'active', store_access_scope = 'all'
  where id = 'db000000-0000-4000-8000-000000000001';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'db000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in (
    'stores.view', 'stores.create',
    'karats.view', 'karats.manage', 'categories.view', 'categories.manage',
    'collection_channels.view', 'collection_channels.manage',
    'payment_methods.view', 'payment_methods.manage',
    'gold_prices.view', 'gold_prices.edit',
    'manufacturing_fees.view', 'manufacturing_fees.manage',
    'sales.create', 'sales.edit', 'sales.view', 'sales.view_profit',
    'returns.view', 'returns.create', 'returns.approve', 'returns.reverse', 'returns.record_refund'
  );

-- No wrapping BEGIN/COMMIT in this file (see header) — each top-level
-- statement is its own implicit transaction, so `SET LOCAL` here would warn
-- and no-op ("SET LOCAL can only be used in transaction blocks"). Plain
-- (session-scoped) SET is correct: this whole psql invocation is dedicated
-- to this one fixture file and disconnects immediately after.
set role authenticated;
set request.jwt.claims = '{"sub":"db000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_store_id uuid;
  v_karat_id uuid;
  v_category_id uuid;
  v_channel_id uuid;
  v_payment_method_id uuid;

  v_order_id uuid; v_item_id uuid; v_row_version bigint;
  v_return_id uuid; v_return_row_version bigint;
begin
  insert into public.stores (code, name_ar, status) values ('P42LEG', 'متجر اختبار ترقية 4.2', 'active') returning id into v_store_id;
  insert into public.karats (code, name_ar, sort_order, status) values ('P42LK', 'عيار اختبار ترقية 4.2', 994, 'active') returning id into v_karat_id;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('p42lcat', 'تصنيف اختبار ترقية 4.2', 994, 'active') returning id into v_category_id;
  insert into public.collection_channels (key, name_ar, sort_order, status) values ('p42lchan', 'قناة اختبار ترقية 4.2', 994, 'active') returning id into v_channel_id;
  -- 10% flat fee, proportional_reversal — same well-understood formula path
  -- used throughout sales_returns_core.test.sql.
  insert into public.payment_methods (key, name_ar, fee_model, refund_fee_policy, sort_order, status)
    values ('p42lpm', 'طريقة دفع اختبار ترقية 4.2', 'percentage', 'proportional_reversal', 994, 'active') returning id into v_payment_method_id;

  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 300.0000, 'db000000-0000-4000-8000-000000000001');

  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, public.business_today(), 'p42 legacy upgrade fixture');
  perform public.create_payment_method_fee_version(v_payment_method_id, 10, 0, public.business_today(), 'p42 legacy upgrade fixture');

  -- --------------------------------------------------------------------
  -- P42-PENDING — Sale @1000.00, Pending return created, THEN Sale edited
  -- (item sale_price -> 1200.00) AFTER the return already exists.
  -- --------------------------------------------------------------------
  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_payment_method_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 1000.00)),
    p_customer_name := 'P42-PENDING'
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'defective_product', array[v_item_id]
  );

  -- Edit the Sale (old update_sales_order(), unchanged since 0084) AFTER
  -- the Pending return already references this item — the item's price is
  -- bumped from 1000.00 to 1200.00. The financial lock in update_sales_
  -- order() only blocks this once a return is 'approved', so this succeeds
  -- (the return is still 'pending' at this point) — this is exactly the gap
  -- Patch 4.1/4.2's requires_sale_refresh mechanism did not exist yet to
  -- catch at the time.
  -- sales_orders has ZERO direct SELECT RLS policy for `authenticated`
  -- (established convention, same as sales_returns/*) — row_version must be
  -- read via the get_sales_order() RPC, not a direct table read.
  select (public.get_sales_order(v_order_id) ->> 'row_version')::bigint into v_row_version;
  perform public.update_sales_order(
    v_order_id, v_payment_method_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('id', v_item_id, 'category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 1200.00)),
    p_customer_name := 'P42-PENDING',
    p_expected_version := v_row_version
  );

  -- --------------------------------------------------------------------
  -- P42-APPROVED — Sale @800.00, return created and approved with the OLD
  -- approve_sales_return() — leaves 0099's three new financial columns NULL.
  -- --------------------------------------------------------------------
  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_payment_method_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 800.00)),
    p_customer_name := 'P42-APPROVED'
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'defective_product', array[v_item_id]
  );
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_return_row_version;
  perform public.approve_sales_return(v_return_id, v_return_row_version);

  -- --------------------------------------------------------------------
  -- P42-REVERSED — Sale @600.00, return created, approved, then reversed
  -- with the OLD reverse_sales_return() — same NULL-backfill target.
  -- --------------------------------------------------------------------
  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_payment_method_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 600.00)),
    p_customer_name := 'P42-REVERSED'
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'defective_product', array[v_item_id]
  );
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_return_row_version;
  perform public.approve_sales_return(v_return_id, v_return_row_version);
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_return_row_version;
  perform public.reverse_sales_return(v_return_id, v_return_row_version, 'p42 legacy upgrade fixture — reversed pre-4.1');
end $$;

reset role;

\echo 'Patch 4.2 legacy-upgrade pre-fixture applied (P42-PENDING / P42-APPROVED / P42-REVERSED) — now apply migrations 0092-latest, then run upgrade_patch_4_2_legacy_returns.test.sql'
