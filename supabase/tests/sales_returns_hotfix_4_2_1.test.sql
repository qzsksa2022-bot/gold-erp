-- ============================================================================
-- Integration test: Phase 4 — Final Hotfix 4.2.1 (migrations 0106-0112)
-- ============================================================================
-- Dedicated to the NEW behavior this hotfix introduces on top of the
-- already-covered sales_returns_core.test.sql / sales_returns_concurrency.
-- test.sql / upgrade_hotfix_4_2_1_legacy_refunds.test.sql. Each scenario is
-- tagged inline with the spec section/letter it proves:
--
--   Section 14 (payment-fee-reversal-basis regression tests):
--     A — proportional_reversal + deduction: fee reversal is basis on
--         approved_refund_amount (40.00), never returned-item value (which
--         would wrongly give 50.00).
--     B — proportional_reversal cumulative-rounding absorption lands
--         exactly on the original fee across three sequential returns
--         (333.33/333.33/333.34 -> 10.00 total), matching the spec's exact
--         worked numbers (see also sales_returns_core.test.sql scenario 3,
--         which proves the same invariant at a different fee scale).
--     C — full_reversal + deduction: ALL items returned but the cumulative
--         approved-refund basis (800/1000) never reaches the order
--         subtotal -> ZERO fee reversal, despite 100% item coverage.
--     D — full_reversal, genuine full cash refund (cumulative basis reaches
--         the order subtotal) -> the FULL remaining fee is reversed.
--     E — customer_never_received + not_collected (approved_refund_amount
--         forced to 0 by the existing DB CHECK) -> zero fee reversal under
--         BOTH proportional_reversal and full_reversal, with no special
--         case needed (falls out of the basis formula naturally).
--     F — legacy v1-computed historical payment_fee_reversal_amount must
--         survive migration unchanged — covered by the DEDICATED upgrade
--         harness (supabase/tests/upgrade_hotfix_4_2_1_legacy_refunds.test.
--         sql, scenario C / HF421-FEEV1), not repeated here (a v1-computed
--         row cannot exist on a database where every migration, including
--         0109, is already applied — approve_sales_return() only ever
--         calls the v2 engine from 0109 forward).
--
--   Section 18 (append-only ledger regression tests, numbered 1-10 per
--   spec; the dedicated legacy-upgrade variant lives in
--   upgrade_hotfix_4_2_1_legacy_refunds.test.sql scenario B / HF421-REVERSED):
--     1-10 — record an event, capture its original values, reverse it,
--         confirm the ORIGINAL row is byte-for-byte unchanged, confirm
--         exactly one new row in sales_return_refund_event_reversals,
--         confirm actual_refunded_total excludes it, confirm a second
--         reversal of the SAME event is rejected, confirm reconciliation
--         history is preserved, confirm get_sales_return() shows the event
--         as reversed (DERIVED), confirm reference/method-name-snapshot are
--         visible.
--
--   Section 6/17 — reference + refund_method_name_snapshot round-trip.
--   Section 15 — a returns.create-only actor (no sales.view at all) can run
--         the full New Return flow via search_sales_orders_for_return() +
--         get_returnable_sales_order() + create_sales_return(), while
--         list_sales_orders() (the Sales module's own RPC) stays forbidden.
--   Section 20 — preview_sales_return() fee-basis parity with
--         approve_sales_return(), on the SAME approved-refund-basis engine.
--
-- Safe to run against a real database: everything happens inside a
-- transaction that is ALWAYS rolled back at the end (mirrors
-- sales_returns_core.test.sql's own convention exactly).
--
-- Requires migrations 0001-latest (including 0106-0112) + supabase/seed.sql
-- already applied.
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/sales_returns_hotfix_4_2_1.test.sql
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0. Setup — actors, store, master data. Prefix 'de...' / 'H421...' is not
-- used by any other test file (checked against s3/S3, d4/d6/d7/d8/d9/S4,
-- db.../P42, dc.../HF421L), so this file can never collide even if chained
-- into one transaction with the others.
--
--   01 = Returns Manager — full Sales + Returns permission set, mirrors
--        sales_returns_core.test.sql's own manager actor.
--   02 = returns.create-ONLY actor (Section 15) — deliberately holds NO
--        sales.view, NOT EVEN sales.create — proving returns.create truly
--        stands alone for the New Return flow.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('de000000-0000-4000-8000-000000000001', 'test-hf421-manager@example.invalid'),
  ('de000000-0000-4000-8000-000000000002', 'test-hf421-createonly@example.invalid');

update public.profiles set full_name = 'Test Hotfix 4.2.1 Returns Manager', status = 'active', store_access_scope = 'all'
  where id = 'de000000-0000-4000-8000-000000000001';
update public.profiles set full_name = 'Test Hotfix 4.2.1 returns.create-only Actor', status = 'active', store_access_scope = 'all'
  where id = 'de000000-0000-4000-8000-000000000002';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'de000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in (
    'stores.view', 'stores.create',
    'karats.view', 'karats.manage', 'categories.view', 'categories.manage',
    'collection_channels.view', 'collection_channels.manage',
    'payment_methods.view', 'payment_methods.manage',
    'gold_prices.view', 'gold_prices.edit',
    'manufacturing_fees.view', 'manufacturing_fees.manage',
    'sales.create', 'sales.edit', 'sales.view', 'sales.view_profit', 'sales.close_day',
    'returns.view', 'returns.create', 'returns.approve', 'returns.reverse',
    'returns.record_refund', 'returns.process_closed_day'
  );

-- Section 15 — deliberately ONLY returns.create. No sales.view, no
-- sales.create, no returns.view/approve/record_refund.
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'de000000-0000-4000-8000-000000000002', id, 'grant' from public.permissions
  where key in ('returns.create');

set role authenticated;
set local request.jwt.claims = '{"sub":"de000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_store_id uuid;
  v_karat_id uuid;
  v_category_id uuid;
  v_channel_id uuid;
  v_pm_prop uuid;
  v_pm_full uuid;
  v_pm_prop_1pct uuid;
begin
  insert into public.stores (code, name_ar, status) values ('H421STA', 'متجر اختبار Hotfix 4.2.1', 'active') returning id into v_store_id;
  insert into public.karats (code, name_ar, sort_order, status) values ('H421K1', 'عيار اختبار Hotfix 4.2.1', 994, 'active') returning id into v_karat_id;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('h421cat', 'تصنيف اختبار Hotfix 4.2.1', 994, 'active') returning id into v_category_id;
  insert into public.collection_channels (key, name_ar, sort_order, status) values ('h421chan', 'قناة اختبار Hotfix 4.2.1', 994, 'active') returning id into v_channel_id;

  -- 10% flat fee, proportional_reversal — Tests A/B(scaled)/E/append-only.
  insert into public.payment_methods (key, name_ar, fee_model, refund_fee_policy, sort_order, status)
    values ('h421pm', 'طريقة دفع اختبار Hotfix 4.2.1 (تناسبي)', 'percentage', 'proportional_reversal', 994, 'active') returning id into v_pm_prop;
  -- 10% flat fee, full_reversal — Tests C/D/E.
  insert into public.payment_methods (key, name_ar, fee_model, refund_fee_policy, sort_order, status)
    values ('h421pmf', 'طريقة دفع اختبار Hotfix 4.2.1 (استرداد كامل)', 'percentage', 'full_reversal', 995, 'active') returning id into v_pm_full;
  -- 1% flat fee, proportional_reversal — Test B (exact spec numbers: fee=10 on subtotal=1000).
  insert into public.payment_methods (key, name_ar, fee_model, refund_fee_policy, sort_order, status)
    values ('h421pm1', 'طريقة دفع اختبار Hotfix 4.2.1 (تناسبي 1%)', 'percentage', 'proportional_reversal', 996, 'active') returning id into v_pm_prop_1pct;

  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 300.0000, 'de000000-0000-4000-8000-000000000001');

  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, public.business_today(), 'hf421 fixture');
  perform public.create_payment_method_fee_version(v_pm_prop, 10, 0, public.business_today(), 'hf421 fixture proportional 10%');
  perform public.create_payment_method_fee_version(v_pm_full, 10, 0, public.business_today(), 'hf421 fixture full_reversal 10%');
  perform public.create_payment_method_fee_version(v_pm_prop_1pct, 1, 0, public.business_today(), 'hf421 fixture proportional 1%');
