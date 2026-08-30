-- ============================================================================
-- FIXTURE — Hotfix 4.2.1 legacy-upgrade proof (Section 22: "Upgrade from
-- 0105 with: active refund events, reversed legacy refund events, and
-- approved returns using fee-engine v1").
-- ============================================================================
-- Run this file against a database that has ONLY migrations 0001-0105 +
-- supabase/seed.sql applied (i.e. exactly Patch 4.2, immediately before
-- Hotfix 4.2.1 ever shipped) — simulating a real production database at
-- that point. THEN apply migrations 0106-latest on top (a SEPARATE psql
-- invocation), THEN run
-- supabase/tests/upgrade_hotfix_4_2_1_legacy_refunds.test.sql (also a
-- separate invocation) — see scripts/run_upgrade_test_hotfix_4_2_1.sh, which
-- drives the whole sequence in the correct order.
--
-- Uses the CURRENT-AT-0105 Returns RPC signatures (jsonb items,
-- collection_state/approved_refund_amount, 7-arg-minus-reference
-- record_sales_return_refund(), 4-arg reverse_sales_return_refund_event()
-- that still does the pre-0107 UPDATE-based soft reversal) — these are
-- exactly what existed immediately before this hotfix.
--
-- Uses COMMITTED inserts (no wrapping transaction) — the data must survive
-- into the next psql invocation that applies 0106-latest and re-reads it.
--
-- Builds THREE tagged Sales+Returns:
--   HF421-ACTIVE   — Sale @400.00 (single item, no deduction), return
--                     approved, ONE refund event recorded for the full
--                     400.00, left ACTIVE (never reversed) — proves an
--                     active event gets NO row in the new reversal ledger
--                     after upgrade, and still counts toward
--                     actual_refunded_total.
--   HF421-REVERSED — Sale @300.00 (single item, no deduction), return
--                     approved, ONE refund event recorded for the full
--                     300.00, then REVERSED with the OLD (pre-0107)
--                     reverse_sales_return_refund_event() — an UPDATE-based
--                     soft reversal (status='reversed' + reversed_at/
--                     reversed_by/reversal_reason/reversal_business_date on
--                     the SAME row). Proves 0106's backfill creates EXACTLY
--                     ONE row in sales_return_refund_event_reversals for it,
--                     carrying over the exact same historical reversal
--                     facts, and that it stops counting toward
--                     actual_refunded_total (which it already didn't, even
--                     pre-upgrade — proving the total is IDENTICAL before
--                     and after migration).
--   HF421-FEEV1    — Sale @1000.00 (single item, so trivially "covers all
--                     remaining items"), a 100.00 deduction, approved_refund_
--                     amount=400.00 — approved under the OLD (v1, item-value/
--                     covers-all-remaining) compute_sales_return_fee_
--                     reversal(): since this is the ONLY item on the order
--                     and it is fully returned, v1's covers_all_remaining
--                     branch fires and reverses the FULL original fee
--                     (100.00) even though only 400.00 of the 1000.00 was
--                     ever actually approved for cash refund — this IS the
--                     historical bug Hotfix 4.2.1 fixes going forward
--                     (Section 7). Proves 0106 backfills
--                     payment_fee_reversal_calculation_version=1 for this
--                     row and NEVER recomputes/rewrites its historical
--                     payment_fee_reversal_amount (still 100.00 after
--                     upgrade, not silently corrected to 40.00).
--
-- Requires: migrations 0001-0105 applied + supabase/seed.sql applied. NOT
-- 0106+ yet.
-- ============================================================================

insert into auth.users (id, email) values
  ('dc000000-0000-4000-8000-000000000001', 'test-hf421-legacy-actor@example.invalid');

update public.profiles set full_name = 'Test Hotfix 4.2.1 Legacy Upgrade Actor', status = 'active', store_access_scope = 'all'
  where id = 'dc000000-0000-4000-8000-000000000001';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'dc000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
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

-- No wrapping BEGIN/COMMIT (see header) — plain (session-scoped) SET is
-- correct, mirroring patch_4_2_legacy_upgrade_pre_fixture.sql's own
-- established convention.
set role authenticated;
set request.jwt.claims = '{"sub":"dc000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_store_id uuid;
  v_karat_id uuid;
  v_category_id uuid;
  v_channel_id uuid;
  v_payment_method_id uuid;

  v_order_id uuid; v_item_id uuid; v_row_version bigint;
  v_return_id uuid; v_return_row_version bigint;
  v_event_id uuid;
begin
  insert into public.stores (code, name_ar, status) values ('HF421L', 'متجر اختبار ترقية 4.2.1', 'active') returning id into v_store_id;
  insert into public.karats (code, name_ar, sort_order, status) values ('HF421K', 'عيار اختبار ترقية 4.2.1', 994, 'active') returning id into v_karat_id;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('hf421cat', 'تصنيف اختبار ترقية 4.2.1', 994, 'active') returning id into v_category_id;
  insert into public.collection_channels (key, name_ar, sort_order, status) values ('hf421chan', 'قناة اختبار ترقية 4.2.1', 994, 'active') returning id into v_channel_id;
  -- 10% flat fee, proportional_reversal.
  insert into public.payment_methods (key, name_ar, fee_model, refund_fee_policy, sort_order, status)
    values ('hf421pm', 'طريقة دفع اختبار ترقية 4.2.1', 'percentage', 'proportional_reversal', 994, 'active') returning id into v_payment_method_id;

  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 300.0000, 'dc000000-0000-4000-8000-000000000001');

  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, public.business_today(), 'hf421 legacy upgrade fixture');
  perform public.create_payment_method_fee_version(v_payment_method_id, 10, 0, public.business_today(), 'hf421 legacy upgrade fixture');

  -- --------------------------------------------------------------------
  -- HF421-ACTIVE — Sale @400.00, full return, one refund event, left ACTIVE.
  -- --------------------------------------------------------------------
  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_payment_method_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 400.00)),
    p_customer_name := 'HF421-ACTIVE'
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 400.00
  );
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_return_row_version;
  perform public.approve_sales_return(v_return_id, v_return_row_version);

  select id into v_event_id from public.record_sales_return_refund(
    v_return_id, 400.00, v_payment_method_id, p_notes := 'hf421 active refund event'
  );

  -- --------------------------------------------------------------------
  -- HF421-REVERSED — Sale @300.00, full return, one refund event, then
  -- REVERSED with the OLD (pre-0107) UPDATE-based reverse_sales_return_
  -- refund_event().
  -- --------------------------------------------------------------------
  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_payment_method_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 300.00)),
    p_customer_name := 'HF421-REVERSED'
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 300.00
  );
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_return_row_version;
  perform public.approve_sales_return(v_return_id, v_return_row_version);

  select id into v_event_id from public.record_sales_return_refund(
    v_return_id, 300.00, v_payment_method_id, p_notes := 'hf421 reversed refund event (pre-reversal)'
  );
  perform public.reverse_sales_return_refund_event(v_event_id, 'hf421 legacy upgrade fixture — reversed pre-4.2.1');

  -- --------------------------------------------------------------------
  -- HF421-FEEV1 — Sale @1000.00 (single item), deduction=100.00,
  -- approved_refund_amount=400.00 — approved under the OLD v1 covers-all-
  -- remaining fee engine, which ignores the cash basis entirely and
  -- reverses the FULL 100.00 fee (the exact historical bug this hotfix
  -- fixes going forward).
  -- --------------------------------------------------------------------
  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_payment_method_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 1000.00)),
    p_customer_name := 'HF421-FEEV1'
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'other',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 400.00,
    p_non_shipping_deduction_amount := 100.00, p_deduction_reason := 'hf421 legacy v1 fee bug fixture',
    p_refund_difference_reason := 'hf421 legacy v1 fee bug fixture — deduction-driven difference',
    p_scenario_notes := 'hf421 legacy v1 fee bug fixture — scenario other requires notes'
  );
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_return_row_version;
  perform public.approve_sales_return(v_return_id, v_return_row_version);
end $$;

reset role;

\echo 'Hotfix 4.2.1 legacy-upgrade pre-fixture applied (HF421-ACTIVE / HF421-REVERSED / HF421-FEEV1) — now apply migrations 0106-latest, then run upgrade_hotfix_4_2_1_legacy_refunds.test.sql'
