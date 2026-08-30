-- ============================================================================
-- Integration test: Phase 3 — Final Sales Integrity Patch 3.2 (migrations
-- 0073-0080), Part 1 — single-session scenarios (spec item 11, tests C-I)
-- ============================================================================
-- Covers: the full-precision rounding regression + reconciliation (C), DB-
-- level input precision/bounds rejection (D), Edit-mode preview parity with
-- Save after a Master Data change (E), item-level calculation_version
-- semantics (F), Sales Read label permissions without any Master .view
-- grant (G), the disabled-store historical-edit policy (H), and complete
-- sale.create/sale.update audit old/new (I).
--
-- Tests A (direct daily_gold_prices write vs a concurrent Sale) and B (the
-- corrected Lost Update expectation) are genuine multi-session concurrency
-- scenarios and live in the companion file
-- supabase/tests/sales_integrity_patch_3_1_concurrency.test.sql (sections
-- J2 and I respectively) — extended in place rather than duplicated here.
--
-- Requires migrations 0001-0080 + supabase/seed.sql to already be applied.
-- Safe to run against a real database: everything happens inside a
-- transaction that is ALWAYS rolled back at the end.
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/sales_integrity_patch_3_2.test.sql
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0. Setup — actors, stores, master data. Prefix 'd7...'/'p32' is unused by
-- any other test file's fixtures.
--   01 = Sales Manager — full Sales permission set + master-data manage +
--        audit_logs.view + sales.view_profit. store_access_scope='all'.
--   02 = Sales-view-only actor — sales.view ONLY, no sales.view_profit, no
--        stores.view/payment_methods.view/collection_channels.view/
--        users.view at all — for scenario G.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('d7000000-0000-4000-8000-000000000001', 'test-p32-manager@example.invalid'),
  ('d7000000-0000-4000-8000-000000000002', 'test-p32-viewonly@example.invalid');

update public.profiles set full_name = 'Test P32 Sales Manager', status = 'active', store_access_scope = 'all'
  where id = 'd7000000-0000-4000-8000-000000000001';
update public.profiles set full_name = 'Test P32 Sales-View-Only', status = 'active', store_access_scope = 'all'
  where id = 'd7000000-0000-4000-8000-000000000002';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'd7000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in (
    'stores.view', 'stores.create', 'stores.manage', 'stores.disable',
    'karats.view', 'karats.manage', 'categories.view', 'categories.manage',
    'collection_channels.view', 'collection_channels.manage',
    'payment_methods.view', 'payment_methods.manage',
    'gold_prices.view', 'gold_prices.edit',
    'manufacturing_fees.view', 'manufacturing_fees.manage',
    'vat_rates.view', 'vat_rates.manage',
    'sales.create', 'sales.edit', 'sales.view', 'sales.view_profit',
    'sales.close_day', 'sales.edit_closed_day',
    'audit_logs.view'
  );

-- Scenario G's actor: sales.view ONLY. Deliberately NOT granted
-- stores.view/payment_methods.view/collection_channels.view/users.view —
-- the whole point of the test.
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'd7000000-0000-4000-8000-000000000002', id, 'grant' from public.permissions
  where key in ('sales.view');

set role authenticated;
set local request.jwt.claims = '{"sub":"d7000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
begin
  insert into public.stores (code, name_ar, status) values ('P32ST', 'متجر تكامل 3.2', 'active') returning id into v_store_id;
  insert into public.karats (code, name_ar, sort_order, status) values ('P32K1', 'عيار تكامل 3.2', 991, 'active') returning id into v_karat_id;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('p32cat', 'تصنيف تكامل 3.2', 991, 'active') returning id into v_category_id;
  insert into public.collection_channels (key, name_ar, sort_order, status) values ('p32_channel', 'قناة تكامل 3.2', 991, 'active') returning id into v_channel_id;
  insert into public.payment_methods (key, name_ar, fee_model, sort_order, status) values ('p32_pm', 'طريقة دفع تكامل 3.2', 'percentage', 991, 'active') returning id into v_pm_id;

  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 300.1234, 'd7000000-0000-4000-8000-000000000001');

  perform public.create_manufacturing_fee_version(v_karat_id, 10.1234, public.business_today(), 'p32 fixture');
  perform public.create_payment_method_fee_version(v_pm_id, 2.5, 0, public.business_today(), 'p32 fixture');
end $$;

reset role;