end $$;

-- ============================================================================
-- A (Section 14-A / Section 7) — proportional_reversal + deduction: fee
-- basis is approved_refund_amount, never returned-item value.
-- Order subtotal=1000 (two items: 500 returned + 500 untouched), fee=100
-- (10%). Return: item value=500, deduction=100, approved_refund_amount=400.
-- Expected fee reversal = 100*400/1000 = 40.00, NOT the 50.00 the old
-- item-value-basis engine would have given.
-- ============================================================================
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_order_id uuid; v_item_1 uuid; v_return_id uuid; v_row_version bigint;
  v_return jsonb;
begin
  select id into v_store_id from public.stores where code = 'H421STA';
  select id into v_karat_id from public.karats where code = 'H421K1';
  select id into v_category_id from public.product_categories where code = 'h421cat';
  select id into v_channel_id from public.collection_channels where key = 'h421chan';
  select id into v_pm_id from public.payment_methods where key = 'h421pm';

  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(
      jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 500.00),
      jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 500.00)
    ),
    'HF421-A'
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_1;

  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'other',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_1)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 400.00,
    p_non_shipping_deduction_amount := 100.00, p_deduction_reason := 'A: خصم اختبار Section 14-A',
    p_refund_difference_reason := 'A: فرق ناتج عن الاستقطاع', p_scenario_notes := 'A: سيناريو أخرى يتطلب ملاحظات'
  );
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_id, v_row_version);

  v_return := public.get_sales_return(v_return_id);
  assert v_return ->> 'payment_fee_reversal_amount' = '40.00', format('A.1 استرداد العمولة (أساس الاسترداد المعتمد) يجب أن يكون 40.00 وليس 50.00 (قيمة البند)، وجد %s', v_return ->> 'payment_fee_reversal_amount');
  assert v_return ->> 'payment_fee_reversal_calculation_version' = '2', format('A.2 إصدار الاحتساب يجب أن يكون 2 (المحرك الجديد)، وجد %s', v_return ->> 'payment_fee_reversal_calculation_version');
  raise notice 'OK: A.1/A.2 (Section 14-A/7) proportional_reversal + استقطاع: استرداد العمولة = 40.00 على أساس الاسترداد المعتمد، مُعلَّم calculation_version=2';
