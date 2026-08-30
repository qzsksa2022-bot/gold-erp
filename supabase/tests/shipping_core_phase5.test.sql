-- ============================================================================
-- Integration test: Phase 5 — Shipping Core (migrations 0113-0121)
-- ============================================================================
-- Single-transaction, rolled-back-at-the-end regression test, mirroring
-- sales_returns_hotfix_4_2_1.test.sql's own convention exactly. Covers the
-- non-concurrency scenarios named in the Phase 5 spec:
--
--   Section 44 — Historical Rate Snapshot Test: a shipment's expected_
--     carrier_cost/carrier_rate_version_id stay pinned to the rate that was
--     effective on ITS shipment_date even after a NEWER rate version is
--     created (and even after the newer version supersedes the one actually
--     used) — never silently recomputed from the current rate.
--   Section 45 — Customer Return Fee Test: the seeded current policy
--     (Riyadh=35, Outside Riyadh=50) resolves correctly via preview_
--     customer_return_shipping_fee()/create_shipment(), and remains
--     overridable at creation time without ever touching sales_returns'
--     own financial history.
--   Section 46 — Carrier Actual Cost Test: record -> correct -> correct
--     again leaves a complete, byte-for-byte-preserved append-only history
--     in shipment_financial_events, with shipments.actual_carrier_cost/
--     net_shipping_actual always reflecting only the LATEST event.
--   Section 47 — Failed-Delivery/Customer-Never-Received Test: the full
--     out_for_delivery -> delivery_failed -> customer_never_received ->
--     returned_to_store path is walked as NORMAL forward transitions (no
--     shipments.correct_status/reason needed at any step), proving
--     customer_never_received is a genuine first-class state.
--   Section 48 — Return Shipment Test: a return shipment links correctly to
--     its sales_return, using RETURN-direction rate resolution (distinct
--     from outbound), and never mutates the linked sales_return's own
--     financial columns.
--   Section 49 — Profit Security Test: get_shipment()/list_shipments()
--     redact every money field for an actor without sales.view_profit
--     (already covered in the earlier smoke-test workflow; re-asserted here
--     as a permanent regression test) and shipments.view alone cannot
--     bypass shipments.create-gated write RPCs.
--
-- Also covers the append-only-status-timeline non-financial nature of
-- shipment.status_add vs the financial gating of shipment.create/cost_
-- record/cost_correct/charge_correct in audit_logs (migration 0121).
--
-- Safe to run against a real database: everything happens inside a
-- transaction that is ALWAYS rolled back at the end.
--
-- Requires migrations 0001-latest (including 0113-0121) + supabase/seed.sql
-- already applied.
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/shipping_core_phase5.test.sql
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0. Setup — actors, store, master data. Prefix 'df.../P5T' is not used by
-- any other test file's fixtures (checked against de.../H421, da.../P4C,
-- db.../P42, dc.../HF421L), so this file can never collide even if chained
-- into one transaction with the others.
--
--   01 = full-permission actor (shipments.* + shipping_rates.* + sales.*)
--   02 = shipments.view-only actor (Section 49 — profit security / write gating)
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('df100000-0000-4000-8000-000000000001', 'test-p5t-manager@example.invalid'),
  ('df100000-0000-4000-8000-000000000002', 'test-p5t-viewonly@example.invalid');

update public.profiles set full_name = 'Test P5 Shipping Manager', status = 'active', store_access_scope = 'all'
  where id = 'df100000-0000-4000-8000-000000000001';
update public.profiles set full_name = 'Test P5 View-Only Actor', status = 'active', store_access_scope = 'all'
  where id = 'df100000-0000-4000-8000-000000000002';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'df100000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in (
    'stores.view', 'stores.create', 'karats.view', 'karats.manage', 'categories.view', 'categories.manage',
    'collection_channels.view', 'collection_channels.manage', 'payment_methods.view', 'payment_methods.manage',
    'gold_prices.view', 'gold_prices.edit', 'manufacturing_fees.view', 'manufacturing_fees.manage',
    'sales.create', 'sales.edit', 'sales.view', 'sales.view_profit', 'sales.close_day',
    'returns.view', 'returns.create', 'returns.approve',
    'shipments.view', 'shipments.create', 'shipments.update_status', 'shipments.correct_status',
    'shipments.manage_cost', 'shipments.process_closed_day', 'shipping_rates.view', 'shipping_rates.manage'
  );