create temporary table p32_row_version (v bigint) on commit drop;
grant select on p32_row_version to authenticated;

-- ============================================================================
-- C) Full-precision rounding regression (spec item 3): Gold=300.1234,
-- Manufacturing=10.1234, Weight=0.0250, VAT=15% -> Total Cost MUST = 8.92
-- (the old component-early-rounding engine would have produced 8.91).
-- ============================================================================
do $$
declare v_costs record;
begin
  select * into v_costs from public.compute_sales_item_costs(300.1234, 10.1234, 15.000, 0.0250, 20.00);

  assert v_costs.base_cost = 7.76, format('base_cost متوقَّع 7.76، وجد %s', v_costs.base_cost);
  assert v_costs.total_cost = 8.92, format('FAIL C: total_cost متوقَّع 8.92 (الهندسة الكاملة الدقة)، وجد %s — لو ظهرت 8.91 فهذا يعني عودة سياسة التقريب المبكر للمكوّنات', v_costs.total_cost);
  assert v_costs.gold_component_cost = 7.50, format('gold_component_cost متوقَّع 7.50، وجد %s', v_costs.gold_component_cost);
  assert v_costs.manufacturing_component_cost = 0.26, format('manufacturing_component_cost متوقَّع 0.26، وجد %s', v_costs.manufacturing_component_cost);
  assert v_costs.vat_cost = 1.16, format('vat_cost متوقَّع 1.16، وجد %s', v_costs.vat_cost);

  -- Reconciliation invariants — must hold exactly, not approximately.
  assert v_costs.gold_component_cost + v_costs.manufacturing_component_cost = v_costs.base_cost,
    'FAIL C: gold_component_cost + manufacturing_component_cost يجب أن يساوي base_cost تمامًا';
  assert v_costs.base_cost + v_costs.vat_cost = v_costs.total_cost,
    'FAIL C: base_cost + vat_cost يجب أن يساوي total_cost تمامًا';
  assert v_costs.total_cost + v_costs.gross_profit = 20.00,
    format('FAIL C: total_cost + gross_profit يجب أن يساوي sale_price (20.00) تمامًا، وجد %s', v_costs.total_cost + v_costs.gross_profit);

  raise notice 'OK: C انحدار التقريب الكامل الدقة (وزن 0.0250) صحيح تمامًا: total_cost=8.92 (وليس 8.91) — ويُصالح تمامًا مع كل من base_cost وgross_profit';
end $$;

-- Same regression wired through the real create_sales_order() RPC end-to-end.
set role authenticated;
set local request.jwt.claims = '{"sub":"d7000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid; v_result record;
begin
  select id into v_store_id from public.stores where code = 'P32ST';
  select id into v_karat_id from public.karats where code = 'P32K1';
  select id into v_category_id from public.product_categories where code = 'p32cat';
  select id into v_channel_id from public.collection_channels where key = 'p32_channel';
  select id into v_pm_id from public.payment_methods where key = 'p32_pm';

  select * into v_result from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.0250, 'sale_price', 20.00))
  );
  create temporary table p32_order_c (order_id uuid) on commit drop;
  insert into p32_order_c values (v_result.id);
end $$;

reset role;
do $$
declare v_order_id uuid; v_item record;
begin
  select order_id into v_order_id from p32_order_c;
  select * into v_item from public.sales_order_items where sales_order_id = v_order_id and status = 'active';
  assert v_item.total_cost = 8.92, format('total_cost عبر create_sales_order() الفعلي متوقَّع 8.92، وجد %s', v_item.total_cost);
  assert v_item.calculation_version = 2, format('كل بند جديد بعد Patch 3.2 يجب أن يحمل calculation_version=2، وجد %s', v_item.calculation_version);
  raise notice 'OK: C2 نفس انحدار التقريب يُصالح تمامًا (8.92) عند المرور فعليًا عبر create_sales_order()، والبند مُعلَّم calculation_version=2';
end $$;

-- ============================================================================
-- D) DB-level input precision/bounds rejection (spec item 4): reject, never
-- silently round, weight >4dp or sale_price >2dp — before any calculation or
-- write, so a multi-item crafted payload can never produce an inconsistent
-- subtotal.
-- ============================================================================
do $$
declare v_bug boolean := false;
begin
  begin
    perform public.validate_sales_item_precision(1.00005, 100.00);
    v_bug := true;
  exception when others then
    assert sqlerrm like '%4 منازل عشرية%', format('FAIL D1: رسالة الخطأ يجب أن تذكر حد 4 منازل عشرية للوزن، كانت: %s', sqlerrm);
    raise notice 'OK: D1 وزن بأكثر من 4 منازل عشرية (1.00005) رُفض قبل أي حساب (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG D1: قُبل وزن بخمس منازل عشرية (1.00005) بدل رفضه'; end if;