end $$;

-- ============================================================================
-- B (Section 14-B) — proportional_reversal cumulative-rounding absorption,
-- EXACT spec numbers: subtotal=1000, fee=10; three sequential approved
-- returns (333.33/333.33/333.34) -> cumulative fee reversal = 10.00 exactly
-- after the third.
-- ============================================================================
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_order_id uuid;
  v_item_a uuid; v_item_b uuid; v_item_c uuid;
  v_return_a uuid; v_return_b uuid; v_return_c uuid;
  v_row_version bigint;
  v_order jsonb; v_return jsonb; v_elem jsonb;
  v_cumulative numeric;
begin
  select id into v_store_id from public.stores where code = 'H421STA';
  select id into v_karat_id from public.karats where code = 'H421K1';
  select id into v_category_id from public.product_categories where code = 'h421cat';
  select id into v_channel_id from public.collection_channels where key = 'h421chan';
  select id into v_pm_id from public.payment_methods where key = 'h421pm1';

  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(
      jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 333.33),
      jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 333.33),
      jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 333.34)
    ),
    'HF421-B'
  );

  v_order := public.get_sales_order(v_order_id);
  assert v_order ->> 'payment_fee_amount' = '10.00', format('B.0 عمولة الدفع يجب أن تكون 10.00 بالضبط (1%% من 1000.00)، وجدت %s', v_order ->> 'payment_fee_amount');

  for v_elem in select * from jsonb_array_elements(v_order -> 'items')
  loop
    if v_elem ->> 'sale_price' = '333.34' then
      v_item_c := (v_elem ->> 'id')::uuid;
    elsif v_item_a is null then
      v_item_a := (v_elem ->> 'id')::uuid;
    else
      v_item_b := (v_elem ->> 'id')::uuid;
    end if;
  end loop;

  select id into v_return_a from public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'other',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_a)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 333.33,
    p_scenario_notes := 'B: سيناريو أخرى يتطلب ملاحظات'
  );
  select (public.get_sales_return(v_return_a) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_a, v_row_version);
  v_return := public.get_sales_return(v_return_a);
  assert v_return ->> 'payment_fee_reversal_amount' = '3.33', format('B.1 استرداد عمولة المرتجع الأول يجب أن يكون 3.33، وجد %s', v_return ->> 'payment_fee_reversal_amount');

  select id into v_return_b from public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'other',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_b)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 333.33,
    p_scenario_notes := 'B: سيناريو أخرى يتطلب ملاحظات'
  );
  select (public.get_sales_return(v_return_b) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_b, v_row_version);
  v_return := public.get_sales_return(v_return_b);
  assert v_return ->> 'payment_fee_reversal_amount' = '3.34', format('B.2 استرداد عمولة المرتجع الثاني (تراكمي) يجب أن يكون 3.34، وجد %s', v_return ->> 'payment_fee_reversal_amount');

  select id into v_return_c from public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'other',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_c)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 333.34,
    p_scenario_notes := 'B: سيناريو أخرى يتطلب ملاحظات'
  );
  select (public.get_sales_return(v_return_c) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_c, v_row_version);
  v_return := public.get_sales_return(v_return_c);
  assert v_return ->> 'payment_fee_reversal_amount' = '3.33', format('B.3 استرداد عمولة المرتجع الثالث (إغلاق الأساس التراكمي عند 1000.00) يجب أن يكون 3.33، وجد %s', v_return ->> 'payment_fee_reversal_amount');

  select coalesce(sum(payment_fee_reversal_amount::numeric), 0) into v_cumulative
  from public.list_sales_returns(p_sales_order_id := v_order_id, p_status := 'approved', p_limit := 200);
  assert v_cumulative = 10.00, format('B.4 مجموع استرداد العمولة التراكمي عبر الثلاث مرتجعات يجب أن يساوي 10.00 بالضبط (عمولة العملية الأصلية)، وجد %s', v_cumulative);
  raise notice 'OK: A-D (Section 14-B) 333.33+333.33+333.34 -> استرداد عمولة تراكمي 3.33+3.34+3.33=10.00 بالضبط — لا فارق تقريب متبقٍّ';
