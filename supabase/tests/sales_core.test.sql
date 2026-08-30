-- ============================================================================
-- Integration test: Phase 3 — Sales Core (migrations 0058-0064)
-- ============================================================================
-- Covers the Phase 3 spec's §29-§32 requirements: VAT rate versioning
-- (0058), create_sales_order/update_sales_order/preview_sales_order/
-- list_sales_orders/get_sales_order (0061-0063), Daily Close (0064),
-- DB-level profit protection, store-scope enforcement, and atomicity.
--
-- This file is a SEPARATE integration test from rls_and_permissions.test.sql
-- (Foundation, 0001-0039) and financial_master_data.test.sql /
-- financial_integrity_*.test.sql (Phase 2, 0040-0057) — none of those are
-- touched by Phase 3, so their own test files are left untouched too. All
-- files are run independently in CI/local verification.
--
-- Safe to run against a real (including production-like staging) Supabase
-- database: everything happens inside a transaction that is ALWAYS rolled
-- back at the end, so no test data is left behind.
--
-- Requires migrations 0001-0064 + supabase/seed.sql to already be applied.
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/sales_core.test.sql
--
-- Every assertion either raises (test fails, transaction aborts, non-zero
-- exit) or prints an "OK:" notice. Read the output top to bottom.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0. Setup — actors, stores, master data. Prefix 's3...' (Phase 3, Sales
-- Core) is not used by any other test file's actors, so this file can never
-- collide with them even if a future test run ever chained files inside one
-- transaction.
--
--   01 = Sales Manager    — full Sales permission set (create/edit/view/
--        view_profit/close_day/edit_closed_day) + every master-data manage
--        permission needed to build fixtures (karats/categories/payment_
--        methods/collection_channels/gold_prices/manufacturing_fees/
--        vat_rates) + stores.create/view. store_access_scope='all'.
--   02 = Sales Employee    — sales.create/edit/view only. No view_profit, no
--        close_day, no edit_closed_day. store_access_scope='all'.
--   03 = View-only         — sales.view only. store_access_scope='all'.
--   04 = No permission     — holds nothing at all. store_access_scope='all'.
--   05 = Profit Viewer     — sales.view + sales.view_profit, but NOT create/
--        edit — proves profit visibility is independent of edit rights.
--        store_access_scope='all'.
--   06 = Store-B-only      — sales.create/edit/view/view_profit, but scoped
--        (store_access_scope='single') to Store B ONLY — used for store-
--        scope enforcement (cannot see/operate on Store A's data).
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('d3000000-0000-4000-8000-000000000001', 'test-s3-manager@example.invalid'),
  ('d3000000-0000-4000-8000-000000000002', 'test-s3-employee@example.invalid'),
  ('d3000000-0000-4000-8000-000000000003', 'test-s3-viewer@example.invalid'),
  ('d3000000-0000-4000-8000-000000000004', 'test-s3-noperm@example.invalid'),
  ('d3000000-0000-4000-8000-000000000005', 'test-s3-profitviewer@example.invalid'),
  ('d3000000-0000-4000-8000-000000000006', 'test-s3-storeb-only@example.invalid');

update public.profiles set full_name = 'Test Sales Manager', status = 'active', store_access_scope = 'all'
  where id = 'd3000000-0000-4000-8000-000000000001';
update public.profiles set full_name = 'Test Sales Employee', status = 'active', store_access_scope = 'all'
  where id = 'd3000000-0000-4000-8000-000000000002';
update public.profiles set full_name = 'Test Sales Viewer', status = 'active', store_access_scope = 'all'
  where id = 'd3000000-0000-4000-8000-000000000003';
update public.profiles set full_name = 'Test No-Permission User', status = 'active', store_access_scope = 'all'
  where id = 'd3000000-0000-4000-8000-000000000004';
update public.profiles set full_name = 'Test Profit Viewer', status = 'active', store_access_scope = 'all'
  where id = 'd3000000-0000-4000-8000-000000000005';
update public.profiles set full_name = 'Test Store-B-Only Sales', status = 'active', store_access_scope = 'all'
  where id = 'd3000000-0000-4000-8000-000000000006';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'd3000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in (
    'stores.view', 'stores.create',
    'karats.view', 'karats.manage', 'categories.view', 'categories.manage',
    'collection_channels.view', 'collection_channels.manage',
    'payment_methods.view', 'payment_methods.manage',
    'gold_prices.view', 'gold_prices.edit',
    'manufacturing_fees.view', 'manufacturing_fees.manage',
    'vat_rates.view', 'vat_rates.manage',
    'sales.create', 'sales.edit', 'sales.view', 'sales.view_profit',
    'sales.close_day', 'sales.edit_closed_day'
  );

-- Master-data VIEW permissions (stores/karats/categories/payment_methods/
-- collection_channels/gold_prices) mirror exactly what seed.sql grants the
-- real 'sales_employee' role — a sales actor needs View-only access to the
-- data a sale screen reads from (spec §12), even though this test builds
-- actors directly via user_permission_overrides rather than roles.
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'd3000000-0000-4000-8000-000000000002', id, 'grant' from public.permissions
  where key in (
    'sales.create', 'sales.edit', 'sales.view',
    'stores.view', 'karats.view', 'categories.view', 'payment_methods.view', 'collection_channels.view', 'gold_prices.view'
  );

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'd3000000-0000-4000-8000-000000000003', id, 'grant' from public.permissions
  where key in (
    'sales.view',
    'stores.view', 'karats.view', 'categories.view', 'payment_methods.view', 'collection_channels.view', 'gold_prices.view'
  );

-- 04 gets nothing at all.

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'd3000000-0000-4000-8000-000000000005', id, 'grant' from public.permissions
  where key in ('sales.view', 'sales.view_profit');

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'd3000000-0000-4000-8000-000000000006', id, 'grant' from public.permissions
  where key in (
    'sales.create', 'sales.edit', 'sales.view', 'sales.view_profit',
    'stores.view', 'karats.view', 'categories.view', 'payment_methods.view', 'collection_channels.view', 'gold_prices.view'
  );