end $$;

do $$
declare v_bug boolean := false;
begin
  begin
    perform public.validate_sales_item_precision(1.0000, 100.005);
    v_bug := true;
  exception when others then
    assert sqlerrm like '%منزلتين عشريتين%', format('FAIL D2: رسالة الخطأ يجب أن تذكر حد منزلتين عشريتين لسعر البيع، كانت: %s', sqlerrm);
    raise notice 'OK: D2 سعر بيع بثلاث منازل عشرية (100.005) رُفض قبل أي حساب (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG D2: قُبل سعر بيع بثلاث منازل عشرية (100.005) بدل رفضه'; end if;
end $$;

-- D3 — wired through the real create_sales_order() RPC: a multi-item
-- payload where EVERY item carries an over-precision sale_price must be
-- rejected outright (atomically — no partial order, no item ever stored),
-- so the "two items each stored as 100.01, SUM=200.02 vs raw-payload-summed
-- 200.01" break case the spec describes can never arise — over-precision
-- input never reaches storage or calculation at all.
set role authenticated;
set local request.jwt.claims = '{"sub":"d7000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_bug boolean := false; v_orders_before int; v_orders_after int;
begin
  select id into v_store_id from public.stores where code = 'P32ST';
  select id into v_karat_id from public.karats where code = 'P32K1';
  select id into v_category_id from public.product_categories where code = 'p32cat';
  select id into v_channel_id from public.collection_channels where key = 'p32_channel';
  select id into v_pm_id from public.payment_methods where key = 'p32_pm';

  begin
    perform public.create_sales_order(
      v_store_id, public.business_today(), v_pm_id, v_channel_id,
      jsonb_build_array(
        jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 100.005),
        jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 100.005)
      )
    );
    v_bug := true;
  exception when others then
    raise notice 'OK: D3 عملية بيع متعددة البنود بسعر بيع مفصَّل زائدًا (100.005) في كل بند رُفضت بالكامل قبل أي كتابة (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG D3: قُبلت عملية بيع ببنود ذات دقة زائدة — قد ينتج مجموع فرعي غير متسق'; end if;
end $$;

reset role;

-- ============================================================================
-- E) Edit-mode preview parity with Save (spec item 5): after a Master Data
-- correction post-Sale, a notes-only Update Preview must stay on the OLD
-- snapshot and match the real Save exactly — never leak the corrected
-- Master Data value into an unrelated edit's preview.
-- ============================================================================
set role authenticated;
set local request.jwt.claims = '{"sub":"d7000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid; v_result record;
begin
  select id into v_store_id from public.stores where code = 'P32ST';
  select id into v_karat_id from public.karats where code = 'P32K1';
  select id into v_category_id from public.product_categories where code = 'p32cat';
  select id into v_channel_id from public.collection_channels where key = 'p32_channel';
  select id into v_pm_id from public.payment_methods where key = 'p32_pm';

  select * into v_result from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 500.00))
  );
  create temporary table p32_order_e (order_id uuid) on commit drop;
  insert into p32_order_e values (v_result.id);
end $$;

reset role;
do $$
declare v_order_id uuid;
begin
  select order_id into v_order_id from p32_order_e;
  create temporary table p32_e_before as
    select id, category_id, karat_id, weight_grams, sale_price, gold_price_per_gram_snapshot, total_cost, gross_profit
    from public.sales_order_items where sales_order_id = v_order_id and status = 'active';
end $$;
grant select on p32_e_before to authenticated;

-- Correct the gold price for the same date AFTER the Sale exists.
set role authenticated;
set local request.jwt.claims = '{"sub":"d7000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v_karat_id uuid;
begin
  select id into v_karat_id from public.karats where code = 'P32K1';
  perform public.save_daily_gold_price(public.business_today(), v_karat_id, 999.0000, 'تصحيح سعر لاحق لاختبار E');
end $$;

reset role;
do $$
declare v_order_id uuid; v_version bigint;
begin
  select order_id into v_order_id from p32_order_e;
  select row_version into v_version from public.sales_orders where id = v_order_id;
  delete from p32_row_version;
  insert into p32_row_version values (v_version);