end $$;

-- ============================================================================
-- C (Section 14-C / Section 10) — full_reversal + deduction: ALL items
-- returned, cumulative approved-refund basis (800/1000) never reaches the
-- subtotal -> ZERO fee reversal despite 100% item coverage.
-- ============================================================================
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_order_id uuid; v_item_id uuid; v_return_id uuid; v_row_version bigint;
  v_return jsonb; v_returnable jsonb;
begin
  select id into v_store_id from public.stores where code = 'H421STA';
  select id into v_karat_id from public.karats where code = 'H421K1';
  select id into v_category_id from public.product_categories where code = 'h421cat';
  select id into v_channel_id from public.collection_channels where key = 'h421chan';
  select id into v_pm_id from public.payment_methods where key = 'h421pmf';

  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 1000.00)),
    'HF421-C'
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'other',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 800.00,
    p_non_shipping_deduction_amount := 200.00, p_deduction_reason := 'C: خصم اختبار Section 14-C',
    p_refund_difference_reason := 'C: فرق ناتج عن الاستقطاع', p_scenario_notes := 'C: سيناريو أخرى يتطلب ملاحظات'
  );
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_id, v_row_version);

  v_returnable := public.get_returnable_sales_order(v_order_id);
  assert v_returnable ->> 'order_state' = 'full', format('C.1 order_state يجب أن يصبح full (كل البنود مرتجعة)، وجد %s', v_returnable ->> 'order_state');

  v_return := public.get_sales_return(v_return_id);
  assert v_return ->> 'payment_fee_reversal_amount' = '0.00', format('C.2 استرداد العمولة يجب أن يكون 0.00 رغم تغطية كل البنود، لأن الأساس النقدي التراكمي (800.00) لم يبلغ 1000.00، وجد %s', v_return ->> 'payment_fee_reversal_amount');
  raise notice 'OK: C (Section 14-C/10) full_reversal + استقطاع: تغطية 100%% للبنود لكن الأساس النقدي 800/1000 -> استرداد عمولة صفري';
end $$;

-- ============================================================================
-- D (Section 14-D / Section 10) — full_reversal, genuine full cash refund
-- (cumulative basis reaches the subtotal) -> full remaining fee reversed.
-- ============================================================================
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_order_id uuid; v_item_id uuid; v_return_id uuid; v_row_version bigint;
  v_return jsonb;
begin
  select id into v_store_id from public.stores where code = 'H421STA';
  select id into v_karat_id from public.karats where code = 'H421K1';
  select id into v_category_id from public.product_categories where code = 'h421cat';
  select id into v_channel_id from public.collection_channels where key = 'h421chan';
  select id into v_pm_id from public.payment_methods where key = 'h421pmf';

  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 1000.00)),
    'HF421-D'
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 1000.00
  );
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_id, v_row_version);

  v_return := public.get_sales_return(v_return_id);
  assert v_return ->> 'payment_fee_reversal_amount' = '100.00', format('D.1 استرداد العمولة يجب أن يكون 100.00 (كامل العمولة) لأن الأساس النقدي بلغ 1000.00 بالضبط، وجد %s', v_return ->> 'payment_fee_reversal_amount');
  raise notice 'OK: D (Section 14-D/10) full_reversal + استرداد نقدي كامل حقيقي: الأساس التراكمي بلغ 1000.00 -> استرداد العمولة كاملاً (100.00)';
end $$;

-- ============================================================================
-- E (Section 14-E / Section 12) — customer_never_received + not_collected
-- (approved_refund_amount forced to 0 by the existing DB CHECK) -> zero fee
-- reversal under BOTH proportional_reversal and full_reversal.
-- ============================================================================
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid;
  v_pm_prop uuid; v_pm_full uuid;
  v_order_id uuid; v_item_id uuid; v_return_id uuid; v_row_version bigint;
  v_return jsonb;