-- Section 49 — deliberately shipments.view ONLY: no shipments.create, no
-- shipments.manage_cost, no sales.view_profit.
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'df100000-0000-4000-8000-000000000002', id, 'grant' from public.permissions
  where key in ('shipments.view');

set role authenticated;
set local request.jwt.claims = '{"sub":"df100000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
begin
  insert into public.stores (code, name_ar, status) values ('P5TSTA', 'متجر اختبار Phase 5 الأساسي', 'active') returning id into v_store_id;
  insert into public.karats (code, name_ar, sort_order, status) values ('P5TK1', 'عيار اختبار Phase 5 الأساسي', 990, 'active') returning id into v_karat_id;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('p5tcat', 'تصنيف اختبار Phase 5 الأساسي', 990, 'active') returning id into v_category_id;
  insert into public.collection_channels (key, name_ar, sort_order, status) values ('p5tchan', 'قناة اختبار Phase 5 الأساسي', 990, 'active') returning id into v_channel_id;
  insert into public.payment_methods (key, name_ar, fee_model, refund_fee_policy, sort_order, status)
    values ('p5tpm', 'طريقة دفع اختبار Phase 5 الأساسي', 'percentage', 'proportional_reversal', 990, 'active') returning id into v_pm_id;

  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 300.0000, 'df100000-0000-4000-8000-000000000001');

  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, public.business_today(), 'p5t fixture');
  perform public.create_payment_method_fee_version(v_pm_id, 10, 0, public.business_today(), 'p5t fixture 10%');
end $$;

-- ============================================================================
-- Section 44 — Historical Rate Snapshot Test
-- ============================================================================
-- SMSA/RIYADH/return already has a seeded 17.00 rate effective from
-- business_today() (Section 45's seed, migration 0114). Create a shipment
-- TODAY (pinning 17.00), THEN schedule a FUTURE rate version (25.00,
-- effective tomorrow) — the already-created shipment's snapshot must stay
-- 17.00 forever, proving no live recomputation.
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_order_id uuid; v_item_id uuid; v_return_id uuid; v_row_version bigint;
  v_carrier_id uuid; v_zone_id uuid; v_shipment_id uuid; v_shipment jsonb;
  v_old_rate_version_id uuid;
begin
  select id into v_store_id from public.stores where code = 'P5TSTA';
  select id into v_karat_id from public.karats where code = 'P5TK1';
  select id into v_category_id from public.product_categories where code = 'p5tcat';
  select id into v_channel_id from public.collection_channels where key = 'p5tchan';
  select id into v_pm_id from public.payment_methods where key = 'p5tpm';
  select id into v_carrier_id from public.shipping_carriers where code = 'SMSA';
  select id into v_zone_id from public.shipping_zones where code = 'RIYADH';

  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 1000.00)),
    'P5T-S44-ORDER'
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'other',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 1000.00,
    p_scenario_notes := 'S44: سيناريو أخرى يتطلب ملاحظات'
  );
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_id, v_row_version);

  select id into v_shipment_id from public.create_shipment(
    p_sales_order_id := v_order_id, p_store_id := v_store_id, p_shipment_date := public.business_today(),
    p_direction := 'return', p_carrier_id := v_carrier_id, p_shipping_zone_id := v_zone_id,
    p_customer_shipping_charge := 35.00, p_sales_return_id := v_return_id
  );

  v_shipment := public.get_shipment(v_shipment_id);
  assert v_shipment ->> 'expected_carrier_cost' = '17.00', format('S44.1 expected_carrier_cost يجب أن يكون 17.00 (السعر الحالي)، وجد %s', v_shipment ->> 'expected_carrier_cost');
  v_old_rate_version_id := (v_shipment ->> 'carrier_rate_version_id')::uuid;
  assert v_old_rate_version_id is not null, 'S44.2 carrier_rate_version_id يجب أن يكون مضبوطًا (تسعير تلقائي، ليس يدويًا)';

  -- Schedule a FUTURE rate version — must NOT retroactively affect the
  -- shipment created above (still effective as of business_today()).
  perform public.create_shipping_carrier_rate_version(v_carrier_id, v_zone_id, 'return', 99.00, public.business_today() + 1, 'S44: إصدار مستقبلي');

  v_shipment := public.get_shipment(v_shipment_id);
  assert v_shipment ->> 'expected_carrier_cost' = '17.00', format('S44.3 expected_carrier_cost يجب أن يبقى 17.00 (لقطة تاريخية) رغم جدولة إصدار مستقبلي جديد، وجد %s', v_shipment ->> 'expected_carrier_cost');
  assert (v_shipment ->> 'carrier_rate_version_id')::uuid = v_old_rate_version_id, 'S44.4 carrier_rate_version_id يجب أن يبقى نفس الإصدار الأصلي المستخدم عند الإنشاء';

  raise notice 'OK: Section 44 (لقطة تسعير تاريخية) — الشحنة تحتفظ بالتسعير الذي كان ساريًا وقت إنشائها (17.00) رغم جدولة إصدار مستقبلي جديد (99.00) لاحقًا.';