-- ---------------------------------------------------------------------------
-- Fixtures: two stores, one karat, one category, one collection channel, one
-- percentage-fee payment method, a gold price + manufacturing fee version
-- for the karat (both effective from business_today()), all created by the
-- Sales Manager (01), who holds every needed *.manage/*.edit/*.create
-- permission. VAT uses the 15% baseline row already seeded by 0058/seed.sql
-- (effective_from = business_today()) — no new VAT version is needed for
-- the happy-path fixtures.
-- ---------------------------------------------------------------------------
set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_store_a uuid;
  v_store_b uuid;
  v_karat_id uuid;
  v_category_id uuid;
  v_channel_id uuid;
  v_payment_method_id uuid;
begin
  insert into public.stores (code, name_ar, status) values ('S3STA', 'متجر اختبار أ', 'active') returning id into v_store_a;
  insert into public.stores (code, name_ar, status) values ('S3STB', 'متجر اختبار ب', 'active') returning id into v_store_b;
  insert into public.karats (code, name_ar, sort_order, status) values ('S3K1', 'عيار اختبار 3', 991, 'active') returning id into v_karat_id;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('s3cat1', 'تصنيف اختبار 3', 991, 'active') returning id into v_category_id;
  insert into public.collection_channels (key, name_ar, sort_order, status) values ('s3_channel', 'قناة اختبار 3', 991, 'active') returning id into v_channel_id;
  insert into public.payment_methods (key, name_ar, fee_model, sort_order, status) values ('s3_pm', 'طريقة دفع اختبار 3', 'percentage', 991, 'active') returning id into v_payment_method_id;

  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 300.0000, 'd3000000-0000-4000-8000-000000000001');

  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, public.business_today(), 's3 fixture');
  perform public.create_payment_method_fee_version(v_payment_method_id, 2.5, 0, public.business_today(), 's3 fixture');
end $$;

-- Give actor 06 a 'single' scope pinned to Store B, and actor 01 an inactive
-- disabled store used later for a "store not operable" negative test.
do $$
declare v_store_b uuid; v_store_disabled uuid;
begin
  select id into v_store_b from public.stores where code = 'S3STB';
  insert into public.stores (code, name_ar, status) values ('S3STD', 'متجر معطّل', 'disabled') returning id into v_store_disabled;
end $$;

reset role;
reset request.jwt.claims;

update public.profiles
  set store_access_scope = 'single', default_store_id = (select id from public.stores where code = 'S3STB')
  where id = 'd3000000-0000-4000-8000-000000000006';

-- ============================================================================
-- 1. VAT rate versioning (0058)
-- ============================================================================
set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- 1.1 Baseline 15% VAT version exists and resolves for business_today().
do $$
declare v_rate numeric; v_rate_text text;
begin
  v_rate := public.vat_rate_for_date();
  v_rate_text := public.vat_rate_for_date_safe();
  assert v_rate = 15.000, format('نسبة الضريبة الأساسية يجب أن تكون 15.000، وجد %s', v_rate);
  assert v_rate_text = '15.000', format('vat_rate_for_date_safe() يجب أن يعيد نصًا "15.000"، وجد %s', v_rate_text);
  raise notice 'OK: 1.1 الإصدار الأساسي لضريبة القيمة المضافة (15%%) يُحل بنجاح كرقم ونص';
end $$;

-- 1.2 create_vat_rate_version() by an authorized manager schedules a FUTURE
-- version correctly (ends nothing yet, since it's future).
do $$
declare v_new_id uuid; v_open_count int;
begin
  v_new_id := public.create_vat_rate_version(20.000, public.business_today() + 30, 's3 test future VAT');
  assert v_new_id is not null, 'create_vat_rate_version() يجب أن يعيد id';

  select count(*) into v_open_count from public.vat_rate_versions
    where effective_to is null and status = 'active';
  assert v_open_count = 1, format('يجب أن يبقى إصدار مفتوح واحد بالضبط بعد جدولة إصدار مستقبلي، وجد %s', v_open_count);

  -- Still resolves to 15% for TODAY (the new version is not effective yet).
  assert public.vat_rate_for_date(public.business_today()) = 15.000, 'اليوم يجب أن يبقى بنسبة 15%% قبل سريان الإصدار المستقبلي';
  assert public.vat_rate_for_date(public.business_today() + 30) = 20.000, 'بعد 30 يومًا يجب أن يُحل إلى 20%% (الإصدار المستقبلي)';
  raise notice 'OK: 1.2 جدولة إصدار ضريبة مستقبلي (20%%) نجحت ولم تُغيّر الإصدار الحالي بعد';
end $$;

-- 1.3 At-most-one-Future-Version guard: a second future version is rejected
-- while one is already pending.
do $$
declare v_bug boolean := false;
begin
  begin
    perform public.create_vat_rate_version(25.000, public.business_today() + 60, 'should be rejected');
    v_bug := true;
  exception when others then
    raise notice 'OK: 1.3 رُفضت محاولة جدولة إصدار ضريبة مستقبلي ثانٍ فوق إصدار مستقبلي قائم (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: قُبل إصدار ضريبة مستقبلي ثانٍ رغم وجود إصدار مستقبلي لم يسرِ بعد'; end if;
end $$;

-- 1.4 cancel_vat_rate_version() withdraws the future version and correctly
-- reopens the exact predecessor (back to 15%, open-ended again).
do $$
declare v_future_id uuid; v_open_count int; v_rate numeric;
begin
  select id into v_future_id from public.vat_rate_versions where rate_percent = 20.000 and status = 'active';
  perform public.cancel_vat_rate_version(v_future_id);

  select count(*) into v_open_count from public.vat_rate_versions where effective_to is null and status = 'active';
  assert v_open_count = 1, format('يجب أن يبقى إصدار مفتوح واحد بالضبط بعد الإلغاء، وجد %s', v_open_count);

  v_rate := public.vat_rate_for_date(public.business_today() + 30);
  assert v_rate = 15.000, format('بعد إلغاء الإصدار المستقبلي، يجب أن يعود الحل إلى 15%% حتى لتاريخ مستقبلي، وجد %s', v_rate);
  raise notice 'OK: 1.4 إلغاء إصدار ضريبة مستقبلي أعاد فتح الإصدار السابق (15%%) بنجاح';
end $$;

-- 1.5 vat_rate_for_date() raises (never returns a fabricated 0/15 default)
-- for a date strictly before any version's effective_from.
do $$
declare v_rate numeric; v_raised boolean := false;
begin
  begin
    v_rate := public.vat_rate_for_date(public.business_today() - 3650);
  exception when others then
    v_raised := true;
    raise notice 'OK: 1.5 vat_rate_for_date() يرفع خطأ بدل افتراض نسبة لتاريخ يسبق أي إصدار مسجَّل (%)', sqlerrm;
  end;
  if not v_raised then
    raise exception 'BUG: vat_rate_for_date() أعاد قيمة (%) بدل رفع خطأ لتاريخ بلا إصدار ضريبة معتمد', v_rate;
  end if;
end $$;

-- 1.6 Unauthorized create rejected (view-only actor 03 has no vat_rates.*).
set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000003","role":"authenticated"}';
do $$
declare v_bug boolean := false;
begin
  begin
    perform public.create_vat_rate_version(10.000, public.business_today() + 5, 'unauthorized attempt');
    v_bug := true;
  exception when others then
    raise notice 'OK: 1.6 مستخدم بلا vat_rates.manage مُنع من إنشاء إصدار ضريبة (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: مستخدم بلا vat_rates.manage استطاع إنشاء إصدار ضريبة'; end if;
end $$;

-- 1.7 No direct-write RLS policy at all on vat_rate_versions (0058's binding
-- decision) — even the actor WITH vat_rates.manage cannot INSERT directly.
set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v_bug boolean := false;
begin
  begin
    insert into public.vat_rate_versions (rate_percent, effective_from, status)
      values (99.000, public.business_today() + 100, 'active');
    v_bug := true;
  exception when others then
    raise notice 'OK: 1.7 إدخال مباشر في vat_rate_versions مرفوض حتى لمستخدم يملك vat_rates.manage (لا توجد سياسة RLS للكتابة إطلاقًا) (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: تم قبول إدخال مباشر في vat_rate_versions رغم عدم وجود أي سياسة RLS للكتابة'; end if;
end $$;

reset role;

-- ============================================================================
-- 2. Sales core: create_sales_order (0061)
-- ============================================================================

-- 2.1 Exact worked example (spec §29): weight 5g, gold 300/g, mfg 10/g,
-- VAT 15%, sale price 2000.00, payment fee 2.5%+0.
-- Base=1550.00, VAT=232.50, Total=1782.50, Item Gross Profit=217.50,
-- Subtotal=2000.00, Order Gross Profit=217.50, Payment Fee=50.00,
-- Net Sales Profit=167.50.
set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000002","role":"authenticated"}';

do $$
declare
  v_store_id uuid;
  v_karat_id uuid;
  v_category_id uuid;
  v_channel_id uuid;
  v_payment_method_id uuid;
  v_result record;
begin
  select id into v_store_id from public.stores where code = 'S3STA';
  select id into v_karat_id from public.karats where code = 'S3K1';
  select id into v_category_id from public.product_categories where code = 's3cat1';
  select id into v_channel_id from public.collection_channels where key = 's3_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's3_pm';

  select * into v_result from public.create_sales_order(
    v_store_id, public.business_today(), v_payment_method_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 5.0000, 'sale_price', 2000.00)),
    'عميل اختبار', '0500000000', 'ملاحظة اختبار'
  );

  create temporary table s3_worked_example (order_id uuid, order_number text) on commit drop;
  insert into s3_worked_example values (v_result.id, v_result.order_number);
  raise notice 'OK: 2.1(a) create_sales_order() نجح — رقم العملية %', v_result.order_number;
end $$;

reset role;

do $$
declare v_order_id uuid; v_item record; v_order record;
begin
  select order_id into v_order_id from s3_worked_example;

  select * into v_item from public.sales_order_items where sales_order_id = v_order_id;
  if v_item.base_cost <> 1550.00 then raise exception 'FAIL base_cost expected 1550.00 got %', v_item.base_cost; end if;
  if v_item.vat_cost <> 232.50 then raise exception 'FAIL vat_cost expected 232.50 got %', v_item.vat_cost; end if;
  if v_item.total_cost <> 1782.50 then raise exception 'FAIL total_cost expected 1782.50 got %', v_item.total_cost; end if;
  if v_item.gross_profit <> 217.50 then raise exception 'FAIL item gross_profit expected 217.50 got %', v_item.gross_profit; end if;
  if v_item.gold_component_cost <> 1500.00 then raise exception 'FAIL gold_component_cost expected 1500.00 got %', v_item.gold_component_cost; end if;
  if v_item.manufacturing_component_cost <> 50.00 then raise exception 'FAIL manufacturing_component_cost expected 50.00 got %', v_item.manufacturing_component_cost; end if;

  select * into v_order from public.sales_orders where id = v_order_id;
  if v_order.subtotal <> 2000.00 then raise exception 'FAIL subtotal expected 2000.00 got %', v_order.subtotal; end if;
  if v_order.gross_profit <> 217.50 then raise exception 'FAIL order gross_profit expected 217.50 got %', v_order.gross_profit; end if;
  if v_order.payment_fee_amount <> 50.00 then raise exception 'FAIL payment_fee_amount expected 50.00 got %', v_order.payment_fee_amount; end if;
  if v_order.net_sales_profit <> 167.50 then raise exception 'FAIL net_sales_profit expected 167.50 got %', v_order.net_sales_profit; end if;
  if v_order.customer_name <> 'عميل اختبار' then raise exception 'FAIL customer_name not persisted correctly'; end if;
  if v_order.order_number !~ '^SALE-[0-9]{10}$' then raise exception 'FAIL order_number format unexpected: %', v_order.order_number; end if;

  raise notice 'OK: 2.1(b) المثال المحلول في المواصفة (§29) مطابق تمامًا — كل قيم التكلفة والربح صحيحة';
end $$;

-- 2.2 Multi-item order: 2 items, verify per-item independence and correct
-- summation (order subtotal/gross_profit = sum of item values; order number
-- issued via SEQUENCE — distinct, monotonically increasing, never MAX+1).
set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid;
  v_result1 record; v_result2 record;
  v_num1 bigint; v_num2 bigint;
begin
  select id into v_store_id from public.stores where code = 'S3STA';
  select id into v_karat_id from public.karats where code = 'S3K1';
  select id into v_category_id from public.product_categories where code = 's3cat1';
  select id into v_channel_id from public.collection_channels where key = 's3_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's3_pm';

  -- Item 1: weight 1g -> base=310.00, vat=46.50, total=356.50, gross=400-356.50=43.50
  -- Item 2: weight 2.5g -> base=775.00, vat=116.25, total=891.25, gross=1000-891.25=108.75
  -- Expected subtotal=1400.00, order gross profit=43.50+108.75=152.25
  select * into v_result1 from public.create_sales_order(
    v_store_id, public.business_today(), v_payment_method_id, v_channel_id,
    jsonb_build_array(
      jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 400.00),
      jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 2.5000, 'sale_price', 1000.00)
    )
  );

  select * into v_result2 from public.create_sales_order(
    v_store_id, public.business_today(), v_payment_method_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 400.00))
  );

  create temporary table s3_multi_item (order_id uuid) on commit drop;
  insert into s3_multi_item values (v_result1.id);

  v_num1 := substring(v_result1.order_number from 6)::bigint;
  v_num2 := substring(v_result2.order_number from 6)::bigint;
  assert v_num2 > v_num1, format('رقم العملية الثانية (%s) يجب أن يكون أكبر من الأولى (%s) — تسلسل SEQUENCE', v_num2, v_num1);
  assert v_result1.order_number <> v_result2.order_number, 'رقما العمليتين يجب أن يكونا فريدين';
  raise notice 'OK: 2.2(a) أرقام العمليات فريدة ومتصاعدة عبر SEQUENCE (% ثم %)', v_result1.order_number, v_result2.order_number;
end $$;

reset role;

do $$
declare v_order_id uuid; v_order record; v_item_count int; v_sum_gross numeric;
begin
  select order_id into v_order_id from s3_multi_item;
  select * into v_order from public.sales_orders where id = v_order_id;
  select count(*), coalesce(sum(gross_profit), 0) into v_item_count, v_sum_gross
    from public.sales_order_items where sales_order_id = v_order_id;

  assert v_item_count = 2, format('يجب أن تحتوي العملية على بندين، وجد %s', v_item_count);
  if v_order.subtotal <> 1400.00 then raise exception 'FAIL multi-item subtotal expected 1400.00 got %', v_order.subtotal; end if;
  if v_order.gross_profit <> 152.25 then raise exception 'FAIL multi-item order gross_profit expected 152.25 got %', v_order.gross_profit; end if;
  if v_order.gross_profit <> v_sum_gross then raise exception 'FAIL order.gross_profit (%) must equal SUM(item.gross_profit) (%)', v_order.gross_profit, v_sum_gross; end if;
  raise notice 'OK: 2.2(b) عملية متعددة البنود: المجموع الفرعي وإجمالي الربح صحيحان ويطابقان مجموع البنود';
end $$;

-- 2.3 Required-field validation: missing store/date/payment method/channel.
set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid; v_bug boolean := false;
begin
  select id into v_store_id from public.stores where code = 'S3STA';
  select id into v_karat_id from public.karats where code = 'S3K1';
  select id into v_category_id from public.product_categories where code = 's3cat1';
  select id into v_channel_id from public.collection_channels where key = 's3_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's3_pm';

  begin
    perform public.create_sales_order(null, public.business_today(), v_payment_method_id, v_channel_id,
      jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 100.00)));
    v_bug := true;
  exception when others then
    raise notice 'OK: 2.3(a) رُفض إنشاء عملية بيع بدون متجر (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: قُبلت عملية بيع بدون متجر'; end if;

  v_bug := false;
  begin
    perform public.create_sales_order(v_store_id, public.business_today(), v_payment_method_id, v_channel_id, '[]'::jsonb);
    v_bug := true;
  exception when others then
    raise notice 'OK: 2.3(b) رُفضت عملية بيع بدون أي بند (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: قُبلت عملية بيع بدون بنود'; end if;
end $$;

-- 2.4 Store outside the actor's operable scope rejected (Store-B-only actor
-- 06 attempting Store A).
set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000006","role":"authenticated"}';
do $$
declare v_store_a uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid; v_bug boolean := false;
begin
  select id into v_store_a from public.stores where code = 'S3STA';
  select id into v_karat_id from public.karats where code = 'S3K1';
  select id into v_category_id from public.product_categories where code = 's3cat1';
  select id into v_channel_id from public.collection_channels where key = 's3_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's3_pm';

  begin
    perform public.create_sales_order(v_store_a, public.business_today(), v_payment_method_id, v_channel_id,
      jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 100.00)));
    v_bug := true;
  exception when others then
    raise notice 'OK: 2.4 مستخدم مُقيَّد بمتجر ب مُنع من إنشاء عملية بيع في متجر أ (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: مستخدم مُقيَّد بمتجر ب استطاع إنشاء عملية بيع في متجر أ خارج نطاقه'; end if;
end $$;

-- 2.4b An inactive (disabled) store is also rejected, even for the full-
-- scope Sales Manager (store_access_scope='all' only covers ACTIVE stores
-- for operability, per user_operable_store_ids()).
set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v_store_disabled uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid; v_bug boolean := false;
begin
  select id into v_store_disabled from public.stores where code = 'S3STD';
  select id into v_karat_id from public.karats where code = 'S3K1';
  select id into v_category_id from public.product_categories where code = 's3cat1';
  select id into v_channel_id from public.collection_channels where key = 's3_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's3_pm';

  begin
    perform public.create_sales_order(v_store_disabled, public.business_today(), v_payment_method_id, v_channel_id,
      jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 100.00)));
    v_bug := true;
  exception when others then
    raise notice 'OK: 2.4b رُفض إنشاء عملية بيع في متجر معطّل حتى لمدير مبيعات بنطاق "الكل" (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: قُبلت عملية بيع في متجر معطّل'; end if;
end $$;

-- 2.5 A future sale_date is rejected.
do $$
declare v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid; v_bug boolean := false;
begin
  select id into v_store_id from public.stores where code = 'S3STA';
  select id into v_karat_id from public.karats where code = 'S3K1';
  select id into v_category_id from public.product_categories where code = 's3cat1';
  select id into v_channel_id from public.collection_channels where key = 's3_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's3_pm';

  begin
    perform public.create_sales_order(v_store_id, public.business_today() + 1, v_payment_method_id, v_channel_id,
      jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 100.00)));
    v_bug := true;
  exception when others then
    raise notice 'OK: 2.5 رُفض إنشاء عملية بيع بتاريخ مستقبلي (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: قُبلت عملية بيع بتاريخ مستقبلي'; end if;
end $$;

-- 2.6 Inactive category/karat rejected for a NEW sale.
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid;
  v_inactive_category uuid; v_inactive_karat uuid; v_bug boolean := false;
begin
  select id into v_store_id from public.stores where code = 'S3STA';
  select id into v_karat_id from public.karats where code = 'S3K1';
  select id into v_channel_id from public.collection_channels where key = 's3_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's3_pm';

  insert into public.product_categories (code, name_ar, sort_order, status) values ('s3cat_inactive', 'تصنيف معطّل', 992, 'inactive') returning id into v_inactive_category;
  insert into public.karats (code, name_ar, sort_order, status) values ('S3K_INACTIVE', 'عيار معطّل', 992, 'inactive') returning id into v_inactive_karat;

  begin
    perform public.create_sales_order(v_store_id, public.business_today(), v_payment_method_id, v_channel_id,
      jsonb_build_array(jsonb_build_object('category_id', v_inactive_category, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 100.00)));
    v_bug := true;
  exception when others then
    raise notice 'OK: 2.6(a) رُفض بند بتصنيف غير نشط (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: قُبل بند بتصنيف غير نشط'; end if;

  select id into v_category_id from public.product_categories where code = 's3cat1';
  v_bug := false;
  begin
    perform public.create_sales_order(v_store_id, public.business_today(), v_payment_method_id, v_channel_id,
      jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_inactive_karat, 'weight_grams', 1.0000, 'sale_price', 100.00)));
    v_bug := true;
  exception when others then
    raise notice 'OK: 2.6(b) رُفض بند بعيار غير نشط (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: قُبل بند بعيار غير نشط'; end if;
end $$;

-- 2.7 Missing financial config fails loud (no gold price recorded for a
-- SECOND karat) and — combined with atomicity — a multi-item order where
-- item 2 fails leaves ZERO rows behind for item 1 too (§25/§28).
--
-- The before/after row counts MUST be taken via the superuser/table-owner
-- role (RLS bypassed), never as `authenticated` — sales_orders/sales_order_
-- items have ZERO SELECT policies (0059), so a count taken as `authenticated`
-- would always read 0 regardless of whether the bug exists, making the
-- comparison vacuously true. See section 3.5, which proves that zero-rows
-- behavior directly; this section must not accidentally rely on it.
do $$
declare v_store_id uuid; v_no_price_karat uuid;
begin
  select id into v_store_id from public.stores where code = 'S3STA';
  insert into public.karats (code, name_ar, sort_order, status) values ('S3K_NOPRICE', 'عيار بلا سعر', 993, 'active') returning id into v_no_price_karat;
  -- deliberately: no daily_gold_prices row for v_no_price_karat.
end $$;

reset role;
do $$
declare v_store_id uuid; v_orders_before int; v_items_before int;
begin
  select id into v_store_id from public.stores where code = 'S3STA';
  select count(*) into v_orders_before from public.sales_orders where store_id = v_store_id;
  select count(*) into v_items_before from public.sales_order_items it
    join public.sales_orders so on so.id = it.sales_order_id where so.store_id = v_store_id;

  create temporary table s3_atomicity_27 (orders_before int, items_before int) on commit drop;
  insert into s3_atomicity_27 values (v_orders_before, v_items_before);
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid;
  v_no_price_karat uuid; v_bug boolean := false;
begin
  select id into v_store_id from public.stores where code = 'S3STA';
  select id into v_karat_id from public.karats where code = 'S3K1';
  select id into v_category_id from public.product_categories where code = 's3cat1';
  select id into v_channel_id from public.collection_channels where key = 's3_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's3_pm';
  select id into v_no_price_karat from public.karats where code = 'S3K_NOPRICE';

  begin
    -- item 1 valid, item 2 references the karat with no recorded gold price
    -- -> must fail loud and roll back BOTH items, not just skip item 2.
    perform public.create_sales_order(v_store_id, public.business_today(), v_payment_method_id, v_channel_id,
      jsonb_build_array(
        jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 100.00),
        jsonb_build_object('category_id', v_category_id, 'karat_id', v_no_price_karat, 'weight_grams', 1.0000, 'sale_price', 100.00)
      ));
    v_bug := true;
  exception when others then
    raise notice 'OK: 2.7(a) رُفض بند بلا سعر ذهب مسجَّل بدل افتراض 0 (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: قُبلت عملية بيع لعيار بلا سعر ذهب مسجَّل'; end if;
end $$;

reset role;
do $$
declare
  v_store_id uuid; v_orders_before int; v_items_before int; v_orders_after int; v_items_after int;
begin
  select id into v_store_id from public.stores where code = 'S3STA';
  select orders_before, items_before into v_orders_before, v_items_before from s3_atomicity_27;

  select count(*) into v_orders_after from public.sales_orders where store_id = v_store_id;
  select count(*) into v_items_after from public.sales_order_items it
    join public.sales_orders so on so.id = it.sales_order_id where so.store_id = v_store_id;

  assert v_orders_after = v_orders_before, format('ATOMICITY BUG: عدد رؤوس العمليات تغيّر رغم فشل الإنشاء (قبل %s بعد %s)', v_orders_before, v_orders_after);
  assert v_items_after = v_items_before, format('ATOMICITY BUG: عدد بنود العمليات تغيّر رغم فشل الإنشاء — البند الأول لم يُتراجع عنه (قبل %s بعد %s)', v_items_before, v_items_after);
  raise notice 'OK: 2.7(b) فشل بند واحد يُلغي العملية بأكملها ذرّيًا — لا رأس عملية ولا أي بند يُترك خلفه (لا حتى البند الصالح) — تحقَّق عبر قراءة تتجاوز RLS';
end $$;

-- 2.8 Unauthorized create rejected (view-only actor 03 has no sales.create).
set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000003","role":"authenticated"}';
do $$
declare v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid; v_bug boolean := false;
begin
  select id into v_store_id from public.stores where code = 'S3STA';
  select id into v_karat_id from public.karats where code = 'S3K1';
  select id into v_category_id from public.product_categories where code = 's3cat1';
  select id into v_channel_id from public.collection_channels where key = 's3_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's3_pm';

  begin
    perform public.create_sales_order(v_store_id, public.business_today(), v_payment_method_id, v_channel_id,
      jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 100.00)));
    v_bug := true;
  exception when others then
    raise notice 'OK: 2.8 مستخدم "عرض فقط" (sales.view فقط) مُنع من إنشاء عملية بيع (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: مستخدم بلا sales.create استطاع إنشاء عملية بيع'; end if;
end $$;

-- 2.9 Audit: sale.create event was correctly written with the right actor
-- for the worked-example order (2.1), created by actor 02 (Sales Employee).
reset role;
do $$
declare v_order_id uuid; v_count int; v_user_id uuid;
begin
  select order_id into v_order_id from s3_worked_example;
  select count(*) into v_count from public.audit_logs
    where action = 'sale.create' and entity_type = 'sales_order' and entity_id = v_order_id;
  select user_id into v_user_id from public.audit_logs
    where action = 'sale.create' and entity_type = 'sales_order' and entity_id = v_order_id limit 1;
  assert v_count = 1, format('يجب وجود حدث تدقيق sale.create واحد بالضبط لهذه العملية، وجد %s', v_count);
  assert v_user_id = 'd3000000-0000-4000-8000-000000000002', format('حدث sale.create يجب أن يُنسب لمنشئ العملية الفعلي، وجد %s', v_user_id);
  raise notice 'OK: 2.9 حدث تدقيق sale.create مسجَّل بدقة مع نسب الفاعل الصحيح';
end $$;

-- 2.10 Client-supplied fabricated cost/profit fields inside p_items are
-- silently ignored — only category_id/karat_id/weight_grams/sale_price/
-- item_name/description/sku are ever read (spec §6/§24).
set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid;
  v_result record; v_item record;
begin
  select id into v_store_id from public.stores where code = 'S3STA';
  select id into v_karat_id from public.karats where code = 'S3K1';
  select id into v_category_id from public.product_categories where code = 's3cat1';
  select id into v_channel_id from public.collection_channels where key = 's3_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's3_pm';

  select * into v_result from public.create_sales_order(
    v_store_id, public.business_today(), v_payment_method_id, v_channel_id,
    jsonb_build_array(jsonb_build_object(
      'category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 400.00,
      -- fabricated/forged fields a malicious client might inject:
      'gross_profit', 999999.99, 'total_cost', 0.01, 'base_cost', 0.01, 'vat_cost', 0.01,
      'gold_price_per_gram_snapshot', 1.0000, 'manufacturing_fee_per_gram_snapshot', 1.0000
    ))
  );

  create temporary table s3_forged (order_id uuid) on commit drop;
  insert into s3_forged values (v_result.id);
end $$;

reset role;

do $$
declare v_order_id uuid; v_item record;
begin
  select order_id into v_order_id from s3_forged;
  select * into v_item from public.sales_order_items where sales_order_id = v_order_id;
  -- Correct real values for weight 1g, gold 300/g, mfg 10/g, VAT 15%, sale 400:
  -- base=310.00, vat=46.50, total=356.50, gross=43.50 -- NOT the forged 999999.99/0.01.
  if v_item.base_cost <> 310.00 then raise exception 'SECURITY BUG: base_cost تأثر بحقل مزوَّر من العميل — متوقَّع 310.00 وجد %', v_item.base_cost; end if;
  if v_item.total_cost <> 356.50 then raise exception 'SECURITY BUG: total_cost تأثر بحقل مزوَّر من العميل — متوقَّع 356.50 وجد %', v_item.total_cost; end if;
  if v_item.gross_profit <> 43.50 then raise exception 'SECURITY BUG: gross_profit تأثر بحقل مزوَّر من العميل — متوقَّع 43.50 وجد %', v_item.gross_profit; end if;
  if v_item.gold_price_per_gram_snapshot <> 300.0000 then raise exception 'SECURITY BUG: gold_price_per_gram_snapshot تأثر بحقل مزوَّر — متوقَّع 300.0000 وجد %', v_item.gold_price_per_gram_snapshot; end if;
  raise notice 'OK: 2.10 حقول تكلفة/ربح مزوَّرة داخل p_items تُتجاهل تمامًا — كل القيم محسوبة من مصادر رسمية فقط';
end $$;

-- ============================================================================
-- 3. Read RPCs & DB-level profit protection (0062)
-- ============================================================================

-- 3.1 list_sales_orders: profit columns NULL for a non-profit caller,
-- populated correctly for a profit-capable caller — for the SAME order.
set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$
declare v_row record; v_order_id uuid;
begin
  select order_id into v_order_id from s3_worked_example;
  select * into v_row from public.list_sales_orders(p_order_number := (select order_number from s3_worked_example));
  assert v_row.gross_profit is null, 'مستخدم بلا sales.view_profit يجب أن يرى NULL في عمود الربح الإجمالي عبر list_sales_orders';
  assert v_row.net_sales_profit is null, 'مستخدم بلا sales.view_profit يجب أن يرى NULL في صافي الربح عبر list_sales_orders';
  assert v_row.payment_fee_amount is null, 'مستخدم بلا sales.view_profit يجب أن يرى NULL في عمولة الدفع عبر list_sales_orders';
  assert v_row.subtotal = '2000.00', format('المجموع الفرعي (وهو غير حسّاس) يجب أن يظهر دائمًا، وجد %s', v_row.subtotal);
  raise notice 'OK: 3.1(a) list_sales_orders() يخفي أعمدة الربح (NULL) عن مستخدم بلا sales.view_profit';
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v_row record;
begin
  select * into v_row from public.list_sales_orders(p_order_number := (select order_number from s3_worked_example));
  assert v_row.gross_profit = '217.50', format('مستخدم يملك sales.view_profit يجب أن يرى الربح الحقيقي، وجد %s', v_row.gross_profit);
  assert v_row.net_sales_profit = '167.50', format('مستخدم يملك sales.view_profit يجب أن يرى صافي الربح الحقيقي، وجد %s', v_row.net_sales_profit);
  raise notice 'OK: 3.1(b) list_sales_orders() يُظهر الربح الحقيقي لمستخدم يملك sales.view_profit، ويطابق ما أنتجه create_sales_order()';
end $$;

-- 3.2 get_sales_order: profit KEYS ARE ENTIRELY ABSENT (not merely null) for
-- a non-profit caller — a crafted client cannot distinguish "hidden" from
-- "zero" (spec §15/§32).
set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$
declare v_order_id uuid; v_json jsonb; v_item jsonb;
begin
  select order_id into v_order_id from s3_worked_example;
  v_json := public.get_sales_order(v_order_id);
  assert not (v_json ? 'gross_profit'), 'مفتاح gross_profit يجب أن يكون غائبًا تمامًا (لا NULL) عن get_sales_order() لمستخدم بلا sales.view_profit';
  assert not (v_json ? 'net_sales_profit'), 'مفتاح net_sales_profit يجب أن يكون غائبًا تمامًا';
  assert not (v_json ? 'payment_fee_amount'), 'مفتاح payment_fee_amount يجب أن يكون غائبًا تمامًا';
  v_item := v_json -> 'items' -> 0;
  assert not (v_item ? 'total_cost'), 'مفتاح total_cost على مستوى البند يجب أن يكون غائبًا تمامًا';
  assert not (v_item ? 'gross_profit'), 'مفتاح gross_profit على مستوى البند يجب أن يكون غائبًا تمامًا';
  assert not (v_item ? 'gold_price_per_gram_snapshot'), 'مفتاح gold_price_per_gram_snapshot يجب أن يكون غائبًا تمامًا';
  assert (v_json ->> 'subtotal') = '2000.00', 'المجموع الفرعي يجب أن يبقى ظاهرًا (غير حسّاس)';
  raise notice 'OK: 3.2(a) get_sales_order() يحذف مفاتيح الربح تمامًا (لا NULL) لمستخدم بلا sales.view_profit — لا يمكن تمييز "مخفي" عن "صفر"';
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v_order_id uuid; v_json jsonb; v_item jsonb;
begin
  select order_id into v_order_id from s3_worked_example;
  v_json := public.get_sales_order(v_order_id);
  assert (v_json ->> 'gross_profit') = '217.50', 'مستخدم يملك sales.view_profit يجب أن يرى gross_profit الحقيقي عبر get_sales_order()';
  assert (v_json ->> 'net_sales_profit') = '167.50', 'مستخدم يملك sales.view_profit يجب أن يرى net_sales_profit الحقيقي';
  v_item := v_json -> 'items' -> 0;
  assert (v_item ->> 'total_cost') = '1782.50', 'بند العملية يجب أن يُظهر total_cost الحقيقي';
  assert (v_json ->> 'is_day_closed') = 'false', 'اليوم لم يُقفل بعد — is_day_closed يجب أن تكون false';
  raise notice 'OK: 3.2(b) get_sales_order() يُظهر تفاصيل الربح الكاملة لمستخدم يملك sales.view_profit';
end $$;

-- 3.3 preview_sales_order(): writes nothing (order_number sequence
-- untouched by preview, no row persisted) and applies the identical
-- profit-hiding rule.
set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_payment_method_id uuid;
  v_preview jsonb; v_orders_before int; v_orders_after int;
begin
  select id into v_store_id from public.stores where code = 'S3STA';
  select id into v_karat_id from public.karats where code = 'S3K1';
  select id into v_category_id from public.product_categories where code = 's3cat1';
  select id into v_payment_method_id from public.payment_methods where key = 's3_pm';

  select count(*) into v_orders_before from public.sales_orders;

  -- Patch 3.1 item 10: preview_sales_order() now also requires
  -- collection_channel_id (validated exactly like create_sales_order()).
  v_preview := public.preview_sales_order(v_store_id, public.business_today(), v_payment_method_id,
    (select id from public.collection_channels where key = 's3_channel'),
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 5.0000, 'sale_price', 2000.00)));

  select count(*) into v_orders_after from public.sales_orders;

  assert v_orders_after = v_orders_before, 'preview_sales_order() لا يجب أن يكتب أي صف في sales_orders';
  assert (v_preview ->> 'subtotal') = '2000.00', format('معاينة المجموع الفرعي يجب أن تكون 2000.00، وجدت %s', v_preview ->> 'subtotal');
  assert (v_preview ->> 'gross_profit') = '217.50', format('معاينة إجمالي الربح يجب أن تكون 217.50 (نفس صيغة الإنشاء الفعلي)، وجدت %s', v_preview ->> 'gross_profit');
  assert (v_preview ->> 'net_sales_profit') = '167.50', 'معاينة صافي الربح يجب أن تطابق ما سينتجه create_sales_order() فعليًا لنفس المدخلات';
  raise notice 'OK: 3.3(a) preview_sales_order() يحسب نفس قيم create_sales_order() تمامًا دون كتابة أي شيء';
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$
declare v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_payment_method_id uuid; v_preview jsonb;
begin
  select id into v_store_id from public.stores where code = 'S3STA';
  select id into v_karat_id from public.karats where code = 'S3K1';
  select id into v_category_id from public.product_categories where code = 's3cat1';
  select id into v_payment_method_id from public.payment_methods where key = 's3_pm';

  v_preview := public.preview_sales_order(v_store_id, public.business_today(), v_payment_method_id,
    (select id from public.collection_channels where key = 's3_channel'),
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 5.0000, 'sale_price', 2000.00)));

  assert not (v_preview ? 'gross_profit'), 'معاينة عملية بيع لمستخدم بلا sales.view_profit يجب ألا تحتوي مفتاح gross_profit إطلاقًا';
  raise notice 'OK: 3.3(b) preview_sales_order() يخفي مفاتيح الربح لمستخدم بلا sales.view_profit تمامًا مثل get_sales_order()';
end $$;

-- 3.4 Store-scope enforcement on reads: the Store-B-only actor cannot see
-- Store A's worked-example order via list_sales_orders() or get_sales_order().
set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000006","role":"authenticated"}';
do $$
declare v_order_id uuid; v_count int; v_bug boolean := false;
begin
  select order_id into v_order_id from s3_worked_example;

  select count(*) into v_count from public.list_sales_orders(p_order_number := (select order_number from s3_worked_example));
  assert v_count = 0, format('مستخدم مُقيَّد بمتجر ب يجب ألا يرى عملية بيع من متجر أ عبر list_sales_orders، وجد %s صفًا', v_count);

  begin
    perform public.get_sales_order(v_order_id);
    v_bug := true;
  exception when others then
    raise notice 'OK: 3.4 مستخدم مُقيَّد بمتجر ب مُنع من رؤية عملية بيع من متجر أ (list و get) (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: مستخدم مُقيَّد بمتجر ب استطاع الوصول لعملية بيع من متجر أ عبر get_sales_order()'; end if;
end $$;

-- 3.5 Direct SELECT on sales_orders/sales_order_items ALWAYS returns zero
-- rows for `authenticated` — even for the Sales Manager who holds every
-- Sales permission including sales.view_profit — proving there is no
-- direct-read RLS bypass path at all (0059's binding access model).
set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v_count int;
begin
  select count(*) into v_count from public.sales_orders;
  assert v_count = 0, format('SECURITY BUG: SELECT مباشر على sales_orders أعاد %s صفًا رغم عدم وجود أي سياسة RLS للقراءة', v_count);
  select count(*) into v_count from public.sales_order_items;
  assert v_count = 0, format('SECURITY BUG: SELECT مباشر على sales_order_items أعاد %s صفًا رغم عدم وجود أي سياسة RLS للقراءة', v_count);
  raise notice 'OK: 3.5 SELECT مباشر على sales_orders/sales_order_items يعيد صفرًا دائمًا لـ authenticated — حتى لمدير مبيعات يملك sales.view_profit';
end $$;

reset role;

-- ============================================================================
-- 4. update_sales_order (0063; rewritten by Patch 3.1, 0069)
-- ============================================================================
-- As of Patch 3.1 (0069), update_sales_order() no longer DELETEs and
-- re-INSERTs the full item set — items now carry a stable, nullable id (null
-- = new item, an existing id = edit-in-place; an item omitted from the
-- payload is soft-removed, status='removed', never hard-deleted). This
-- section's 4.1 submits an item payload with NO id at all (the pre-Patch-3.1
-- test's original shape), which under the new semantics means "remove the
-- existing item, add one brand-new item" — still a fully valid, commonly-
-- used path (a user replacing a line item entirely), so every assertion
-- below that reads sales_order_items now explicitly filters to
-- status = 'active' (the removed original 5g item is still physically
-- present in the table, by design — see the new stable-identity coverage in
-- sales_integrity_patch_3_1.test.sql for dedicated tests of the id-preserving
-- edit-in-place path, selective snapshot recalculation, and soft-removal
-- itself).

-- Patch 3.2 item 2 — update_sales_order() now requires p_expected_version
-- (optimistic concurrency, 0075). Fetch the order's current row_version via
-- the superuser/table-owner role (sales_orders has zero SELECT RLS policies
-- for authenticated) into a small reusable temp table, exactly the same
-- reset-role pattern already used by the 7.1 atomicity check below.
create temporary table s3_row_version (v bigint) on commit drop;
grant select on s3_row_version to public;

reset role;
do $$
declare v_order_id uuid; v_version bigint;
begin
  select order_id into v_order_id from s3_worked_example;
  select row_version into v_version from public.sales_orders where id = v_order_id;
  delete from s3_row_version;
  insert into s3_row_version values (v_version);
end $$;

-- 4.1 Open-day edit recomputes totals/snapshots correctly: change item
-- weight/sale_price and payment method's own totals must reflect the edit.
set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$
declare
  v_order_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid;
  v_result record; v_old_store_id uuid; v_old_sale_date date; v_version bigint;
begin
  select order_id into v_order_id from s3_worked_example;
  select id into v_karat_id from public.karats where code = 'S3K1';
  select id into v_category_id from public.product_categories where code = 's3cat1';
  select id into v_channel_id from public.collection_channels where key = 's3_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's3_pm';
  select v into v_version from s3_row_version;

  select store_id, sale_date into v_old_store_id, v_old_sale_date from public.sales_orders where id = v_order_id;

  -- New weight 10g (was 5g), same sale_price 2000.00:
  -- base=(300+10)*10=3100.00, vat=465.00, total=3565.00, gross=2000-3565=-1565.00 (a loss, allowed).
  select * into v_result from public.update_sales_order(
    v_order_id, v_payment_method_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 10.0000, 'sale_price', 2000.00)),
    'عميل معدّل', '0511111111', 'ملاحظة معدّلة', null, v_version
  );

  assert v_result.id = v_order_id, 'update_sales_order() يجب أن يعيد نفس id العملية';
end $$;

reset role;

do $$
declare v_order_id uuid; v_order record; v_item record; v_item_count int;
begin
  select order_id into v_order_id from s3_worked_example;
  select * into v_order from public.sales_orders where id = v_order_id;
  select count(*) into v_item_count from public.sales_order_items where sales_order_id = v_order_id and status = 'active';
  select * into v_item from public.sales_order_items where sales_order_id = v_order_id and status = 'active';

  assert v_item_count = 1, format('بعد التعديل بمجموعة بنود جديدة (بلا id)، يجب أن يبقى بند نشط واحد فقط (البند القديم أُزيل بصورة ناعمة)، وجد %s', v_item_count);
  if v_item.base_cost <> 3100.00 then raise exception 'FAIL updated base_cost expected 3100.00 got %', v_item.base_cost; end if;
  if v_item.gross_profit <> -1565.00 then raise exception 'FAIL updated item gross_profit expected -1565.00 (loss) got %', v_item.gross_profit; end if;
  if v_order.subtotal <> 2000.00 then raise exception 'FAIL updated subtotal expected 2000.00 got %', v_order.subtotal; end if;
  if v_order.customer_name <> 'عميل معدّل' then raise exception 'FAIL customer_name not updated'; end if;
  raise notice 'OK: 4.1 تعديل عملية بيع في يوم مفتوح أعاد حساب Snapshots والإجماليات بدقة (بما في ذلك ربح سالب/خسارة)، والبند القديم أُزيل بصورة ناعمة (status=removed) لا حذفًا فعليًا';
end $$;

-- 4.1b Patch 3.1 item 1 — the item replaced in 4.1 above still physically
-- exists, permanently, with status='removed' and removal metadata stamped —
-- never hard-deleted.
reset role;
do $$
declare v_order_id uuid; v_removed_count int; v_removed record;
begin
  select order_id into v_order_id from s3_worked_example;
  select count(*) into v_removed_count from public.sales_order_items where sales_order_id = v_order_id and status = 'removed';
  assert v_removed_count = 1, format('البند الأصلي (5g) يجب أن يبقى موجودًا فعليًا بحالة removed بعد استبداله، وجد %s صف بحالة removed', v_removed_count);

  select * into v_removed from public.sales_order_items where sales_order_id = v_order_id and status = 'removed';
  assert v_removed.weight_grams = 5.0000, format('البند المُزال يجب أن يحتفظ بوزنه الأصلي 5g، وجد %s', v_removed.weight_grams);
  assert v_removed.removed_at is not null, 'removed_at يجب أن يكون مضبوطًا للبند المُزال';
  assert v_removed.removed_by = 'd3000000-0000-4000-8000-000000000002', 'removed_by يجب أن يُنسب للمستخدم الذي نفّذ التعديل فعليًا';
  raise notice 'OK: 4.1b البند الأصلي (5g) لم يُحذف فعليًا — بقي بحالة removed مع removed_at/removed_by صحيحين (لا Hard Delete)';
end $$;

-- 4.2 Unauthorized edit rejected (view-only actor 03 has no sales.edit).
set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000003","role":"authenticated"}';
do $$
declare v_order_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid; v_bug boolean := false;
begin
  select order_id into v_order_id from s3_worked_example;
  select id into v_karat_id from public.karats where code = 'S3K1';
  select id into v_category_id from public.product_categories where code = 's3cat1';
  select id into v_channel_id from public.collection_channels where key = 's3_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's3_pm';

  begin
    perform public.update_sales_order(v_order_id, v_payment_method_id, v_channel_id,
      jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 100.00)));
    v_bug := true;
  exception when others then
    raise notice 'OK: 4.2 مستخدم "عرض فقط" مُنع من تعديل عملية بيع (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: مستخدم بلا sales.edit استطاع تعديل عملية بيع'; end if;
end $$;

-- 4.3 Order not found / outside operable scope rejected (random id, and a
-- real order from a store outside the actor's scope).
set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000006","role":"authenticated"}';
do $$
declare v_order_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid; v_bug boolean := false;
begin
  select order_id into v_order_id from s3_worked_example; -- Store A order; actor 06 is Store-B-only
  select id into v_karat_id from public.karats where code = 'S3K1';
  select id into v_category_id from public.product_categories where code = 's3cat1';
  select id into v_channel_id from public.collection_channels where key = 's3_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's3_pm';

  begin
    perform public.update_sales_order(v_order_id, v_payment_method_id, v_channel_id,
      jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 100.00)));
    v_bug := true;
  exception when others then
    raise notice 'OK: 4.3(a) مستخدم مُقيَّد بمتجر ب مُنع من تعديل عملية بيع تعود لمتجر أ (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: مستخدم مُقيَّد بمتجر ب استطاع تعديل عملية بيع من متجر أ'; end if;

  v_bug := false;
  begin
    perform public.update_sales_order(gen_random_uuid(), v_payment_method_id, v_channel_id,
      jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 100.00)));
    v_bug := true;
  exception when others then
    raise notice 'OK: 4.3(b) رُفض تعديل عملية بيع غير موجودة (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: قُبل تعديل عملية بيع بمعرّف غير موجود'; end if;
end $$;

-- 4.4 Audit: sale.update event captured with correct old_values (pre-edit
-- item snapshot preserved) and new_values (post-edit summary).
reset role;
do $$
declare v_order_id uuid; v_row record;
begin
  select order_id into v_order_id from s3_worked_example;
  select * into v_row from public.audit_logs
    where action = 'sale.update' and entity_type = 'sales_order' and entity_id = v_order_id
    order by created_at desc limit 1;

  assert v_row.id is not null, 'يجب وجود حدث تدقيق sale.update لهذه العملية';
  assert v_row.user_id = 'd3000000-0000-4000-8000-000000000002', 'حدث sale.update يجب أن يُنسب للمستخدم الذي عدّل فعليًا';
  assert (v_row.old_values -> 'items') is not null, 'old_values يجب أن يحتوي حالة البنود قبل التعديل';
  assert jsonb_array_length(v_row.old_values -> 'items') = 1, 'old_values.items يجب أن يعكس بند العملية الأصلي (بند واحد، وزن 5g)';
  assert (v_row.new_values ->> 'subtotal')::numeric = 2000.00, 'new_values.subtotal يجب أن يعكس القيمة بعد التعديل';
  raise notice 'OK: 4.4 حدث تدقيق sale.update يحفظ الحالة قبل وبعد التعديل بدقة مع نسب الفاعل الصحيح';
end $$;

-- ============================================================================
-- 5. Daily Close (0064) + closed-day override interplay
-- ============================================================================

-- 5.1 close_sales_day() success + daily_closing.create audit event.
set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v_store_id uuid; v_closing_id uuid;
begin
  select id into v_store_id from public.stores where code = 'S3STA';
  v_closing_id := public.close_sales_day(v_store_id, public.business_today(), 'إغلاق اختبار');
  assert v_closing_id is not null, 'close_sales_day() يجب أن يعيد id';
  create temporary table s3_closing (id uuid, store_id uuid) on commit drop;
  insert into s3_closing values (v_closing_id, v_store_id);
  raise notice 'OK: 5.1(a) إغلاق يوم المبيعات نجح لمتجر أ';
end $$;

reset role;
do $$
declare v_closing_id uuid; v_count int;
begin
  select id into v_closing_id from s3_closing;
  select count(*) into v_count from public.audit_logs
    where action = 'daily_closing.create' and entity_type = 'daily_closing' and entity_id = v_closing_id;
  assert v_count = 1, format('يجب وجود حدث تدقيق daily_closing.create واحد بالضبط، وجد %s', v_count);
  raise notice 'OK: 5.1(b) حدث تدقيق daily_closing.create مسجَّل بدقة';
end $$;

-- 5.2 Duplicate close on the same (store, business_date) rejected (design
-- decision: reject, not silent no-op — see migration 0064 header).
set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v_store_id uuid; v_bug boolean := false;
begin
  select id into v_store_id from public.stores where code = 'S3STA';
  begin
    perform public.close_sales_day(v_store_id, public.business_today(), 'محاولة إغلاق مكرر');
    v_bug := true;
  exception when others then
    raise notice 'OK: 5.2 رُفضت محاولة إغلاق يوم مغلق بالفعل بدل تجاهلها بصمت (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: قُبل إغلاق مكرر لنفس اليوم/المتجر'; end if;
end $$;

-- 5.3 Future business_date rejected.
do $$
declare v_store_id uuid; v_bug boolean := false;
begin
  select id into v_store_id from public.stores where code = 'S3STA';
  begin
    perform public.close_sales_day(v_store_id, public.business_today() + 1, null);
    v_bug := true;
  exception when others then
    raise notice 'OK: 5.3 رُفض إغلاق تاريخ عمل مستقبلي (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: قُبل إغلاق تاريخ عمل مستقبلي'; end if;
end $$;

-- 5.4 Unauthorized close rejected (Sales Employee 02 has no sales.close_day).
set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$
declare v_store_id uuid; v_bug boolean := false;
begin
  select id into v_store_id from public.stores where code = 'S3STB';
  begin
    perform public.close_sales_day(v_store_id, public.business_today(), null);
    v_bug := true;
  exception when others then
    raise notice 'OK: 5.4 موظف مبيعات بلا sales.close_day مُنع من إغلاق يوم (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: موظف مبيعات بلا sales.close_day استطاع إغلاق يوم'; end if;
end $$;

-- 5.5 Store outside operable scope rejected (Store-B-only actor 06
-- attempting to close Store A).
set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000006","role":"authenticated"}';
do $$
declare v_store_id uuid; v_bug boolean := false;
begin
  select id into v_store_id from public.stores where code = 'S3STA';
  begin
    perform public.close_sales_day(v_store_id, public.business_today(), null);
    v_bug := true;
  exception when others then
    raise notice 'OK: 5.5 مستخدم مُقيَّد بمتجر ب مُنع من إغلاق يوم لمتجر أ (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: مستخدم مُقيَّد بمتجر ب استطاع إغلاق يوم لمتجر أ'; end if;
end $$;

-- 5.6 With Store A now closed for today: creating a NEW sale there without
-- sales.edit_closed_day is rejected; WITH the permission but an empty
-- reason is rejected; WITH the permission and a real reason it succeeds and
-- produces BOTH a sale.create and a sale.closed_day_update audit event.
set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$
declare v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid; v_bug boolean := false;
begin
  select id into v_store_id from public.stores where code = 'S3STA';
  select id into v_karat_id from public.karats where code = 'S3K1';
  select id into v_category_id from public.product_categories where code = 's3cat1';
  select id into v_channel_id from public.collection_channels where key = 's3_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's3_pm';

  begin
    perform public.create_sales_order(v_store_id, public.business_today(), v_payment_method_id, v_channel_id,
      jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 100.00)));
    v_bug := true;
  exception when others then
    raise notice 'OK: 5.6(a) موظف مبيعات بلا sales.edit_closed_day مُنع من إنشاء عملية بيع في يوم مقفل (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: تمت إضافة عملية بيع في يوم مقفل بدون صلاحية sales.edit_closed_day'; end if;
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid; v_bug boolean := false;
begin
  select id into v_store_id from public.stores where code = 'S3STA';
  select id into v_karat_id from public.karats where code = 'S3K1';
  select id into v_category_id from public.product_categories where code = 's3cat1';
  select id into v_channel_id from public.collection_channels where key = 's3_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's3_pm';

  -- Actor 01 DOES hold sales.edit_closed_day, but supplies an empty reason.
  begin
    perform public.create_sales_order(v_store_id, public.business_today(), v_payment_method_id, v_channel_id,
      jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 100.00)),
      null, null, null, '   ');
    v_bug := true;
  exception when others then
    raise notice 'OK: 5.6(b) مُنع إنشاء عملية بيع في يوم مقفل بسبب فارغ/مسافات فقط رغم امتلاك sales.edit_closed_day (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: قُبل إنشاء عملية بيع في يوم مقفل بسبب فارغ'; end if;
end $$;

do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid;
  v_result record;
begin
  select id into v_store_id from public.stores where code = 'S3STA';
  select id into v_karat_id from public.karats where code = 'S3K1';
  select id into v_category_id from public.product_categories where code = 's3cat1';
  select id into v_channel_id from public.collection_channels where key = 's3_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's3_pm';

  select * into v_result from public.create_sales_order(v_store_id, public.business_today(), v_payment_method_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 100.00)),
    null, null, null, 'تصحيح ضروري بعد الإغلاق');

  create temporary table s3_closed_day_order (order_id uuid) on commit drop;
  insert into s3_closed_day_order values (v_result.id);
  raise notice 'OK: 5.6(c) إنشاء عملية بيع في يوم مقفل نجح بسبب صريح مع صلاحية sales.edit_closed_day';
end $$;

reset role;
do $$
declare v_order_id uuid; v_create_count int; v_closed_count int; v_reason text;
begin
  select order_id into v_order_id from s3_closed_day_order;
  select count(*) into v_create_count from public.audit_logs where action = 'sale.create' and entity_type = 'sales_order' and entity_id = v_order_id;
  select count(*), max(reason) into v_closed_count, v_reason from public.audit_logs where action = 'sale.closed_day_update' and entity_type = 'sales_order' and entity_id = v_order_id;

  assert v_create_count = 1, format('يجب وجود حدث sale.create واحد حتى في يوم مقفل، وجد %s', v_create_count);
  assert v_closed_count = 1, format('يجب وجود حدث sale.closed_day_update إضافي منفصل عند الإنشاء في يوم مقفل، وجد %s', v_closed_count);
  assert v_reason = 'تصحيح ضروري بعد الإغلاق', 'حدث sale.closed_day_update يجب أن يحفظ السبب المُدخل بدقة';
  raise notice 'OK: 5.6(d) إنشاء عملية بيع في يوم مقفل ينتج حدثي تدقيق منفصلين (sale.create + sale.closed_day_update) مع حفظ السبب';
end $$;

-- 5.7 update_sales_order on a closed-day order: rejected without a reason,
-- succeeds with one, and produces the same dual sale.update +
-- sale.closed_day_update audit pattern.
--
-- Patch 3.2 item 2 — fetch this order's real row_version first (still
-- required even for the deliberately-failing 5.7(a) call, so that call
-- actually exercises the closed-day-reason check it is meant to test,
-- rather than failing earlier on a missing/placeholder version).
reset role;
do $$
declare v_order_id uuid; v_version bigint;
begin
  select order_id into v_order_id from s3_closed_day_order;
  select row_version into v_version from public.sales_orders where id = v_order_id;
  delete from s3_row_version;
  insert into s3_row_version values (v_version);
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v_order_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid; v_bug boolean := false; v_version bigint;
begin
  select order_id into v_order_id from s3_closed_day_order;
  select id into v_karat_id from public.karats where code = 'S3K1';
  select id into v_category_id from public.product_categories where code = 's3cat1';
  select id into v_channel_id from public.collection_channels where key = 's3_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's3_pm';
  select v into v_version from s3_row_version;

  begin
    perform public.update_sales_order(v_order_id, v_payment_method_id, v_channel_id,
      jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 2.0000, 'sale_price', 200.00)),
      null, null, null, null, v_version);
    v_bug := true;
  exception when others then
    raise notice 'OK: 5.7(a) رُفض تعديل عملية بيع في يوم مقفل بدون سبب (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: قُبل تعديل عملية بيع في يوم مقفل بدون سبب'; end if;

  perform public.update_sales_order(v_order_id, v_payment_method_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 2.0000, 'sale_price', 200.00)),
    null, null, null, 'تصحيح تعديل بعد الإغلاق', v_version);
  raise notice 'OK: 5.7(b) تعديل عملية بيع في يوم مقفل نجح بسبب صريح';
end $$;

reset role;
do $$
declare v_order_id uuid; v_update_count int; v_closed_count int;
begin
  select order_id into v_order_id from s3_closed_day_order;
  select count(*) into v_update_count from public.audit_logs where action = 'sale.update' and entity_type = 'sales_order' and entity_id = v_order_id;
  select count(*) into v_closed_count from public.audit_logs where action = 'sale.closed_day_update' and entity_type = 'sales_order' and entity_id = v_order_id;

  assert v_update_count = 1, format('يجب وجود حدث sale.update واحد بالضبط، وجد %s', v_update_count);
  -- Two closed_day_update events by now: one from 5.6(c) create, one from this edit.
  assert v_closed_count = 2, format('يجب وجود حدثي sale.closed_day_update (إنشاء ثم تعديل)، وجد %s', v_closed_count);
  raise notice 'OK: 5.7(c) تعديل عملية بيع في يوم مقفل ينتج حدثي تدقيق منفصلين (sale.update + sale.closed_day_update)';
end $$;

-- ============================================================================
-- 6. Security / bypass attempts
-- ============================================================================

-- 6.1 Direct INSERT into sales_orders/sales_order_items blocked by RLS even
-- for the full-permission Sales Manager (already proven for SELECT in 3.5;
-- this proves the write side too).
set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v_store_id uuid; v_bug boolean := false;
begin
  select id into v_store_id from public.stores where code = 'S3STA';
  begin
    insert into public.sales_orders (
      order_number, store_id, sale_date, salesperson_id, payment_method_id, collection_channel_id,
      payment_fee_version_id, payment_fee_percentage_snapshot, payment_fee_fixed_snapshot,
      payment_fee_amount, subtotal, gross_profit, net_sales_profit
    ) values (
      'SALE-FORGED001', v_store_id, public.business_today(), 'd3000000-0000-4000-8000-000000000001',
      (select id from public.payment_methods where key = 's3_pm'),
      (select id from public.collection_channels where key = 's3_channel'),
      (select id from public.payment_method_fee_versions where payment_method_id = (select id from public.payment_methods where key = 's3_pm') limit 1),
      2.5, 0, 0, 0, 0, 0
    );
    v_bug := true;
  exception when others then
    raise notice 'OK: 6.1 إدخال مباشر في sales_orders مرفوض حتى لمدير مبيعات يملك كل صلاحيات المبيعات (لا توجد سياسة RLS للكتابة إطلاقًا) (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: تم قبول إدخال مباشر في sales_orders رغم عدم وجود أي سياسة RLS للكتابة'; end if;
end $$;

-- 6.2 daily_closings DOES have a direct SELECT policy (0059 — no
-- profit-sensitive data) — confirm it correctly gates by sales.view + store
-- visibility (the Store-B-only actor cannot see Store A's closing row).
set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000006","role":"authenticated"}';
do $$
declare v_count int;
begin
  select count(*) into v_count from public.daily_closings where store_id = (select id from public.stores where code = 'S3STA');
  assert v_count = 0, format('مستخدم مُقيَّد بمتجر ب يجب ألا يرى صف إغلاق يوم لمتجر أ عبر SELECT مباشر (له سياسة SELECT)، وجد %s', v_count);
  raise notice 'OK: 6.2(a) سياسة SELECT المباشرة على daily_closings تُطبّق نطاق رؤية المتجر بشكل صحيح';
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v_count int;
begin
  select count(*) into v_count from public.daily_closings where store_id = (select id from public.stores where code = 'S3STA');
  assert v_count = 1, format('مدير المبيعات (نطاق الكل) يجب أن يرى صف إغلاق يوم متجر أ عبر SELECT مباشر، وجد %s', v_count);
  raise notice 'OK: 6.2(b) مدير مبيعات بنطاق "الكل" يرى صف إغلاق اليوم مباشرة كما هو متوقَّع';
end $$;

-- 6.3 Profit visibility is independent of ownership — actor 05 (view +
-- view_profit only, never created anything) sees profit on an order created
-- by someone else; actor 02 (created the order, no view_profit) cannot see
-- its own order's profit.
set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000005","role":"authenticated"}';
do $$
declare v_order_id uuid; v_json jsonb;
begin
  select order_id into v_order_id from s3_worked_example; -- created by actor 02
  v_json := public.get_sales_order(v_order_id);
  assert (v_json ? 'gross_profit'), 'مستخدم يملك sales.view_profit يجب أن يرى الربح حتى لعملية أنشأها مستخدم آخر';
  raise notice 'OK: 6.3 رؤية الربح مرتبطة بالصلاحية فقط، لا بمن أنشأ العملية';
end $$;

reset role;

-- ============================================================================
-- 7. Atomicity (additional to 2.7 above)
-- ============================================================================

-- 7.1 A failed update_sales_order (invalid item mid-list) leaves the
-- original order/items COMPLETELY untouched — proves that update_sales_
-- order()'s per-item processing (0069: new items inserted, soft-removal of
-- the old set applied only after the full loop succeeds) rolls back
-- cleanly via the calling savepoint, never leaving zero items or a
-- partially-applied soft-removal.
--
-- As in 2.7, the before/after item snapshot MUST be read via the superuser/
-- table-owner role (RLS bypassed) — sales_order_items has zero SELECT
-- policies for `authenticated`, so reading it as `authenticated` would
-- always see 0 rows and make the comparison meaningless.
reset role;
do $$
declare v_order_id uuid; v_before_items int; v_before_weight numeric; v_version bigint;
begin
  select order_id into v_order_id from s3_closed_day_order;
  select count(*), max(weight_grams) into v_before_items, v_before_weight
    from public.sales_order_items where sales_order_id = v_order_id;

  create temporary table s3_atomicity_71 (before_items int, before_weight numeric) on commit drop;
  insert into s3_atomicity_71 values (v_before_items, v_before_weight);

  -- Patch 3.2 item 2 — fetch the real row_version too, so the call below
  -- actually reaches (and exercises) the item-validation rollback path
  -- instead of failing earlier on a missing version.
  select row_version into v_version from public.sales_orders where id = v_order_id;
  delete from s3_row_version;
  insert into s3_row_version values (v_version);
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"d3000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_order_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid;
  v_inactive_karat uuid; v_bug boolean := false; v_version bigint;
begin
  select order_id into v_order_id from s3_closed_day_order;
  select id into v_karat_id from public.karats where code = 'S3K1';
  select id into v_category_id from public.product_categories where code = 's3cat1';
  select id into v_channel_id from public.collection_channels where key = 's3_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's3_pm';
  select id into v_inactive_karat from public.karats where code = 'S3K_INACTIVE';
  select v into v_version from s3_row_version;

  begin
    -- This order's day is closed -- must also supply a reason, otherwise the
    -- closed-day check itself would raise first and this wouldn't actually
    -- exercise the item-validation rollback path.
    perform public.update_sales_order(v_order_id, v_payment_method_id, v_channel_id,
      jsonb_build_array(
        jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 99.0000, 'sale_price', 9999.00),
        jsonb_build_object('category_id', v_category_id, 'karat_id', v_inactive_karat, 'weight_grams', 1.0000, 'sale_price', 100.00)
      ),
      null, null, null, 'محاولة تعديل بها بند غير صالح', v_version
    );
    v_bug := true;
  exception when others then
    raise notice 'OK: 7.1(a) رُفض تعديل بسبب بند بعيار غير نشط (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: قُبل تعديل بعيار غير نشط في أحد البنود'; end if;
end $$;

reset role;
do $$
declare
  v_order_id uuid; v_before_items int; v_before_weight numeric; v_after_items int; v_after_weight numeric;
begin
  select order_id into v_order_id from s3_closed_day_order;
  select before_items, before_weight into v_before_items, v_before_weight from s3_atomicity_71;

  select count(*), max(weight_grams) into v_after_items, v_after_weight
    from public.sales_order_items where sales_order_id = v_order_id;

  assert v_after_items = v_before_items, format('ATOMICITY BUG: عدد بنود العملية تغيّر رغم فشل التعديل (قبل %s بعد %s)', v_before_items, v_after_items);
  assert v_after_weight = v_before_weight, format('ATOMICITY BUG: وزن البند الأصلي تغيّر رغم فشل التعديل (قبل %s بعد %s) — DELETE+INSERT لم يتراجع بالكامل', v_before_weight, v_after_weight);
  raise notice 'OK: 7.1(b) فشل التعديل بسبب بند غير صالح لم يترك العملية بلا بنود ولا بحالة جزئية — الحالة الأصلية سليمة تمامًا — تحقَّق عبر قراءة تتجاوز RLS';
end $$;

-- ============================================================================
-- Done.
-- ============================================================================
do $$ begin raise notice 'OK: ALL Sales Core (Phase 3) integration tests passed'; end $$;

rollback;