begin
  select id into v_store_id from public.stores where code = 'H421STA';
  select id into v_karat_id from public.karats where code = 'H421K1';
  select id into v_category_id from public.product_categories where code = 'h421cat';
  select id into v_channel_id from public.collection_channels where key = 'h421chan';
  select id into v_pm_prop from public.payment_methods where key = 'h421pm';
  select id into v_pm_full from public.payment_methods where key = 'h421pmf';

  -- proportional_reversal leg.
  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_prop, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 2000.00)),
    'HF421-E-PROP'
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'customer_never_received',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'not_collected', 0.00,
    p_refund_difference_reason := 'E: لم يتم تحصيل المبلغ من العميل أصلاً'
  );
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_id, v_row_version);
  v_return := public.get_sales_return(v_return_id);
  assert v_return ->> 'payment_fee_reversal_amount' = '0.00', format('E.1 (proportional_reversal) استرداد العمولة يجب أن يكون 0.00 عندما approved_refund_amount=0، وجد %s', v_return ->> 'payment_fee_reversal_amount');

  -- full_reversal leg.
  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_full, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 2000.00)),
    'HF421-E-FULL'
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'customer_never_received',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'not_collected', 0.00,
    p_refund_difference_reason := 'E: لم يتم تحصيل المبلغ من العميل أصلاً'
  );
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_id, v_row_version);
  v_return := public.get_sales_return(v_return_id);
  assert v_return ->> 'payment_fee_reversal_amount' = '0.00', format('E.2 (full_reversal) استرداد العمولة يجب أن يكون 0.00 عندما approved_refund_amount=0، وجد %s', v_return ->> 'payment_fee_reversal_amount');

  raise notice 'OK: E (Section 14-E/12) customer_never_received+not_collected: استرداد عمولة صفري تحت كل من proportional_reversal وfull_reversal دون أي حالة خاصة في الصيغة';
end $$;

-- ============================================================================
-- 1-10 (Section 18) — append-only ledger regression: record, capture, reverse,
-- confirm the original row is UNCHANGED, confirm exactly one new reversal
-- row, confirm actual_refunded_total excludes it, confirm a second reversal
-- is rejected, confirm reconciliation history preserved, confirm
-- get_sales_return() shows the derived reversed status, confirm reference/
-- method-name-snapshot are visible.
-- ============================================================================
-- sales_return_refund_events / sales_return_refund_event_reversals have
-- ZERO direct SELECT RLS policy for `authenticated` (established convention
-- since 0082, see sales_returns_core.test.sql's own header) — steps (2),
-- (4), (5) below need a genuine direct-table read to check columns
-- get_sales_return() does not expose (created_at) or a raw COUNT, so those
-- specific reads happen after `reset role;` (superuser), with ids handed
-- across role switches via set_config()/current_setting() — the same
-- established idiom sales_returns_core.test.sql itself uses (see its own
-- scenario Q, s4.q_return_id).
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_order_id uuid; v_item_id uuid; v_return_id uuid; v_row_version bigint;
  v_event_id uuid;
begin
  select id into v_store_id from public.stores where code = 'H421STA';
  select id into v_karat_id from public.karats where code = 'H421K1';
  select id into v_category_id from public.product_categories where code = 'h421cat';
  select id into v_channel_id from public.collection_channels where key = 'h421chan';
  select id into v_pm_id from public.payment_methods where key = 'h421pm';

  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 250.00)),
    'HF421-18'
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 250.00
  );
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_id, v_row_version);

  -- (1) Record a Refund event, with a reference (Section 6).
  select id into v_event_id from public.record_sales_return_refund(
    v_return_id, 250.00, v_pm_id, p_notes := '18.1 ملاحظات', p_reference := '18.1-REF-0001'
  );

  perform set_config('hf421.event_id', v_event_id::text, false);
  perform set_config('hf421.return_id', v_return_id::text, false);
end $$;

reset role;

-- (2) Save the original values via a genuine direct-table read.
create temporary table hf421_18_orig as
  select amount, refund_method_id, refund_business_date, notes, reference, created_at, refund_method_name_snapshot
  from public.sales_return_refund_events where id = current_setting('hf421.event_id')::uuid;

do $$
begin
  assert (select reference from hf421_18_orig) = '18.1-REF-0001', '1/6.1 المرجع المُدخَل عند التسجيل يجب أن يُحفظ كما هو';
  assert (select refund_method_name_snapshot from hf421_18_orig) is not null, '1/17.1 refund_method_name_snapshot يجب أن يُملأ عند التسجيل';
  raise notice 'OK: 1/2 (Section 18) تسجيل حدث استرداد + حفظ قيمه الأصلية (بما فيها المرجع Section 6 ولقطة اسم طريقة الاسترداد Section 17)';
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"de000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- (3) Reverse the event.
do $$
begin
  perform public.reverse_sales_return_refund_event(current_setting('hf421.event_id')::uuid, '18.3 سبب التراجع');
end $$;

reset role;

-- (4) Confirm the original row did NOT change at all.
do $$
declare
  v_event_id uuid := current_setting('hf421.event_id')::uuid;
  v_unchanged boolean;