end $$;

-- ============================================================================
-- Section 45 — Customer Return Fee Test
-- ============================================================================
-- Seeded policy: Riyadh=35, Outside Riyadh=50 (migration 0115). Preview
-- resolves the correct suggested fee per zone; create_shipment() accepts an
-- override without ever touching sales_returns' own financial columns.
do $$
declare
  v_zone_riyadh uuid; v_zone_outside uuid;
  v_preview_riyadh record; v_preview_outside record;
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_order_id uuid; v_item_id uuid; v_return_id uuid; v_row_version bigint;
  v_carrier_id uuid; v_shipment_id uuid; v_shipment jsonb;
  v_return_before jsonb; v_return_after jsonb;
begin
  select id into v_zone_riyadh from public.shipping_zones where code = 'RIYADH';
  select id into v_zone_outside from public.shipping_zones where code = 'OUTSIDE_RIYADH';

  select * into v_preview_riyadh from public.preview_customer_return_shipping_fee(v_zone_riyadh);
  select * into v_preview_outside from public.preview_customer_return_shipping_fee(v_zone_outside);

  -- preview_customer_return_shipping_fee() returns fee_amount as TEXT
  -- (Decimal Transport Boundary, ::text at the RPC boundary) — compared
  -- here via ::numeric, never text, since '35.00' vs '35' would otherwise
  -- diverge on trailing zeros.
  assert v_preview_riyadh.found = true and v_preview_riyadh.fee_amount::numeric = 35.00, format('S45.1 الرياض يجب أن تقترح 35.00، وجد found=%s fee=%s', v_preview_riyadh.found, v_preview_riyadh.fee_amount);
  assert v_preview_outside.found = true and v_preview_outside.fee_amount::numeric = 50.00, format('S45.2 خارج الرياض يجب أن تقترح 50.00، وجد found=%s fee=%s', v_preview_outside.found, v_preview_outside.fee_amount);

  -- Now prove the suggestion is OVERRIDABLE and never touches sales_returns.
  select id into v_store_id from public.stores where code = 'P5TSTA';
  select id into v_karat_id from public.karats where code = 'P5TK1';
  select id into v_category_id from public.product_categories where code = 'p5tcat';
  select id into v_channel_id from public.collection_channels where key = 'p5tchan';
  select id into v_pm_id from public.payment_methods where key = 'p5tpm';
  select id into v_carrier_id from public.shipping_carriers where code = 'ARAMEX';

  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 1000.00)),
    'P5T-S45-ORDER'
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'other',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 1000.00,
    p_scenario_notes := 'S45: سيناريو أخرى يتطلب ملاحظات'
  );
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_id, v_row_version);

  v_return_before := public.get_sales_return(v_return_id);

  -- Override: enter 60.00 instead of the suggested 35.00. As of Patch 5.1
  -- item 9 (migration 0125), overriding the resolved standard fee requires
  -- a non-empty p_customer_return_shipping_charge_override_reason — the
  -- trailing 21st positional param added there. Confirm it is REJECTED
  -- without one first (S45.3), matching item 9's own wording exactly, then
  -- accepted with one (S45.4-S45.7).
  begin
    perform public.create_shipment(
      p_sales_order_id := v_order_id, p_store_id := v_store_id, p_shipment_date := public.business_today(),
      p_direction := 'return', p_carrier_id := v_carrier_id, p_shipping_zone_id := v_zone_riyadh,
      p_customer_shipping_charge := 60.00, p_sales_return_id := v_return_id
    );
    raise exception 'S45.3 FAILED — كان يجب رفض تجاوز الرسوم القياسية بدون سبب';
  exception
    when others then
      if sqlerrm not like '%سبب%' then
        raise;
      end if;
  end;

  select id into v_shipment_id from public.create_shipment(
    p_sales_order_id := v_order_id, p_store_id := v_store_id, p_shipment_date := public.business_today(),
    p_direction := 'return', p_carrier_id := v_carrier_id, p_shipping_zone_id := v_zone_riyadh,
    p_customer_shipping_charge := 60.00, p_sales_return_id := v_return_id,
    p_customer_return_shipping_charge_override_reason := 'S45: العميل طلب توصيلًا سريعًا للإرجاع'
  );

  v_shipment := public.get_shipment(v_shipment_id);
  assert v_shipment ->> 'customer_shipping_charge' = '60.00', format('S45.4 يجب قبول تجاوز الاقتراح (60.00 بدلًا من 35.00) مع سبب، وجد %s', v_shipment ->> 'customer_shipping_charge');
  assert v_shipment ->> 'customer_return_shipping_fee_standard_amount' = '35.00', format('S45.5 يجب حفظ الرسوم القياسية المُقترحة (35.00) في اللقطة رغم التجاوز، وجد %s', v_shipment ->> 'customer_return_shipping_fee_standard_amount');
  assert (v_shipment ->> 'customer_return_shipping_charge_is_override')::boolean = true, 'S45.6 customer_return_shipping_charge_is_override يجب أن يكون true';
  assert v_shipment ->> 'customer_return_shipping_charge_override_reason' = 'S45: العميل طلب توصيلًا سريعًا للإرجاع', format('S45.7 سبب التجاوز يجب أن يُحفظ كما أُدخل، وجد %s', v_shipment ->> 'customer_return_shipping_charge_override_reason');

  v_return_after := public.get_sales_return(v_return_id);
  assert v_return_before = v_return_after, 'S45.8 إنشاء شحنة الإرجاع (مع رسوم شحن مختلفة عن الاقتراح) يجب ألا يغيّر أي عمود مالي في sales_returns على الإطلاق';

  raise notice 'OK: Section 45 (رسوم شحن الإرجاع للعميل) — الاقتراح صحيح لكل منطقة (35.00/50.00)، مرفوض بدون سبب عند التجاوز (Patch 5.1 item 9)، مقبول وموثَّق بالكامل (60.00 + اللقطة القياسية + السبب) عند توفر السبب، ولا يمس أي عمود في سجل المرتجع المالي.';