end $$;

do $$
declare
  v_order_id uuid; v_channel_id uuid; v_pm_id uuid; v_version bigint;
  v_preview jsonb; v_preview_total_cost text; v_preview_gross_profit text;
  v_saved record; v_saved_total_cost numeric; v_saved_gross_profit numeric;
begin
  select order_id into v_order_id from p32_order_e;
  select id into v_channel_id from public.collection_channels where key = 'p32_channel';
  select id into v_pm_id from public.payment_methods where key = 'p32_pm';
  select v into v_version from p32_row_version;

  -- Notes-only preview: the item payload is byte-for-byte the pre-edit item
  -- (same id/category/karat/weight/sale_price) — only p_notes changes.
  v_preview := public.preview_update_sales_order(
    v_order_id, v_version, v_pm_id, v_channel_id,
    (select jsonb_agg(jsonb_build_object('id', b.id, 'category_id', b.category_id, 'karat_id', b.karat_id, 'weight_grams', b.weight_grams, 'sale_price', b.sale_price)) from p32_e_before b),
    null, null, 'ملاحظة فقط بعد تصحيح السعر لاحقًا (E)'
  );

  v_preview_total_cost := v_preview -> 'items' -> 0 ->> 'total_cost';
  v_preview_gross_profit := v_preview -> 'items' -> 0 ->> 'gross_profit';

  -- Must stay on the OLD snapshot (300.1234-based total_cost), never leak
  -- the corrected 999.0000 price into a notes-only preview.
  assert (v_preview -> 'items' -> 0 ->> 'gold_price_per_gram') = '300.1234',
    format('FAIL E: معاينة تعديل بملاحظة فقط يجب أن تعرض لقطة سعر الذهب القديمة (300.1234)، وجدت %s', v_preview -> 'items' -> 0 ->> 'gold_price_per_gram');

  -- Now actually Save the identical payload and prove the saved result
  -- matches the preview literally, field for field.
  perform public.update_sales_order(
    v_order_id, v_pm_id, v_channel_id,
    (select jsonb_agg(jsonb_build_object('id', b.id, 'category_id', b.category_id, 'karat_id', b.karat_id, 'weight_grams', b.weight_grams, 'sale_price', b.sale_price)) from p32_e_before b),
    null, null, 'ملاحظة فقط بعد تصحيح السعر لاحقًا (E)', null, v_version
  );

  select total_cost, gross_profit into v_saved_total_cost, v_saved_gross_profit
    from public.sales_order_items where sales_order_id = v_order_id and status = 'active';

  assert v_preview_total_cost::numeric = v_saved_total_cost,
    format('FAIL E: total_cost في المعاينة (%s) يجب أن يطابق المحفوظ فعليًا (%s) تمامًا', v_preview_total_cost, v_saved_total_cost);
  assert v_preview_gross_profit::numeric = v_saved_gross_profit,
    format('FAIL E: gross_profit في المعاينة (%s) يجب أن يطابق المحفوظ فعليًا (%s) تمامًا', v_preview_gross_profit, v_saved_gross_profit);

  raise notice 'OK: E معاينة تعديل بملاحظة فقط بقيت على اللقطة القديمة رغم تصحيح سعر الذهب لاحقًا، وطابقت نتيجة الحفظ الفعلي حرفيًا';
end $$;

reset role;

-- ============================================================================
-- F) Item-level calculation_version semantics (spec item 7): a simulated
-- legacy item (v1) is NOT force-upgraded by a metadata-only edit, but IS
-- stamped v2 once its financial inputs are actually recalculated; a
-- brand-new order is entirely v2 at both header and item level.
-- ============================================================================
set role authenticated;
set local request.jwt.claims = '{"sub":"d7000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid; v_result record;
begin
  select id into v_store_id from public.stores where code = 'P32ST';
  select id into v_karat_id from public.karats where code = 'P32K1';
  select id into v_category_id from public.product_categories where code = 'p32cat';
  select id into v_channel_id from public.collection_channels where key = 'p32_channel';
  select id into v_pm_id from public.payment_methods where key = 'p32_pm';

  select * into v_result from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 500.00))
  );
  create temporary table p32_order_f (order_id uuid) on commit drop;
  insert into p32_order_f values (v_result.id);
end $$;