begin
  select
    e.amount = o.amount and e.refund_method_id = o.refund_method_id and e.refund_business_date = o.refund_business_date
    and e.notes = o.notes and e.reference = o.reference and e.created_at = o.created_at
    and e.refund_method_name_snapshot = o.refund_method_name_snapshot
  into v_unchanged
  from public.sales_return_refund_events e, hf421_18_orig o
  where e.id = v_event_id;
  assert v_unchanged, '4 الصف الأصلي يجب ألا يتغيّر إطلاقًا بعد التراجع — لا UPDATE على أي عمود من أعمدته';
  raise notice 'OK: 4 (Section 18) الصف الأصلي لم يتغيّر بتاتًا بعد التراجع — append-only حقيقي';
end $$;

-- (5) Confirm a new Reversal row exists (exactly one).
do $$
declare
  v_reversal_count int;
begin
  select count(*) into v_reversal_count from public.sales_return_refund_event_reversals where refund_event_id = current_setting('hf421.event_id')::uuid;
  assert v_reversal_count = 1, format('5 يجب أن يوجد صف واحد بالضبط في sales_return_refund_event_reversals، وجد %s', v_reversal_count);
  raise notice 'OK: 5 (Section 18) صف إلغاء واحد جديد أُنشئ في sales_return_refund_event_reversals';
end $$;

drop table hf421_18_orig;

set role authenticated;
set local request.jwt.claims = '{"sub":"de000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_return_id uuid := current_setting('hf421.return_id')::uuid;
  v_event_id uuid := current_setting('hf421.event_id')::uuid;
  v_row_version bigint;
  v_return jsonb;
  v_second_reversal_failed boolean := false;
begin
  -- (6) Confirm actual_refunded_total excludes it.
  v_return := public.get_sales_return(v_return_id);
  assert v_return ->> 'actual_refunded_total' = '0.00', format('6 actual_refunded_total يجب أن يستبعد الحدث المتراجَع عنه (0.00)، وجد %s', v_return ->> 'actual_refunded_total');
  raise notice 'OK: 6 (Section 18) actual_refunded_total يستبعد الحدث المتراجَع عنه';

  -- (7) Reversing the same event a second time -> rejected.
  begin
    perform public.reverse_sales_return_refund_event(v_event_id, '18.7 محاولة تراجع ثانية');
  exception when others then
    v_second_reversal_failed := true;
    assert sqlerrm like '%متراجَع عنه بالفعل%', format('7 رسالة رفض التراجع الثاني غير متوقعة: %s', sqlerrm);
  end;
  assert v_second_reversal_failed, '7 التراجع عن نفس الحدث مرتين يجب أن يُرفض في المرة الثانية';
  raise notice 'OK: 7 (Section 18) محاولة تراجع ثانية عن نفس الحدث رُفضت بوضوح';

  -- (8) Reconciliation history preserved — finalize creates a permanent
  -- history row that survives regardless of the ledger's own state.
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.finalize_sales_return_refund(v_return_id, v_row_version, '18.8 فرق متوقع (الاسترداد الوحيد متراجَع عنه)');
  v_return := public.get_sales_return(v_return_id);
  assert jsonb_array_length(v_return -> 'reconciliation_history') = 1, '8 سجل تسوية الاسترداد يجب أن يحوي حدثًا واحدًا بعد الإغلاق';
  raise notice 'OK: 8 (Section 18) سجل تسوية الاسترداد محفوظ بعد الإغلاق';

  -- (9) get_sales_return() shows the event as reversed, Derived.
  assert (v_return -> 'refund_events' -> 0 ->> 'status') = 'reversed', '9 get_sales_return() يجب أن يعرض حالة الحدث reversed (مشتقة)';
  raise notice 'OK: 9 (Section 18) get_sales_return() يعرض الحدث كـreversed (مشتق من الملحق append-only)';

  -- (10) reference/method snapshot visible.
  assert (v_return -> 'refund_events' -> 0 ->> 'reference') = '18.1-REF-0001', '10/6.2 المرجع يجب أن يظهر في get_sales_return()';
  assert (v_return -> 'refund_events' -> 0 ->> 'refund_method_name_snapshot') is not null, '10/17.2 لقطة اسم طريقة الاسترداد يجب أن تظهر في get_sales_return()';
  raise notice 'OK: 10 (Section 18/Section 6/17) المرجع ولقطة اسم طريقة الاسترداد ظاهران في get_sales_return()';
end $$;

-- ============================================================================
-- Section 17 (extended) — refund_method_name_snapshot stays historically
-- accurate even after the payment method is later renamed.
-- ============================================================================
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_order_id uuid; v_item_id uuid; v_return_id uuid; v_row_version bigint;
  v_event_id uuid;
  v_return jsonb;
  v_snapshot_before text;