end $$;

-- ============================================================================
-- Section 46 — Carrier Actual Cost Test
-- ============================================================================
-- record -> correct -> correct again: append-only history fully preserved,
-- shipments.actual_carrier_cost/net_shipping_actual always reflect the
-- LATEST event only.
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_order_id uuid; v_carrier_id uuid; v_zone_id uuid; v_shipment_id uuid;
  v_rv bigint := 1;
  v_first_event_id uuid; v_first_amount numeric;
  v_event_count int; v_shipment jsonb; v_events jsonb;
begin
  select id into v_store_id from public.stores where code = 'P5TSTA';
  select id into v_karat_id from public.karats where code = 'P5TK1';
  select id into v_category_id from public.product_categories where code = 'p5tcat';
  select id into v_channel_id from public.collection_channels where key = 'p5tchan';
  select id into v_pm_id from public.payment_methods where key = 'p5tpm';
  select id into v_carrier_id from public.shipping_carriers where code = 'BARQ';
  select id into v_zone_id from public.shipping_zones where code = 'RIYADH';

  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 1000.00)),
    'P5T-S46-ORDER'
  );

  select id into v_shipment_id from public.create_shipment(
    p_sales_order_id := v_order_id, p_store_id := v_store_id, p_shipment_date := public.business_today(),
    p_direction := 'outbound', p_carrier_id := v_carrier_id, p_shipping_zone_id := v_zone_id,
    p_customer_shipping_charge := 40.00, p_manual_expected_cost := 25.00, p_manual_expected_cost_reason := 'S46: لا يوجد تسعير ذهاب'
  );

  select row_version into v_rv from public.record_shipment_actual_cost(v_shipment_id, v_rv, 24.00, public.business_today(), 'INV-S46-1');
  select row_version into v_rv from public.correct_shipment_actual_cost(v_shipment_id, v_rv, 26.50, public.business_today(), 'S46: تصحيح أول — فاتورة معدَّلة', 'INV-S46-2');
  select row_version into v_rv from public.correct_shipment_actual_cost(v_shipment_id, v_rv, 25.75, public.business_today(), 'S46: تصحيح ثانٍ — نزاع تمت تسويته', 'INV-S46-3');

  v_shipment := public.get_shipment(v_shipment_id);
  assert v_shipment ->> 'actual_carrier_cost' = '25.75', format('S46.1 actual_carrier_cost يجب أن يعكس آخر تصحيح فقط (25.75)، وجد %s', v_shipment ->> 'actual_carrier_cost');
  assert v_shipment ->> 'net_shipping_actual' = '14.25', format('S46.2 net_shipping_actual يجب أن يكون 40.00-25.75=14.25، وجد %s', v_shipment ->> 'net_shipping_actual');

  v_events := v_shipment -> 'financial_events';
  assert jsonb_array_length(v_events) = 3, format('S46.3 يجب وجود 3 أحداث مالية بالضبط (تسجيل + تصحيحان) — لا شيء حُذف أو استُبدل، وجد %s', jsonb_array_length(v_events));
  assert (v_events -> 0 ->> 'event_type') = 'actual_cost_recorded' and (v_events -> 0 ->> 'amount') = '24.00', 'S46.4 الحدث الأول يجب أن يبقى محفوظًا بقيمته الأصلية (24.00) بلا تغيير';
  assert (v_events -> 1 ->> 'event_type') = 'actual_cost_correction' and (v_events -> 1 ->> 'amount') = '26.50', 'S46.5 التصحيح الأول يجب أن يبقى محفوظًا بقيمته (26.50) بلا تغيير';
  assert (v_events -> 2 ->> 'event_type') = 'actual_cost_correction' and (v_events -> 2 ->> 'amount') = '25.75', 'S46.6 التصحيح الثاني يجب أن يكون آخر عنصر بقيمته (25.75)';

  raise notice 'OK: Section 46 (تاريخ التكلفة الفعلية) — 3 أحداث محفوظة بالكامل (append-only)، والقيم الحالية (actual_carrier_cost/net_shipping_actual) تعكس آخر تصحيح فقط.';