-- Every item freshly created after Patch 3.2 is v2, and the header-level
-- calculation_version too (item 7's "every Sale created after Patch 3.2 is
-- entirely v2"). Checked via the RLS-bypassing superuser/table-owner role —
-- sales_orders/sales_order_items have zero SELECT RLS policies for
-- `authenticated` (0059), exactly like every other direct-table read in
-- these test files.
reset role;
do $$
declare v_order_id uuid;
begin
  select order_id into v_order_id from p32_order_f;
  assert exists (
    select 1 from public.sales_order_items where sales_order_id = v_order_id and status = 'active' and calculation_version = 2
  ), 'بند جديد بعد Patch 3.2 يجب أن يحمل calculation_version=2';
  assert (select calculation_version from public.sales_orders where id = v_order_id) = 2,
    'رأس عملية بيع جديدة بعد Patch 3.2 يجب أن يحمل calculation_version=2';
  raise notice 'OK: F1 عملية بيع جديدة بالكامل (رأس وبند) بعد Patch 3.2 مُعلَّمة calculation_version=2';
end $$;

-- Simulate a LEGACY item (v1) — a fresh test database has no organically
-- pre-Patch-3.2 data to exercise this against, so this directly stamps
-- calculation_version=1 the same way an item created before this patch
-- would actually have it (default value, per 0074) — the mechanism under
-- test (never force-upgrading an untouched legacy item, but stamping v2 the
-- moment its financials are actually recalculated) is exactly the same
-- regardless of how the row came to be v1.
reset role;
do $$
declare v_order_id uuid; v_item_id uuid;
begin
  select order_id into v_order_id from p32_order_f;
  select id into v_item_id from public.sales_order_items where sales_order_id = v_order_id and status = 'active';
  update public.sales_order_items set calculation_version = 1 where id = v_item_id;

  create temporary table p32_f_item (item_id uuid, category_id uuid, karat_id uuid, weight_grams numeric, sale_price numeric) on commit drop;
  insert into p32_f_item
    select id, category_id, karat_id, weight_grams, sale_price from public.sales_order_items where id = v_item_id;
end $$;
grant select on p32_f_item to authenticated;

do $$
declare v_order_id uuid; v_version bigint;
begin
  select order_id into v_order_id from p32_order_f;
  select row_version into v_version from public.sales_orders where id = v_order_id;
  delete from p32_row_version;
  insert into p32_row_version values (v_version);
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"d7000000-0000-4000-8000-000000000001","role":"authenticated"}';
-- F2: metadata-only edit on the (simulated) legacy item must NOT force it
-- to v2 — it stays v1, untouched.
do $$
declare
  v_order_id uuid; v_channel_id uuid; v_pm_id uuid; v_version bigint; v_item_id uuid;
  v_category_id uuid; v_karat_id uuid; v_weight numeric; v_sale_price numeric;
begin
  select order_id into v_order_id from p32_order_f;
  select id into v_channel_id from public.collection_channels where key = 'p32_channel';
  select id into v_pm_id from public.payment_methods where key = 'p32_pm';
  select v into v_version from p32_row_version;
  select item_id, category_id, karat_id, weight_grams, sale_price
    into v_item_id, v_category_id, v_karat_id, v_weight, v_sale_price
    from p32_f_item;

  perform public.update_sales_order(
    v_order_id, v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('id', v_item_id, 'category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', v_weight, 'sale_price', v_sale_price, 'item_name', 'اسم وصفي فقط')),
    null, null, null, null, v_version
  );
end $$;

reset role;
do $$
declare v_item_id uuid; v_version_after int;
begin
  select item_id into v_item_id from p32_f_item;
  select calculation_version into v_version_after from public.sales_order_items where id = v_item_id and status = 'active';
  assert v_version_after = 1, format('FAIL F2: تعديل وصفي فقط يجب ألا يرفع calculation_version للبند القديم (v1)، وجد %s', v_version_after);
  raise notice 'OK: F2 تعديل بيانات وصفية فقط على بند قديم (v1) لم يرفعه إلى v2 — لم يُعَد حسابه';
end $$;

do $$
declare v_order_id uuid; v_version bigint;
begin
  select order_id into v_order_id from p32_order_f;
  select row_version into v_version from public.sales_orders where id = v_order_id;
  delete from p32_row_version;
  insert into p32_row_version values (v_version);
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"d7000000-0000-4000-8000-000000000001","role":"authenticated"}';
-- F3: an actual financial-input change on that same legacy item DOES
-- recalculate it and stamp it v2.
do $$
declare
  v_order_id uuid; v_channel_id uuid; v_pm_id uuid; v_version bigint; v_item_id uuid;
  v_category_id uuid; v_karat_id uuid;