begin
  select id into v_store_id from public.stores where code = 'H421STA';
  select id into v_karat_id from public.karats where code = 'H421K1';
  select id into v_category_id from public.product_categories where code = 'h421cat';
  select id into v_channel_id from public.collection_channels where key = 'h421chan';
  select id into v_pm_id from public.payment_methods where key = 'h421pm';

  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 90.00)),
    'HF421-17'
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 90.00
  );
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_id, v_row_version);

  select id into v_event_id from public.record_sales_return_refund(v_return_id, 90.00, v_pm_id);

  v_return := public.get_sales_return(v_return_id);
  v_snapshot_before := v_return -> 'refund_events' -> 0 ->> 'refund_method_name_snapshot';
  assert v_snapshot_before = 'طريقة دفع اختبار Hotfix 4.2.1 (تناسبي)', format('17.1 اللقطة المبدئية غير متوقعة: %s', v_snapshot_before);

  -- Rename the payment method — a direct superuser write, simulating a
  -- future Master Data edit (payment_methods.manage), not a Returns RPC.
  reset role;
  update public.payment_methods set name_ar = 'اسم مُعاد تسميته لاحقًا' where id = v_pm_id;
  set role authenticated;
  set local request.jwt.claims = '{"sub":"de000000-0000-4000-8000-000000000001","role":"authenticated"}';

  v_return := public.get_sales_return(v_return_id);
  assert (v_return -> 'refund_events' -> 0 ->> 'refund_method_name_snapshot') = v_snapshot_before,
    format('17.2 اللقطة التاريخية يجب ألا تتأثر بإعادة تسمية طريقة الدفع لاحقًا، وجدت %s', v_return -> 'refund_events' -> 0 ->> 'refund_method_name_snapshot');
  assert (v_return -> 'refund_events' -> 0 ->> 'refund_method_name_snapshot') <> 'اسم مُعاد تسميته لاحقًا', '17.2 اللقطة يجب ألا تساوي الاسم الجديد';
  raise notice 'OK: 17 (Section 17) لقطة اسم طريقة الاسترداد التاريخية بقيت ثابتة رغم إعادة تسمية طريقة الدفع لاحقًا';
end $$;

-- ============================================================================
-- Section 20 — preview_sales_return() fee-basis parity with
-- approve_sales_return(): both must agree on the SAME approved-refund-basis
-- engine (never returned-item value).
-- ============================================================================
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_order_id uuid; v_item_1 uuid; v_return_id uuid; v_row_version bigint;
  v_items jsonb; v_preview jsonb; v_return jsonb;
begin
  select id into v_store_id from public.stores where code = 'H421STA';
  select id into v_karat_id from public.karats where code = 'H421K1';
  select id into v_category_id from public.product_categories where code = 'h421cat';
  select id into v_channel_id from public.collection_channels where key = 'h421chan';
  select id into v_pm_id from public.payment_methods where key = 'h421pm';

  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(
      jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 500.00),
      jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 500.00)
    ),
    'HF421-20'
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_1;
  v_items := jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_1));

  -- Preview with an explicit approved_refund_amount (400.00, after a 100.00
  -- deduction on a 500.00 item) — the SAME shape as Test A above. The old
  -- (v1-basis) preview would have estimated 50.00 (500/1000*100); the fixed
  -- preview must estimate 40.00, exactly matching what approval will
  -- actually compute.
  v_preview := public.preview_sales_return(
    v_order_id, v_items, p_scenario := 'other', p_collection_state := 'collected',
    p_non_shipping_deduction_amount := 100.00, p_deduction_reason := '20: خصم اختبار',
    p_approved_refund_amount := 400.00, p_refund_difference_reason := '20: فرق ناتج عن الاستقطاع'
  );
  assert v_preview ->> 'estimated_payment_fee_reversal_amount' = '40.00', format('20.1 معاينة استرداد العمولة يجب أن تكون 40.00 (أساس الاسترداد المعتمد)، وجدت %s', v_preview ->> 'estimated_payment_fee_reversal_amount');
  assert v_preview ->> 'payment_fee_reversal_calculation_version' = '2', '20.2 المعاينة يجب أن تعلن إصدار المحرك 2';

  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'other', v_items,
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 400.00,
    p_non_shipping_deduction_amount := 100.00, p_deduction_reason := '20: خصم اختبار',
    p_refund_difference_reason := '20: فرق ناتج عن الاستقطاع', p_scenario_notes := '20: سيناريو أخرى يتطلب ملاحظات'
  );
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_id, v_row_version);
  v_return := public.get_sales_return(v_return_id);
  assert v_return ->> 'payment_fee_reversal_amount' = v_preview ->> 'estimated_payment_fee_reversal_amount',
    format('20.3 استرداد العمولة الفعلي عند الاعتماد (%s) يجب أن يطابق تقدير المعاينة (%s) تمامًا', v_return ->> 'payment_fee_reversal_amount', v_preview ->> 'estimated_payment_fee_reversal_amount');
  raise notice 'OK: 20 (Section 20) preview_sales_return() يتطابق تمامًا مع approve_sales_return() على نفس أساس الاسترداد المعتمد (40.00 لكليهما)';
end $$;

reset role;