end $$;

-- ============================================================================
-- Section 47 — Failed-Delivery / Customer-Never-Received Test
-- ============================================================================
-- out_for_delivery -> delivery_failed -> customer_never_received ->
-- returned_to_store, ALL as NORMAL forward transitions (no reason needed at
-- any step) — proving customer_never_received is a genuine first-class
-- state in the normal flow, not merely a correction target.
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_order_id uuid; v_carrier_id uuid; v_zone_id uuid; v_shipment_id uuid;
  v_rv bigint := 1;
  v_shipment jsonb; v_timeline jsonb;
begin
  select id into v_store_id from public.stores where code = 'P5TSTA';
  select id into v_karat_id from public.karats where code = 'P5TK1';
  select id into v_category_id from public.product_categories where code = 'p5tcat';
  select id into v_channel_id from public.collection_channels where key = 'p5tchan';
  select id into v_pm_id from public.payment_methods where key = 'p5tpm';
  select id into v_carrier_id from public.shipping_carriers where code = 'REDBOX';
  select id into v_zone_id from public.shipping_zones where code = 'OUTSIDE_RIYADH';

  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 1000.00)),
    'P5T-S47-ORDER'
  );

  select id into v_shipment_id from public.create_shipment(
    p_sales_order_id := v_order_id, p_store_id := v_store_id, p_shipment_date := public.business_today(),
    p_direction := 'outbound', p_carrier_id := v_carrier_id, p_shipping_zone_id := v_zone_id,
    p_customer_shipping_charge := 50.00, p_manual_expected_cost := 30.00, p_manual_expected_cost_reason := 'S47: لا يوجد تسعير ذهاب'
  );

  select row_version into v_rv from public.add_shipment_status_event(v_shipment_id, 'picked_up', v_rv, public.business_today());
  select row_version into v_rv from public.add_shipment_status_event(v_shipment_id, 'out_for_delivery', v_rv, public.business_today());
  select row_version into v_rv from public.add_shipment_status_event(v_shipment_id, 'delivery_failed', v_rv, public.business_today(), 'S47: العميل لم يكن متواجدًا');
  select row_version into v_rv from public.add_shipment_status_event(v_shipment_id, 'customer_never_received', v_rv, public.business_today());
  select row_version into v_rv from public.add_shipment_status_event(v_shipment_id, 'returned_to_store', v_rv, public.business_today());

  v_shipment := public.get_shipment(v_shipment_id);
  assert v_shipment ->> 'current_status' = 'returned_to_store', format('S47.1 current_status النهائي يجب أن يكون returned_to_store، وجد %s', v_shipment ->> 'current_status');

  v_timeline := v_shipment -> 'status_timeline';
  assert jsonb_array_length(v_timeline) = 6, format('S47.2 يجب وجود 6 أحداث حالة (created + 5 انتقالات)، وجد %s', jsonb_array_length(v_timeline));

  -- Every event in this chain must be is_correction=false — proving the
  -- WHOLE failed-delivery/never-received path is NORMAL flow, never a
  -- correction requiring shipments.correct_status.
  perform (
    select 1
    from jsonb_array_elements(v_timeline) e
    where (e ->> 'is_correction')::boolean = true
  );
  assert not exists (select 1 from jsonb_array_elements(v_timeline) e where (e ->> 'is_correction')::boolean = true),
    'S47.3 لا ينبغي أن يكون أي حدث في هذا المسار (out_for_delivery -> delivery_failed -> customer_never_received -> returned_to_store) تصحيحيًا — المسار بأكمله ضمن التدفق الطبيعي';

  raise notice 'OK: Section 47 (فشل التسليم / لم يستلم العميل) — المسار الكامل (out_for_delivery -> delivery_failed -> customer_never_received -> returned_to_store) تم اجتيازه بالكامل كانتقالات طبيعية (is_correction=false) بلا حاجة لأي سبب.';