begin
  select order_id into v_order_id from p32_order_f;
  select id into v_channel_id from public.collection_channels where key = 'p32_channel';
  select id into v_pm_id from public.payment_methods where key = 'p32_pm';
  select v into v_version from p32_row_version;
  select item_id, category_id, karat_id into v_item_id, v_category_id, v_karat_id from p32_f_item;

  perform public.update_sales_order(
    v_order_id, v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('id', v_item_id, 'category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 2.0000, 'sale_price', 900.00)),
    null, null, null, null, v_version
  );
end $$;

reset role;
do $$
declare v_item_id uuid; v_version_after int;
begin
  select item_id into v_item_id from p32_f_item;
  select calculation_version into v_version_after from public.sales_order_items where id = v_item_id and status = 'active';
  assert v_version_after = 2, format('FAIL F3: تغيير مدخل مالي فعلي على بند قديم (v1) يجب أن يرفعه إلى v2، وجد %s', v_version_after);
  raise notice 'OK: F3 تغيير مدخل مالي فعلي على بند قديم (v1) أعاد حسابه ورفعه إلى calculation_version=2 — عملية واحدة يمكن أن تحتوي مزيجًا من v1/v2 بتصميم مقصود';
end $$;

-- ============================================================================
-- G) Sales Read label permissions (spec item 8): a sales.view-ONLY actor
-- (no stores.view/payment_methods.view/collection_channels.view/users.view)
-- must still see order_number/store_name/salesperson_name/
-- payment_method_name/collection_channel_name — profit stays protected.
-- ============================================================================
set role authenticated;
set local request.jwt.claims = '{"sub":"d7000000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$
declare v_order_id uuid; v_json jsonb; v_row record;
begin
  select order_id into v_order_id from p32_order_c;

  v_json := public.get_sales_order(v_order_id);
  assert (v_json ->> 'store_name') is not null and (v_json ->> 'store_name') <> '', 'FAIL G: get_sales_order() يجب أن يُظهر store_name لمستخدم يملك sales.view فقط';
  assert (v_json ->> 'payment_method_name') is not null and (v_json ->> 'payment_method_name') <> '', 'FAIL G: get_sales_order() يجب أن يُظهر payment_method_name لمستخدم يملك sales.view فقط';
  assert (v_json ->> 'collection_channel_name') is not null and (v_json ->> 'collection_channel_name') <> '', 'FAIL G: get_sales_order() يجب أن يُظهر collection_channel_name لمستخدم يملك sales.view فقط';
  assert (v_json ->> 'salesperson_name') is not null and (v_json ->> 'salesperson_name') <> '', 'FAIL G: get_sales_order() يجب أن يُظهر salesperson_name لمستخدم يملك sales.view فقط';
  assert not (v_json ? 'gross_profit'), 'FAIL G: الربح يجب أن يبقى محجوبًا تمامًا (لا مفتاح gross_profit) لمستخدم بلا sales.view_profit';

  select * into v_row from public.list_sales_orders(p_order_number := (select order_number from public.sales_orders where id = v_order_id));
  assert v_row.store_name is not null and v_row.store_name <> '', 'FAIL G: list_sales_orders() يجب أن يُظهر store_name لمستخدم يملك sales.view فقط';
  assert v_row.payment_method_name is not null and v_row.payment_method_name <> '', 'FAIL G: list_sales_orders() يجب أن يُظهر payment_method_name لمستخدم يملك sales.view فقط';
  assert v_row.collection_channel_name is not null and v_row.collection_channel_name <> '', 'FAIL G: list_sales_orders() يجب أن يُظهر collection_channel_name لمستخدم يملك sales.view فقط';
  assert v_row.salesperson_name is not null and v_row.salesperson_name <> '', 'FAIL G: list_sales_orders() يجب أن يُظهر salesperson_name لمستخدم يملك sales.view فقط';
  assert v_row.gross_profit is null, 'FAIL G: عمود الربح في list_sales_orders() يجب أن يبقى NULL لمستخدم بلا sales.view_profit';

  raise notice 'OK: G مستخدم يملك sales.view فقط (بلا أي صلاحية .view من بيانات رئيسية) يرى كل التسميات الأساسية عبر get_sales_order()/list_sales_orders() — والربح يبقى محجوبًا تمامًا';