-- ============================================================================
-- Section 15 — a returns.create-ONLY actor (no sales.view at all) can run
-- the full New Return flow via search_sales_orders_for_return() +
-- get_returnable_sales_order() + create_sales_return(); list_sales_orders()
-- (the Sales module's own RPC) stays forbidden.
-- ============================================================================
do $$
declare
  v_store_id uuid;
  v_order_id uuid; v_order_number text; v_item_id uuid;
  v_search_results record;
  v_search_count int := 0;
  v_returnable jsonb;
  v_return_id uuid;
  v_list_sales_orders_failed boolean := false;
begin
  -- Build the Sale as the Manager actor (needs sales.create) first. v_store_
  -- id is captured here, in the OUTER block, so it survives the switch to
  -- the returns.create-only actor below — that actor lacks stores.view, so
  -- re-querying `stores` directly under its own claims would return NULL
  -- (RLS-blocked), not a permission error.
  set role authenticated;
  set local request.jwt.claims = '{"sub":"de000000-0000-4000-8000-000000000001","role":"authenticated"}';
  declare
    v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  begin
    select id into v_store_id from public.stores where code = 'H421STA';
    select id into v_karat_id from public.karats where code = 'H421K1';
    select id into v_category_id from public.product_categories where code = 'h421cat';
    select id into v_channel_id from public.collection_channels where key = 'h421chan';
    select id into v_pm_id from public.payment_methods where key = 'h421pm';

    select id, order_number into v_order_id, v_order_number from public.create_sales_order(
      v_store_id, public.business_today(), v_pm_id, v_channel_id,
      jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 60.00)),
      'HF421-15'
    );
    select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;
  end;

  -- Now switch to the returns.create-ONLY actor for the rest of this test.
  set local request.jwt.claims = '{"sub":"de000000-0000-4000-8000-000000000002","role":"authenticated"}';

  -- list_sales_orders() (Sales module's own RPC, requires sales.view) must
  -- stay forbidden — proving this actor genuinely has no Sales module access.
  begin
    perform public.list_sales_orders(p_order_number := v_order_number, p_limit := 10, p_offset := 0);
  exception when others then
    v_list_sales_orders_failed := true;
    assert sqlerrm like '%صلاحية%', format('15.1 رسالة رفض list_sales_orders() غير متوقعة: %s', sqlerrm);
  end;
  assert v_list_sales_orders_failed, '15.1 list_sales_orders() يجب أن يبقى ممنوعًا على مستخدم يملك returns.create فقط دون sales.view';
  raise notice 'OK: 15.1 (Section 15) list_sales_orders() (وحدة المبيعات نفسها) بقي ممنوعًا على المستخدم الذي يملك returns.create فقط';

  -- search_sales_orders_for_return() succeeds with returns.create alone.
  for v_search_results in select * from public.search_sales_orders_for_return(p_order_number := v_order_number, p_limit := 10)
  loop
    v_search_count := v_search_count + 1;
    assert v_search_results.id = v_order_id, '15.2 نتيجة البحث يجب أن تطابق عملية البيع المستهدفة';
  end loop;
  assert v_search_count = 1, format('15.2 search_sales_orders_for_return() يجب أن يجد عملية البيع بالضبط، وجد %s نتيجة', v_search_count);
  raise notice 'OK: 15.2 (Section 15) search_sales_orders_for_return() نجح لمستخدم يملك returns.create فقط — لا يعتمد على sales.view';

  -- get_returnable_sales_order() succeeds with returns.create alone.
  v_returnable := public.get_returnable_sales_order(v_order_id);
  assert v_returnable ->> 'order_number' = v_order_number, '15.3 get_returnable_sales_order() يجب أن ينجح ويعيد بيانات عملية البيع الصحيحة';
  raise notice 'OK: 15.3 (Section 15) get_returnable_sales_order() نجح لمستخدم يملك returns.create فقط — لم يعد sales.view شرطًا';

  -- create_sales_return() succeeds with returns.create alone (this RPC
  -- never required sales.view in the first place — proving the full flow
  -- end-to-end, not just the two previously-broken lookups).
  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (v_returnable ->> 'row_version')::bigint, 'collected', 60.00
  );
  assert v_return_id is not null, '15.4 create_sales_return() يجب أن ينجح لمستخدم يملك returns.create فقط، مكتملاً تدفق المرتجع الجديد بالكامل';
  raise notice 'OK: 15.4 (Section 15) تدفق المرتجع الجديد الكامل (بحث + تحميل بنود قابلة للإرجاع + إنشاء مرتجع Pending) نجح لمستخدم returns.create فقط، دون أي صلاحية sales.view';
end $$;

reset role;

do $$ begin
  raise notice 'ALL sales_returns_hotfix_4_2_1.test.sql ASSERTIONS PASSED (Sections 6/7/8/9/10/12/13/14/15/17/18/20)';
end $$;

rollback;