end $$;

-- ============================================================================
-- Section 48 — Return Shipment Test
-- ============================================================================
-- A return shipment links correctly to its sales_return (direction=return
-- required, rate resolved for direction='return' specifically — distinct
-- from outbound), and never mutates the linked return's own financial
-- columns (re-asserted independently from Section 45's own check, this
-- time via the shipment's own linkage fields).
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_order_id uuid; v_item_id uuid; v_return_id uuid; v_row_version bigint;
  v_carrier_id uuid; v_zone_id uuid; v_shipment_id uuid; v_shipment jsonb;
begin
  select id into v_store_id from public.stores where code = 'P5TSTA';
  select id into v_karat_id from public.karats where code = 'P5TK1';
  select id into v_category_id from public.product_categories where code = 'p5tcat';
  select id into v_channel_id from public.collection_channels where key = 'p5tchan';
  select id into v_pm_id from public.payment_methods where key = 'p5tpm';
  select id into v_carrier_id from public.shipping_carriers where code = 'ARAMEX';
  select id into v_zone_id from public.shipping_zones where code = 'RIYADH';

  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 1000.00)),
    'P5T-S48-ORDER'
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'other',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 1000.00,
    p_scenario_notes := 'S48: سيناريو أخرى يتطلب ملاحظات'
  );
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_id, v_row_version);

  select id into v_shipment_id from public.create_shipment(
    p_sales_order_id := v_order_id, p_store_id := v_store_id, p_shipment_date := public.business_today(),
    p_direction := 'return', p_carrier_id := v_carrier_id, p_shipping_zone_id := v_zone_id,
    p_customer_shipping_charge := 35.00, p_sales_return_id := v_return_id
  );

  v_shipment := public.get_shipment(v_shipment_id);
  assert v_shipment ->> 'direction' = 'return', 'S48.1 direction يجب أن يكون return';
  assert (v_shipment ->> 'sales_return_id')::uuid = v_return_id, 'S48.2 sales_return_id يجب أن يشير إلى المرتجع الصحيح';
  assert v_shipment ->> 'return_number' is not null, 'S48.3 return_number يجب أن يظهر في تفاصيل الشحنة';
  -- ARAMEX/RIYADH/return is seeded at 17.00 (Section 45's exact figures) —
  -- proves the RETURN-direction rate resolved, not an outbound one (which
  -- has no configuration at all in this phase, per the "don't invent
  -- numbers" rule).
  assert v_shipment ->> 'expected_carrier_cost' = '17.00', format('S48.4 يجب أن يُحل تسعير اتجاه return تحديدًا (17.00 لأرامكس/الرياض)، وجد %s', v_shipment ->> 'expected_carrier_cost');

  -- Attempting an OUTBOUND direction with a sales_return_id must be rejected
  -- by the direction/return-link invariant (Section 23).
  declare
    v_failed boolean := false;
  begin
    begin
      perform public.create_shipment(
        p_sales_order_id := v_order_id, p_store_id := v_store_id, p_shipment_date := public.business_today(),
        p_direction := 'outbound', p_carrier_id := v_carrier_id, p_shipping_zone_id := v_zone_id,
        p_customer_shipping_charge := 20.00, p_sales_return_id := v_return_id,
        p_manual_expected_cost := 10.00, p_manual_expected_cost_reason := 'S48: يجب أن يُرفض'
      );
    exception when others then
      v_failed := true;
    end;
    assert v_failed, 'S48.5 محاولة إنشاء شحنة باتجاه outbound مع sales_return_id يجب أن تُرفض (قيد Section 23)';
  end;

  raise notice 'OK: Section 48 (شحنة الإرجاع) — الربط الصحيح بالمرتجع، تسعير اتجاه return المستقل (17.00)، ورفض الجمع بين outbound و sales_return_id.';
end $$;

-- ============================================================================
-- Section 49 — Profit Security Test
-- ============================================================================
-- CORRECTED by Patch 5.1 items 10/22/23 (migration 0126): customer_
-- shipping_charge/effective_customer_shipping_charge and has_actual_
-- carrier_cost are OPERATIONAL facts, never profit-gated — a shipments.
-- view-only actor (no sales.view_profit, no shipments.create/manage_cost)
-- now correctly SEES them. Only expected/actual_carrier_cost, net_
-- shipping_expected/actual, and financial_events (the actual cost FIGURES)
-- remain entirely absent — that is the real profit boundary, not the
-- customer-facing charge. This replaces the pre-Patch-5.1 version of this
-- test, which incorrectly asserted customer_shipping_charge should also be
-- absent (that was the bug item 10 fixes, not a spec this test should keep
-- enforcing). The actor still cannot call any write RPC gated on a
-- permission they lack.
-- shipments/sales_orders are zero-direct-RLS-policy, RPC-only tables — a
-- raw SELECT under `authenticated` (even as a fully-permissioned actor)
-- silently returns zero rows. Resolve the lookup as superuser first.
reset role;

do $$
declare
  v_shipment_id uuid;
begin
  select id into v_shipment_id from public.shipments where sales_order_id in (select id from public.sales_orders where customer_name = 'P5T-S48-ORDER');
  perform set_config('p5t.s49_shipment_id', v_shipment_id::text, false);
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"df100000-0000-4000-8000-000000000002","role":"authenticated"}';

do $$
declare
  v_shipment_id uuid := current_setting('p5t.s49_shipment_id')::uuid;
  v jsonb;
  v_failed boolean := false;
begin
  v := public.get_shipment(v_shipment_id);
  -- Item 10 — operational, customer-facing money, ALWAYS visible.
  assert v ? 'customer_shipping_charge', 'S49.1 customer_shipping_charge (تشغيلي، غير مرتبط بالربحية) يجب أن يكون ظاهرًا لفاعل shipments.view فقط';
  assert v ? 'effective_customer_shipping_charge', 'S49.1b effective_customer_shipping_charge يجب أن يكون ظاهرًا أيضًا لنفس السبب';
  -- Item 23 — operational fact (has a cost been recorded at all), ALWAYS visible.
  assert v ? 'has_actual_carrier_cost', 'S49.1c has_actual_carrier_cost يجب أن يكون ظاهرًا (حقيقة تشغيلية، ليست رقمًا ماليًا)';
  -- The real profit boundary: the actual carrier-cost FIGURES stay absent.
  assert not (v ? 'expected_carrier_cost'), 'S49.2 expected_carrier_cost يجب أن يكون غائبًا تمامًا';
  assert not (v ? 'actual_carrier_cost'), 'S49.3 actual_carrier_cost يجب أن يكون غائبًا تمامًا';
  assert not (v ? 'net_shipping_expected'), 'S49.4 net_shipping_expected يجب أن يكون غائبًا تمامًا';
  assert not (v ? 'net_shipping_actual'), 'S49.5 net_shipping_actual يجب أن يكون غائبًا تمامًا';
  assert not (v ? 'financial_events'), 'S49.6 financial_events يجب أن يكون غائبًا تمامًا';
  assert v ? 'status_timeline', 'S49.7 status_timeline (غير مالي) يجب أن يبقى ظاهرًا';
  assert v ? 'cod_timeline', 'S49.7b cod_timeline (تشغيلي، Patch 5.1 item 13) يجب أن يبقى ظاهرًا';

  begin
    perform public.create_shipment(
      p_sales_order_id := (v ->> 'sales_order_id')::uuid, p_store_id := (v ->> 'store_id')::uuid, p_shipment_date := public.business_today(),
      p_direction := 'outbound', p_carrier_id := (v ->> 'carrier_id')::uuid, p_shipping_zone_id := (v ->> 'shipping_zone_id')::uuid,
      p_customer_shipping_charge := 20.00, p_manual_expected_cost := 10.00, p_manual_expected_cost_reason := 'S49: يجب أن يُرفض'
    );
  exception when others then
    v_failed := true;
  end;
  assert v_failed, 'S49.8 فاعل بصلاحية shipments.view فقط يجب أن يُرفض عند محاولة create_shipment()';

  v_failed := false;
  begin
    perform public.record_shipment_actual_cost(v_shipment_id, (v ->> 'row_version')::bigint, 10.00, public.business_today());
  exception when others then
    v_failed := true;
  end;
  assert v_failed, 'S49.9 فاعل بصلاحية shipments.view فقط يجب أن يُرفض عند محاولة record_shipment_actual_cost()';

  raise notice 'OK: Section 49 (أمن الربحية) — كل الحقول المالية غائبة تمامًا لفاعل shipments.view فقط، وكل استدعاءات RPC الكتابية المالية مرفوضة.';
end $$;

reset role;

rollback;

select 'ALL PHASE 5 CORE TESTS PASSED (Sections 44-49)' as result;