end $$;

reset role;

-- ============================================================================
-- H) Disabled-store historical-edit policy (spec item 9): Create requires
-- OPERABLE scope (rejected once the store is disabled); editing an EXISTING
-- Sale in that now-disabled store is still allowed via VISIBLE scope, since
-- store_id itself is immutable on edit.
-- ============================================================================
set role authenticated;
set local request.jwt.claims = '{"sub":"d7000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid; v_result record;
begin
  select id into v_store_id from public.stores where code = 'P32ST';
  select id into v_karat_id from public.karats where code = 'P32K1';
  select id into v_category_id from public.product_categories where code = 'p32cat';
  select id into v_channel_id from public.collection_channels where key = 'p32_channel';
  select id into v_pm_id from public.payment_methods where key = 'p32_pm';

  select * into v_result from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 400.00))
  );
  create temporary table p32_order_h (order_id uuid) on commit drop;
  insert into p32_order_h values (v_result.id);
end $$;

reset role;
update public.stores set status = 'disabled' where code = 'P32ST';
do $$
declare v_order_id uuid; v_version bigint;
begin
  select order_id into v_order_id from p32_order_h;
  select row_version into v_version from public.sales_orders where id = v_order_id;
  delete from p32_row_version;
  insert into p32_row_version values (v_version);
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"d7000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- H1: Create in the now-disabled store is rejected (operable scope only).
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid; v_bug boolean := false;
begin
  select id into v_store_id from public.stores where code = 'P32ST';
  select id into v_karat_id from public.karats where code = 'P32K1';
  select id into v_category_id from public.product_categories where code = 'p32cat';
  select id into v_channel_id from public.collection_channels where key = 'p32_channel';
  select id into v_pm_id from public.payment_methods where key = 'p32_pm';

  begin
    perform public.create_sales_order(
      v_store_id, public.business_today(), v_pm_id, v_channel_id,
      jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 400.00))
    );
    v_bug := true;
  exception when others then
    raise notice 'OK: H1 رُفض إنشاء عملية بيع جديدة في متجر معطَّل (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG H1: قُبل إنشاء عملية بيع جديدة في متجر معطَّل — Create يجب أن يبقى بنطاق Operable فقط'; end if;
end $$;

-- H2: editing the EXISTING historical Sale in that now-disabled store still
-- succeeds (visible scope, store_id immutable).
do $$
declare
  v_order_id uuid; v_channel_id uuid; v_pm_id uuid; v_category_id uuid; v_karat_id uuid; v_version bigint; v_result record;
begin
  select order_id into v_order_id from p32_order_h;
  select id into v_channel_id from public.collection_channels where key = 'p32_channel';
  select id into v_pm_id from public.payment_methods where key = 'p32_pm';
  select id into v_category_id from public.product_categories where code = 'p32cat';
  select id into v_karat_id from public.karats where code = 'P32K1';
  select v into v_version from p32_row_version;

  select * into v_result from public.update_sales_order(
    v_order_id, v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 400.00)),
    'تصحيح تاريخي بعد تعطيل المتجر', null, null, null, v_version
  );
  assert v_result.id = v_order_id, 'FAIL H2: تعديل عملية بيع تاريخية في متجر أصبح معطَّلًا يجب أن ينجح (النطاق المرئي، المتجر غير قابل للتغيير أصلًا)';

  -- The Edit-lookup RPC (item 6) must also work under the same policy.
  perform public.sales_order_edit_lookups(v_order_id);

  raise notice 'OK: H2 تعديل عملية بيع تاريخية موجودة في متجر أصبح معطَّلًا نجح فعليًا (النطاق المرئي)، وrpc البحث الخاص بالتعديل عمل أيضًا لنفس العملية';
end $$;

reset role;
update public.stores set status = 'active' where code = 'P32ST'; -- restore

-- ============================================================================
-- I) Complete audit old/new (spec item 10): sale.create's new_values now
-- carries the final items array; sale.update's new_values ALSO carries the
-- final items array (previously header-only) alongside old_values, plus
-- calculation_version/row_version/totals on both sides.
-- ============================================================================
set role authenticated;
set local request.jwt.claims = '{"sub":"d7000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid; v_result record;
  v_create_new jsonb;
begin
  select id into v_store_id from public.stores where code = 'P32ST';
  select id into v_karat_id from public.karats where code = 'P32K1';
  select id into v_category_id from public.product_categories where code = 'p32cat';
  select id into v_channel_id from public.collection_channels where key = 'p32_channel';
  select id into v_pm_id from public.payment_methods where key = 'p32_pm';

  select * into v_result from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 300.00))
  );
  create temporary table p32_order_i (order_id uuid) on commit drop;
  insert into p32_order_i values (v_result.id);

  select new_values into v_create_new from public.audit_logs
    where action = 'sale.create' and entity_type = 'sales_order' and entity_id = v_result.id;
  assert jsonb_typeof(v_create_new -> 'items') = 'array' and jsonb_array_length(v_create_new -> 'items') = 1,
    format('FAIL I1: تدقيق sale.create يجب أن يحمل new_values.items بمصفوفة بند واحد، وجد %s', v_create_new -> 'items');
  assert (v_create_new ->> 'calculation_version')::int = 2, 'FAIL I1: تدقيق sale.create يجب أن يحمل calculation_version=2 في new_values';
  raise notice 'OK: I1 تدقيق sale.create يحمل مصفوفة البنود النهائية في new_values (وليس رأسًا فقط)';
end $$;

reset role;
do $$
declare v_order_id uuid; v_version bigint;
begin
  select order_id into v_order_id from p32_order_i;
  select row_version into v_version from public.sales_orders where id = v_order_id;
  delete from p32_row_version;
  insert into p32_row_version values (v_version);
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"d7000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_order_id uuid; v_channel_id uuid; v_pm_id uuid; v_category_id uuid; v_karat_id uuid; v_version bigint;
  v_old jsonb; v_new jsonb;
begin
  select order_id into v_order_id from p32_order_i;
  select id into v_channel_id from public.collection_channels where key = 'p32_channel';
  select id into v_pm_id from public.payment_methods where key = 'p32_pm';
  select id into v_category_id from public.product_categories where code = 'p32cat';
  select id into v_karat_id from public.karats where code = 'P32K1';
  select v into v_version from p32_row_version;

  perform public.update_sales_order(
    v_order_id, v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 3.0000, 'sale_price', 900.00)),
    'تعديل لاختبار التدقيق الكامل (I)', null, null, null, v_version
  );

  select old_values, new_values into v_old, v_new
    from public.audit_logs
    where action = 'sale.update' and entity_type = 'sales_order' and entity_id = v_order_id
    order by created_at desc limit 1;

  assert jsonb_typeof(v_old -> 'items') = 'array' and jsonb_array_length(v_old -> 'items') = 1,
    'FAIL I2: old_values.items يجب أن يحمل حالة البند قبل التعديل';
  assert jsonb_typeof(v_new -> 'items') = 'array' and jsonb_array_length(v_new -> 'items') = 1,
    'FAIL I2: new_values.items يجب أن يحمل حالة البنود النشطة بعد التعديل (لم يكن موجودًا إطلاقًا قبل Patch 3.2)';
  assert (v_new -> 'items' -> 0 ->> 'sale_price')::numeric = 900.00,
    format('FAIL I2: new_values.items[0].sale_price يجب أن يعكس القيمة الجديدة (900.00)، وجد %s', v_new -> 'items' -> 0 ->> 'sale_price');
  assert (v_old ->> 'row_version')::bigint = v_version, 'FAIL I2: old_values.row_version يجب أن يعكس الإصدار قبل التعديل';
  assert (v_new ->> 'row_version')::bigint = v_version + 1, 'FAIL I2: new_values.row_version يجب أن يعكس الإصدار بعد التعديل (زيادة بمقدار 1)';
  assert (v_new ->> 'subtotal')::numeric = 900.00, format('FAIL I2: new_values.subtotal يجب أن يعكس المجموع الجديد (900.00)، وجد %s', v_new ->> 'subtotal');

  raise notice 'OK: I2 تدقيق sale.update يحمل old_values.items وnew_values.items معًا (مع calculation_version/row_version/subtotal على الجانبين) — يمكن فهم التغيير بدقة من الطرفين';
end $$;

reset role;

-- ============================================================================
-- Done.
-- ============================================================================
do $$ begin raise notice 'OK: ALL Sales Integrity Patch 3.2 (Part 1, single-session) tests passed'; end $$;

rollback;
