-- ============================================================================
-- Integration test: Phase 3 — Sales Integrity Patch 3.1 (migrations 0065-0072)
-- Part 1 — single-session scenarios (spec item 13, tests A-G and L)
-- ============================================================================
-- Covers: stable item identity across edits (A), selective snapshot
-- recalculation (B/C/D), soft-removal never hard-deletes (E), historical
-- inactive-reference tolerance (F), the audit_logs profit-leak fix (G), and
-- the rounding-reconciliation boundary case (L).
--
-- Genuine multi-session concurrency scenarios (H — Daily Close race, I —
-- lost update, J — torn financial snapshot, K — order number uniqueness
-- under true parallel dispatch) are NOT in this file — they need real
-- separate database sessions to mean anything, which this file's
-- begin/rollback-per-run safety model cannot provide. See the companion
-- file supabase/tests/sales_integrity_patch_3_1_concurrency.test.sql (uses
-- dblink to open genuinely separate sessions; NOT rollback-safe against a
-- shared database — read that file's own header before running it).
--
-- Requires migrations 0001-0072 + supabase/seed.sql to already be applied.
-- Safe to run against a real database: everything happens inside a
-- transaction that is ALWAYS rolled back at the end.
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/sales_integrity_patch_3_1.test.sql
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0. Setup — actors, stores, master data. Prefix 'd4...'/'p31' is unused by
-- any other test file's fixtures.
--   01 = Sales Manager — full Sales permission set + master-data manage +
--        audit_logs.view + sales.view_profit. store_access_scope='all'.
--   02 = Audit-only viewer — audit_logs.view ONLY (no sales.*, no
--        sales.view_profit at all) — for scenario G.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('d4000000-0000-4000-8000-000000000001', 'test-p31-manager@example.invalid'),
  ('d4000000-0000-4000-8000-000000000002', 'test-p31-audit-noprofit@example.invalid');

update public.profiles set full_name = 'Test P31 Sales Manager', status = 'active', store_access_scope = 'all'
  where id = 'd4000000-0000-4000-8000-000000000001';
update public.profiles set full_name = 'Test P31 Audit Viewer (No Profit)', status = 'active', store_access_scope = 'all'
  where id = 'd4000000-0000-4000-8000-000000000002';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'd4000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in (
    'stores.view', 'stores.create',
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

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'd4000000-0000-4000-8000-000000000002', id, 'grant' from public.permissions
  where key in ('audit_logs.view');

set role authenticated;
set local request.jwt.claims = '{"sub":"d4000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_a uuid; v_category_b uuid;
  v_channel_a uuid; v_channel_b uuid; v_pm_a uuid; v_pm_b uuid;
begin
  insert into public.stores (code, name_ar, status) values ('P31ST', 'متجر تكامل 3.1', 'active') returning id into v_store_id;
  insert into public.karats (code, name_ar, sort_order, status) values ('P31K1', 'عيار تكامل 3.1', 981, 'active') returning id into v_karat_id;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('p31cat_a', 'تصنيف أ 3.1', 981, 'active') returning id into v_category_a;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('p31cat_b', 'تصنيف ب 3.1', 982, 'active') returning id into v_category_b;
  insert into public.collection_channels (key, name_ar, sort_order, status) values ('p31_channel_a', 'قناة أ 3.1', 981, 'active') returning id into v_channel_a;
  insert into public.collection_channels (key, name_ar, sort_order, status) values ('p31_channel_b', 'قناة ب 3.1', 982, 'active') returning id into v_channel_b;
  insert into public.payment_methods (key, name_ar, fee_model, sort_order, status) values ('p31_pm_a', 'طريقة دفع أ 3.1', 'percentage', 981, 'active') returning id into v_pm_a;
  insert into public.payment_methods (key, name_ar, fee_model, sort_order, status) values ('p31_pm_b', 'طريقة دفع ب 3.1', 'fixed', 982, 'active') returning id into v_pm_b;

  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 300.0000, 'd4000000-0000-4000-8000-000000000001');

  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, public.business_today(), 'p31 fixture');
  perform public.create_payment_method_fee_version(v_pm_a, 2.5, 0, public.business_today(), 'p31 fixture');
  perform public.create_payment_method_fee_version(v_pm_b, 0, 15.00, public.business_today(), 'p31 fixture');
end $$;

reset role;

-- Patch 3.2 item 2 — update_sales_order() now requires p_expected_version
-- (optimistic concurrency, 0075). This small reusable temp table holds the
-- current row_version for whichever order the next update call targets;
-- populated via a `reset role` fetch (sales_orders has zero SELECT RLS
-- policies for `authenticated`, 0059) immediately before each
-- `set role authenticated` block that calls update_sales_order(), then read
-- inside that block and passed through as the trailing argument.
create temporary table p31_row_version (v bigint) on commit drop;
grant select on p31_row_version to authenticated;

-- ============================================================================
-- A) Stable Item Identity — metadata-only edit leaves ids/snapshots/profits
-- untouched.
-- ============================================================================
set role authenticated;
set local request.jwt.claims = '{"sub":"d4000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_result record;
begin
  select id into v_store_id from public.stores where code = 'P31ST';
  select id into v_karat_id from public.karats where code = 'P31K1';
  select id into v_category_id from public.product_categories where code = 'p31cat_a';
  select id into v_channel_id from public.collection_channels where key = 'p31_channel_a';
  select id into v_pm_id from public.payment_methods where key = 'p31_pm_a';

  select * into v_result from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(
      jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 400.00),
      jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 2.0000, 'sale_price', 800.00)
    )
  );

  create temporary table p31_order_a (order_id uuid) on commit drop;
  insert into p31_order_a values (v_result.id);
end $$;

reset role;
do $$
declare v_order_id uuid;
begin
  select order_id into v_order_id from p31_order_a;
  create temporary table p31_a_before as
    select id, line_no, category_id, karat_id, weight_grams, sale_price, gold_price_per_gram_snapshot, total_cost, gross_profit, updated_at
    from public.sales_order_items where sales_order_id = v_order_id and status = 'active' order by line_no;
end $$;
-- Created while superuser/table-owner (reset role, bypassing sales_order_
-- items' RLS) but needed again below under `set role authenticated` to
-- build the update payload — an explicit grant is required for that
-- cross-role read (unlike the reverse direction, which superuser can always
-- do regardless of grants).
grant select on p31_a_before to authenticated;

do $$
declare v_order_id uuid; v_version bigint;
begin
  select order_id into v_order_id from p31_order_a;
  select row_version into v_version from public.sales_orders where id = v_order_id;
  delete from p31_row_version;
  insert into p31_row_version values (v_version);
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"d4000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_order_id uuid; v_category_id uuid; v_karat_id uuid; v_channel_id uuid; v_pm_id uuid;
  r record; v_result record; v_version bigint;
begin
  select order_id into v_order_id from p31_order_a;
  select id into v_category_id from public.product_categories where code = 'p31cat_a';
  select id into v_karat_id from public.karats where code = 'P31K1';
  select id into v_channel_id from public.collection_channels where key = 'p31_channel_a';
  select id into v_pm_id from public.payment_methods where key = 'p31_pm_a';
  select v into v_version from p31_row_version;

  -- Resubmit the SAME two items with their real ids and identical financial
  -- fields — only order-level customer_name changes.
  -- Built from the RLS-bypassing snapshot taken above (p31_a_before), NOT
  -- from a direct SELECT on sales_order_items here — that table has zero
  -- SELECT RLS policies for `authenticated` (0059) and would silently
  -- return zero rows under this role, exactly like every other Sales Read
  -- in this project.
  select * into v_result from public.update_sales_order(
    v_order_id, v_pm_id, v_channel_id,
    (
      select jsonb_agg(jsonb_build_object(
        'id', b.id, 'category_id', b.category_id, 'karat_id', b.karat_id,
        'weight_grams', b.weight_grams, 'sale_price', b.sale_price
      ) order by b.line_no)
      from p31_a_before b
    ),
    'عميل بعد تعديل البيانات فقط', null, null, null, v_version
  );
  assert v_result.id = v_order_id, 'update_sales_order() يجب أن يعيد نفس id العملية';
end $$;

reset role;
do $$
declare v_order_id uuid; v_after_count int; v_before_count int; v_customer_name text;
begin
  select order_id into v_order_id from p31_order_a;

  select count(*) into v_before_count from p31_a_before;
  select count(*) into v_after_count from public.sales_order_items where sales_order_id = v_order_id and status = 'active';
  assert v_after_count = v_before_count, format('عدد البنود النشطة يجب ألا يتغيّر بعد تعديل بيانات وصفية فقط، قبل %s بعد %s', v_before_count, v_after_count);

  -- Every before-row must still exist, byte-for-byte identical on every
  -- financial/snapshot/timestamp column (no UPDATE at all should have
  -- touched these rows).
  if exists (
    select 1 from p31_a_before b
    where not exists (
      select 1 from public.sales_order_items it
      where it.id = b.id and it.status = 'active'
        and it.weight_grams = b.weight_grams and it.sale_price = b.sale_price
        and it.gold_price_per_gram_snapshot = b.gold_price_per_gram_snapshot
        and it.total_cost = b.total_cost and it.gross_profit = b.gross_profit
        and it.updated_at = b.updated_at
    )
  ) then
    raise exception 'FAIL: بند واحد على الأقل تغيّر (id/snapshot/cost/profit/updated_at) رغم أن التعديل كان بيانات وصفية فقط';
  end if;

  select customer_name into v_customer_name from public.sales_orders where id = v_order_id;
  assert v_customer_name = 'عميل بعد تعديل البيانات فقط', 'customer_name يجب أن يتحدّث فعليًا';

  raise notice 'OK: A نفس معرّفات البنود ونفس اللقطات ونفس الأرباح ونفس updated_at بعد تعديل بيانات وصفية فقط (customer_name)';
end $$;

-- ============================================================================
-- B) Master Data changed + metadata edit — original snapshot must NOT drift.
-- ============================================================================
set role authenticated;
set local request.jwt.claims = '{"sub":"d4000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_result record;
begin
  select id into v_store_id from public.stores where code = 'P31ST';
  select id into v_karat_id from public.karats where code = 'P31K1';
  select id into v_category_id from public.product_categories where code = 'p31cat_a';
  select id into v_channel_id from public.collection_channels where key = 'p31_channel_a';
  select id into v_pm_id from public.payment_methods where key = 'p31_pm_a';

  select * into v_result from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 400.00))
  );
  create temporary table p31_order_b (order_id uuid) on commit drop;
  insert into p31_order_b values (v_result.id);
end $$;

reset role;
do $$
declare v_order_id uuid;
begin
  select order_id into v_order_id from p31_order_b;
  create temporary table p31_b_before as
    select id, category_id, karat_id, weight_grams, sale_price, gold_price_per_gram_snapshot, category_name_ar_snapshot, total_cost, gross_profit
    from public.sales_order_items where sales_order_id = v_order_id and status = 'active';
end $$;
grant select on p31_b_before to authenticated;

-- Correct the gold price for the SAME date (a later price correction) and
-- rename the category — neither must affect the already-saved snapshot.
set role authenticated;
set local request.jwt.claims = '{"sub":"d4000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v_karat_id uuid; v_category_id uuid;
begin
  select id into v_karat_id from public.karats where code = 'P31K1';
  select id into v_category_id from public.product_categories where code = 'p31cat_a';
  perform public.save_daily_gold_price(public.business_today(), v_karat_id, 350.0000, 'تصحيح سعر لاحق');
end $$;

reset role;
update public.product_categories set name_ar = 'تصنيف أ 3.1 (بعد إعادة التسمية)' where code = 'p31cat_a';

do $$
declare v_order_id uuid; v_version bigint;
begin
  select order_id into v_order_id from p31_order_b;
  select row_version into v_version from public.sales_orders where id = v_order_id;
  delete from p31_row_version;
  insert into p31_row_version values (v_version);
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"d4000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_order_id uuid; v_category_id uuid; v_karat_id uuid; v_channel_id uuid; v_pm_id uuid; v_result record; v_version bigint;
begin
  select order_id into v_order_id from p31_order_b;
  select id into v_category_id from public.product_categories where code = 'p31cat_a';
  select id into v_karat_id from public.karats where code = 'P31K1';
  select id into v_channel_id from public.collection_channels where key = 'p31_channel_a';
  select id into v_pm_id from public.payment_methods where key = 'p31_pm_a';
  select v into v_version from p31_row_version;

  select * into v_result from public.update_sales_order(
    v_order_id, v_pm_id, v_channel_id,
    (
      select jsonb_agg(jsonb_build_object('id', b.id, 'category_id', b.category_id, 'karat_id', b.karat_id, 'weight_grams', b.weight_grams, 'sale_price', b.sale_price))
      from p31_b_before b
    ),
    null, null, 'ملاحظة فقط بعد تصحيح السعر وإعادة تسمية التصنيف', null, v_version
  );
end $$;

reset role;
do $$
declare v_order_id uuid; v_before record; v_after record;
begin
  select order_id into v_order_id from p31_order_b;
  select * into v_before from p31_b_before;
  select * into v_after from public.sales_order_items where sales_order_id = v_order_id and status = 'active';

  assert v_after.id = v_before.id, 'معرّف البند يجب ألا يتغيّر';
  assert v_after.gold_price_per_gram_snapshot = v_before.gold_price_per_gram_snapshot,
    format('لقطة سعر الذهب يجب أن تبقى القديمة (%s) رغم تصحيح السعر لاحقًا، وجد %s', v_before.gold_price_per_gram_snapshot, v_after.gold_price_per_gram_snapshot);
  assert v_after.gold_price_per_gram_snapshot = 300.0000, format('لقطة سعر الذهب المتوقعة 300.0000، وجد %s', v_after.gold_price_per_gram_snapshot);
  assert v_after.category_name_ar_snapshot = v_before.category_name_ar_snapshot,
    format('لقطة اسم التصنيف يجب أن تبقى القديمة (%s) رغم إعادة التسمية، وجد %s', v_before.category_name_ar_snapshot, v_after.category_name_ar_snapshot);
  assert v_after.total_cost = v_before.total_cost, 'total_cost يجب ألا يتغيّر';
  assert v_after.gross_profit = v_before.gross_profit, 'gross_profit يجب ألا يتغيّر';

  raise notice 'OK: B لقطة سعر الذهب ولقطة اسم التصنيف بقيتا كما كانتا رغم تصحيح لاحق للسعر وإعادة تسمية للتصنيف — التعديل كان بيانات وصفية فقط';
end $$;

-- ============================================================================
-- C) Payment Method changed only — item snapshots/ids untouched; only the
-- payment fee snapshot + net_sales_profit change.
-- ============================================================================
reset role;
do $$
declare v_order_id uuid;
begin
  select order_id into v_order_id from p31_order_b;
  create temporary table p31_c_before as
    select it.id as item_id, it.gross_profit as item_gross_profit, it.total_cost,
           so.gross_profit as order_gross_profit, so.subtotal
    from public.sales_order_items it join public.sales_orders so on so.id = it.sales_order_id
    where it.sales_order_id = v_order_id and it.status = 'active';
end $$;

do $$
declare v_order_id uuid; v_version bigint;
begin
  select order_id into v_order_id from p31_order_b;
  select row_version into v_version from public.sales_orders where id = v_order_id;
  delete from p31_row_version;
  insert into p31_row_version values (v_version);
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"d4000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_order_id uuid; v_category_id uuid; v_karat_id uuid; v_channel_id uuid; v_pm_b_id uuid; v_result record; v_version bigint;
begin
  select order_id into v_order_id from p31_order_b;
  select id into v_category_id from public.product_categories where code = 'p31cat_a';
  select id into v_karat_id from public.karats where code = 'P31K1';
  select id into v_channel_id from public.collection_channels where key = 'p31_channel_a';
  select id into v_pm_b_id from public.payment_methods where key = 'p31_pm_b'; -- fixed 15.00 fee, was percentage 2.5%+0
  select v into v_version from p31_row_version;

  -- Item is unchanged since section B (a metadata-only edit) — p31_b_before
  -- still accurately reflects its current category/karat/weight/sale_price.
  select * into v_result from public.update_sales_order(
    v_order_id, v_pm_b_id, v_channel_id,
    (
      select jsonb_agg(jsonb_build_object('id', b.id, 'category_id', b.category_id, 'karat_id', b.karat_id, 'weight_grams', b.weight_grams, 'sale_price', b.sale_price))
      from p31_b_before b
    ),
    null, null, null, null, v_version
  );
end $$;

reset role;
do $$
declare
  v_order_id uuid; v_before record; v_after_item record; v_after_order record;
begin
  select order_id into v_order_id from p31_order_b;
  select * into v_before from p31_c_before;
  select * into v_after_item from public.sales_order_items where sales_order_id = v_order_id and status = 'active';
  select * into v_after_order from public.sales_orders where id = v_order_id;

  assert v_after_item.id = v_before.item_id, 'معرّف البند يجب ألا يتغيّر عند تغيير طريقة الدفع فقط';
  assert v_after_item.gross_profit = v_before.item_gross_profit, 'ربح البند يجب ألا يتغيّر عند تغيير طريقة الدفع فقط';
  assert v_after_item.total_cost = v_before.total_cost, 'تكلفة البند يجب ألا تتغيّر عند تغيير طريقة الدفع فقط';
  assert v_after_order.gross_profit = v_before.order_gross_profit, 'إجمالي ربح العملية يجب ألا يتغيّر (البنود لم تتغيّر)';
  assert v_after_order.payment_method_id = (select id from public.payment_methods where key = 'p31_pm_b'), 'طريقة الدفع يجب أن تتحدّث فعليًا';

  -- New method is fixed 15.00 fee (0% + 15.00), vs old 2.5% of subtotal(400)=10.00.
  assert v_after_order.payment_fee_amount = 15.00, format('عمولة الدفع الجديدة يجب أن تكون 15.00 (رسم ثابت)، وجد %s', v_after_order.payment_fee_amount);
  assert v_after_order.net_sales_profit = round(v_after_order.gross_profit - 15.00, 2),
    format('صافي الربح يجب أن يعكس عمولة الدفع الجديدة فقط، متوقَّع %s وجد %s', round(v_after_order.gross_profit - 15.00, 2), v_after_order.net_sales_profit);

  raise notice 'OK: C تغيير طريقة الدفع فقط لم يمسّ معرّفات/لقطات/أرباح البنود — فقط لقطة عمولة الدفع وصافي الربح تحدّثا';
end $$;

-- ============================================================================
-- D) One item's financial input changed — only that item's snapshots
-- recompute; the other item is fully untouched; totals correct.
-- ============================================================================
set role authenticated;
set local request.jwt.claims = '{"sub":"d4000000-0000-4000-8000-000000000001","role":"authenticated"}';
-- Dedicated karat + gold price for section D — deliberately NOT P31K1
-- (whose price section B intentionally corrected 300 -> 350 as part of
-- ITS test), so this section's expected numbers stay fixed and
-- order-independent regardless of what earlier sections did to P31K1.
do $$
declare v_karat_id uuid;
begin
  insert into public.karats (code, name_ar, sort_order, status) values ('P31K_D', 'عيار قسم D 3.1', 984, 'active') returning id into v_karat_id;
  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 300.0000, 'd4000000-0000-4000-8000-000000000001');
  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, public.business_today(), 'p31 section D fixture');
end $$;

do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid; v_result record;
begin
  select id into v_store_id from public.stores where code = 'P31ST';
  select id into v_karat_id from public.karats where code = 'P31K_D';
  select id into v_category_id from public.product_categories where code = 'p31cat_a';
  select id into v_channel_id from public.collection_channels where key = 'p31_channel_a';
  select id into v_pm_id from public.payment_methods where key = 'p31_pm_a';

  select * into v_result from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(
      jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 400.00),
      jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 2.0000, 'sale_price', 800.00)
    )
  );
  create temporary table p31_order_d (order_id uuid) on commit drop;
  insert into p31_order_d values (v_result.id);
end $$;

reset role;
do $$
declare v_order_id uuid;
begin
  select order_id into v_order_id from p31_order_d;
  create temporary table p31_d_before as
    select id, line_no, weight_grams, total_cost, gross_profit, gold_price_per_gram_snapshot, updated_at
    from public.sales_order_items where sales_order_id = v_order_id and status = 'active' order by line_no;
end $$;
grant select on p31_d_before to authenticated;

do $$
declare v_order_id uuid; v_version bigint;
begin
  select order_id into v_order_id from p31_order_d;
  select row_version into v_version from public.sales_orders where id = v_order_id;
  delete from p31_row_version;
  insert into p31_row_version values (v_version);
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"d4000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_order_id uuid; v_category_id uuid; v_karat_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_item1_id uuid; v_item2_id uuid; v_result record; v_version bigint;
begin
  select order_id into v_order_id from p31_order_d;
  select id into v_category_id from public.product_categories where code = 'p31cat_a';
  select id into v_karat_id from public.karats where code = 'P31K_D';
  select id into v_channel_id from public.collection_channels where key = 'p31_channel_a';
  select id into v_pm_id from public.payment_methods where key = 'p31_pm_a';
  select id into v_item1_id from p31_d_before where line_no = 1;
  select id into v_item2_id from p31_d_before where line_no = 2;
  select v into v_version from p31_row_version;

  -- Item 1 unchanged; item 2's weight changes 2.0000 -> 3.0000.
  select * into v_result from public.update_sales_order(
    v_order_id, v_pm_id, v_channel_id,
    jsonb_build_array(
      jsonb_build_object('id', v_item1_id, 'category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 400.00),
      jsonb_build_object('id', v_item2_id, 'category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 3.0000, 'sale_price', 800.00)
    ),
    null, null, null, null, v_version
  );
end $$;

reset role;
do $$
declare
  v_order_id uuid; v_item1_before record; v_item2_before record; v_item1_after record; v_item2_after record; v_order record;
begin
  select order_id into v_order_id from p31_order_d;
  select * into v_item1_before from p31_d_before where line_no = 1;
  select * into v_item2_before from p31_d_before where line_no = 2;
  select * into v_item1_after from public.sales_order_items where id = v_item1_before.id and status = 'active';
  select * into v_item2_after from public.sales_order_items where id = v_item2_before.id and status = 'active';
  select * into v_order from public.sales_orders where id = v_order_id;

  assert v_item1_after.updated_at = v_item1_before.updated_at, 'FAIL: البند 1 (غير المعدَّل) تغيّر updated_at رغم عدم تغيير مدخلاته المالية';
  assert v_item1_after.total_cost = v_item1_before.total_cost, 'FAIL: تكلفة البند 1 تغيّرت رغم عدم تعديله';
  assert v_item1_after.gross_profit = v_item1_before.gross_profit, 'FAIL: ربح البند 1 تغيّر رغم عدم تعديله';

  assert v_item2_after.id = v_item2_before.id, 'البند 2 يجب أن يحتفظ بنفس المعرّف';
  assert v_item2_after.weight_grams = 3.0000, format('وزن البند 2 يجب أن يتحدّث إلى 3.0000، وجد %s', v_item2_after.weight_grams);
  -- New base=(300+10)*3=930.00, vat=139.50, total=1069.50, gross=800-1069.50=-269.50.
  assert v_item2_after.total_cost = 1069.50, format('تكلفة البند 2 بعد التعديل يجب أن تكون 1069.50، وجد %s', v_item2_after.total_cost);
  assert v_item2_after.gross_profit = -269.50, format('ربح البند 2 بعد التعديل يجب أن يكون -269.50، وجد %s', v_item2_after.gross_profit);

  assert v_order.subtotal = 1200.00, format('المجموع الفرعي يجب أن يكون 1200.00، وجد %s', v_order.subtotal);
  assert v_order.gross_profit = (v_item1_after.gross_profit + v_item2_after.gross_profit), 'إجمالي ربح العملية يجب أن يطابق مجموع البندين بعد التعديل الجزئي';

  raise notice 'OK: D تعديل مدخل مالي لبند واحد فقط أعاد حساب لقطاته هو فقط — البند الآخر بقي دون أي مساس (حتى updated_at)، والإجماليات صحيحة';
end $$;

-- ============================================================================
-- E) Remove item — soft-removed, never deleted, id never reused, excluded
-- from Reads/Totals.
-- ============================================================================
do $$
declare v_order_id uuid; v_version bigint;
begin
  select order_id into v_order_id from p31_order_d;
  select row_version into v_version from public.sales_orders where id = v_order_id;
  delete from p31_row_version;
  insert into p31_row_version values (v_version);
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"d4000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_order_id uuid; v_category_id uuid; v_karat_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_item1_id uuid; v_result record; v_json jsonb; v_version bigint;
begin
  select order_id into v_order_id from p31_order_d;
  select id into v_category_id from public.product_categories where code = 'p31cat_a';
  select id into v_karat_id from public.karats where code = 'P31K1';
  select id into v_channel_id from public.collection_channels where key = 'p31_channel_a';
  select id into v_pm_id from public.payment_methods where key = 'p31_pm_a';
  select id into v_item1_id from p31_d_before where line_no = 1;
  select v into v_version from p31_row_version;

  -- Keep only item 1 — item 2 is omitted entirely.
  select * into v_result from public.update_sales_order(
    v_order_id, v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('id', v_item1_id, 'category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 400.00)),
    null, null, null, null, v_version
  );

  v_json := public.get_sales_order(v_order_id);
  assert jsonb_array_length(v_json -> 'items') = 1, format('get_sales_order() يجب أن يُظهر بندًا نشطًا واحدًا فقط بعد الإزالة، وجد %s', jsonb_array_length(v_json -> 'items'));
end $$;

reset role;
do $$
declare
  v_order_id uuid; v_item2_id uuid; v_removed record; v_active_count int; v_order record;
begin
  select order_id into v_order_id from p31_order_d;
  select id into v_item2_id from p31_d_before where line_no = 2;

  select * into v_removed from public.sales_order_items where id = v_item2_id;
  assert v_removed.id is not null, 'FAIL: البند المُزال حُذف فعليًا من قاعدة البيانات — يجب أن يبقى موجودًا (لا Hard Delete)';
  assert v_removed.status = 'removed', 'حالة البند المُزال يجب أن تكون removed';
  assert v_removed.removed_at is not null, 'removed_at يجب أن يُضبط';
  assert v_removed.removed_by = 'd4000000-0000-4000-8000-000000000001', 'removed_by يجب أن يُنسب للفاعل الصحيح';

  select count(*) into v_active_count from public.sales_order_items where sales_order_id = v_order_id and status = 'active';
  assert v_active_count = 1, format('يجب أن يبقى بند نشط واحد فقط، وجد %s', v_active_count);

  select * into v_order from public.sales_orders where id = v_order_id;
  assert v_order.subtotal = 400.00, format('المجموع الفرعي بعد الإزالة يجب أن يكون 400.00 (البند النشط فقط)، وجد %s', v_order.subtotal);

  raise notice 'OK: E إزالة بند لا تحذفه فعليًا — يبقى بحالة removed مع removed_at/removed_by صحيحين، ويُستبعد من القراءات والإجماليات النشطة، ومعرّفه لا يُعاد استخدامه';
end $$;

-- ============================================================================
-- F) Inactive historical references tolerated when unchanged; rejected when
-- changing TO a different inactive reference.
-- ============================================================================
set role authenticated;
set local request.jwt.claims = '{"sub":"d4000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid; v_result record;
begin
  select id into v_store_id from public.stores where code = 'P31ST';
  select id into v_karat_id from public.karats where code = 'P31K1';
  select id into v_category_id from public.product_categories where code = 'p31cat_a';
  select id into v_channel_id from public.collection_channels where key = 'p31_channel_a';
  select id into v_pm_id from public.payment_methods where key = 'p31_pm_a';

  select * into v_result from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 400.00))
  );
  create temporary table p31_order_f (order_id uuid) on commit drop;
  insert into p31_order_f values (v_result.id);
end $$;

-- Disable every reference this order used, directly (bypassing any
-- management RPC — this test only cares about the resulting status, not the
-- disabling workflow itself, matching how other Sales test files build
-- "already inactive" fixtures). Also capture the order's one item (id +
-- current financial fields) into a temp table HERE, under a role that can
-- actually read sales_order_items (RLS-bypassing) — every subsequent
-- do-block below runs `set role authenticated`, under which a direct SELECT
-- on sales_order_items always returns zero rows (0059), exactly like every
-- other Sales Read in this project; the item's id/category/karat/weight/
-- sale_price never change across F1-F4 (F1 is a no-op for the item, F2
-- changes weight in place keeping the same id, F3/F4 are both rejected), so
-- one snapshot here is valid for the whole section.
reset role;
update public.karats set status = 'inactive' where code = 'P31K1';
update public.product_categories set status = 'inactive' where code = 'p31cat_a';
update public.payment_methods set status = 'inactive' where key = 'p31_pm_a';
update public.collection_channels set status = 'inactive' where key = 'p31_channel_a';

do $$
declare v_order_id uuid;
begin
  select order_id into v_order_id from p31_order_f;
  create temporary table p31_f_item as
    select id, category_id, karat_id, weight_grams, sale_price
    from public.sales_order_items where sales_order_id = v_order_id and status = 'active';
end $$;
grant select on p31_f_item to authenticated;

do $$
declare v_order_id uuid; v_version bigint;
begin
  select order_id into v_order_id from p31_order_f;
  select row_version into v_version from public.sales_orders where id = v_order_id;
  delete from p31_row_version;
  insert into p31_row_version values (v_version);
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"d4000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- F1: editing notes only (every reference UNCHANGED) succeeds despite all
-- four now being inactive.
do $$
declare
  v_order_id uuid; v_channel_id uuid; v_pm_id uuid; v_result record; v_version bigint;
begin
  select order_id into v_order_id from p31_order_f;
  select id into v_channel_id from public.collection_channels where key = 'p31_channel_a';
  select id into v_pm_id from public.payment_methods where key = 'p31_pm_a';
  select v into v_version from p31_row_version;

  select * into v_result from public.update_sales_order(
    v_order_id, v_pm_id, v_channel_id,
    (select jsonb_agg(jsonb_build_object('id', f.id, 'category_id', f.category_id, 'karat_id', f.karat_id, 'weight_grams', f.weight_grams, 'sale_price', f.sale_price)) from p31_f_item f),
    null, null, 'ملاحظة فقط رغم تعطّل كل المراجع', null, v_version
  );
  assert v_result.id = v_order_id, 'يجب أن ينجح تعديل الملاحظة فقط رغم أن كل المراجع أصبحت غير نشطة';
  raise notice 'OK: F1 تعديل ملاحظة فقط (كل المراجع بلا تغيير) نجح رغم أن التصنيف/العيار/طريقة الدفع/قناة التحصيل أصبحت جميعًا غير نشطة';
end $$;

reset role;
do $$
declare v_order_id uuid; v_version bigint;
begin
  select order_id into v_order_id from p31_order_f;
  select row_version into v_version from public.sales_orders where id = v_order_id;
  delete from p31_row_version;
  insert into p31_row_version values (v_version);
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"d4000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- F2: changing weight only (financial input changed) while karat/category
-- stay the SAME (still inactive) — allowed, resolves against sale_date with
-- the same (inactive) references.
do $$
declare
  v_order_id uuid; v_category_id uuid; v_karat_id uuid; v_channel_id uuid; v_pm_id uuid; v_item_id uuid; v_version bigint;
begin
  select order_id into v_order_id from p31_order_f;
  select id into v_channel_id from public.collection_channels where key = 'p31_channel_a';
  select id into v_pm_id from public.payment_methods where key = 'p31_pm_a';
  select id, category_id, karat_id into v_item_id, v_category_id, v_karat_id from p31_f_item;
  select v into v_version from p31_row_version;

  perform public.update_sales_order(
    v_order_id, v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('id', v_item_id, 'category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 2.0000, 'sale_price', 700.00)),
    null, null, null, null, v_version
  );
end $$;

reset role;
do $$
declare v_item_id uuid; v_item record; v_order_id uuid; v_version bigint;
begin
  select id into v_item_id from p31_f_item;
  select * into v_item from public.sales_order_items where id = v_item_id and status = 'active';
  assert v_item.weight_grams = 2.0000, 'الوزن يجب أن يتحدّث حتى مع بقاء العيار/التصنيف غير نشطين (لم يتغيّرا)';
  raise notice 'OK: F2 تعديل مدخل مالي (الوزن) مع بقاء العيار/التصنيف بلا تغيير نجح وأعاد الحساب رغم أنهما غير نشطين حاليًا';

  select order_id into v_order_id from p31_order_f;
  select row_version into v_version from public.sales_orders where id = v_order_id;
  delete from p31_row_version;
  insert into p31_row_version values (v_version);
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"d4000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- F3: attempting to CHANGE karat_id to a DIFFERENT (also inactive) karat is
-- rejected.
do $$
declare
  v_order_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid; v_item_id uuid;
  v_other_inactive_karat uuid; v_bug boolean := false; v_version bigint;
begin
  select order_id into v_order_id from p31_order_f;
  select id into v_channel_id from public.collection_channels where key = 'p31_channel_a';
  select id into v_pm_id from public.payment_methods where key = 'p31_pm_a';
  select id, category_id into v_item_id, v_category_id from p31_f_item;
  select v into v_version from p31_row_version;

  insert into public.karats (code, name_ar, sort_order, status) values ('P31K2_INACTIVE', 'عيار آخر معطّل 3.1', 982, 'inactive') returning id into v_other_inactive_karat;

  begin
    perform public.update_sales_order(
      v_order_id, v_pm_id, v_channel_id,
      jsonb_build_array(jsonb_build_object('id', v_item_id, 'category_id', v_category_id, 'karat_id', v_other_inactive_karat, 'weight_grams', 2.0000, 'sale_price', 700.00)),
      null, null, null, null, v_version
    );
    v_bug := true;
  exception when others then
    raise notice 'OK: F3 رُفض تغيير العيار إلى عيار آخر غير نشط (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: قُبل تغيير العيار إلى عيار آخر غير نشط'; end if;
end $$;

-- F4: attempting to CHANGE payment_method_id to a different inactive method
-- is rejected. F3 above failed (no write), so the row_version fetched
-- before F3 is still current — reused here rather than re-fetched.
do $$
declare
  v_order_id uuid; v_channel_id uuid; v_other_inactive_pm uuid; v_bug boolean := false; v_version bigint;
begin
  select order_id into v_order_id from p31_order_f;
  select id into v_channel_id from public.collection_channels where key = 'p31_channel_a';
  select v into v_version from p31_row_version;
  insert into public.payment_methods (key, name_ar, fee_model, sort_order, status) values ('p31_pm_inactive', 'طريقة دفع معطّلة 3.1', 'percentage', 983, 'inactive') returning id into v_other_inactive_pm;

  begin
    perform public.update_sales_order(
      v_order_id, v_other_inactive_pm, v_channel_id,
      (select jsonb_agg(jsonb_build_object('id', f.id, 'category_id', f.category_id, 'karat_id', f.karat_id, 'weight_grams', f.weight_grams, 'sale_price', f.sale_price)) from p31_f_item f),
      null, null, null, null, v_version
    );
    v_bug := true;
  exception when others then
    raise notice 'OK: F4 رُفض تغيير طريقة الدفع إلى طريقة أخرى غير نشطة (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: قُبل تغيير طريقة الدفع إلى طريقة أخرى غير نشطة'; end if;
end $$;

reset role;

-- ============================================================================
-- G) Audit profit leak (0072) — audit_logs.view alone cannot read sale.*
-- financial payload; audit_logs.view + sales.view_profit can; other audit
-- rows remain visible either way.
-- ============================================================================
set role authenticated;
set local request.jwt.claims = '{"sub":"d4000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v_store_id uuid;
begin
  select id into v_store_id from public.stores where code = 'P31ST';
  perform public.close_sales_day(v_store_id, public.business_today() - 1, 'إغلاق لاختبار G');
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"d4000000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$
declare v_sale_count int; v_daily_close_count int;
begin
  select count(*) into v_sale_count from public.audit_logs where action like 'sale.%';
  assert v_sale_count = 0, format('مستخدم يملك audit_logs.view فقط (بلا sales.view_profit) يجب ألا يرى أي صف sale.%%، وجد %s', v_sale_count);

  select count(*) into v_daily_close_count from public.audit_logs where action = 'daily_closing.create';
  assert v_daily_close_count > 0, 'نفس المستخدم يجب أن يرى أحداث daily_closing.create (غير حسّاسة ماليًا) بلا أي قيد إضافي';

  raise notice 'OK: G1 مستخدم بلا sales.view_profit لا يرى أي صف تدقيق sale.%% رغم امتلاكه audit_logs.view — ويرى أحداث التدقيق الأخرى غير الحسّاسة بشكل طبيعي';
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"d4000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v_sale_count int;
begin
  select count(*) into v_sale_count from public.audit_logs where action like 'sale.%';
  assert v_sale_count > 0, 'مستخدم يملك audit_logs.view و sales.view_profit معًا يجب أن يرى صفوف sale.%% كاملة';
  raise notice 'OK: G2 مستخدم يملك audit_logs.view + sales.view_profit يرى صفوف تدقيق sale.%% كاملة (لا حذف/تنقيح للبيانات، فقط تقييد من يراها)';
end $$;

reset role;

-- ============================================================================
-- L) Rounding boundary (spec item 8's exact worked example): weight=0.0100,
-- gold=300, mfg=10, VAT=15% -> total_cost=3.57, gross_profit(sale=100)=96.43,
-- reconciling exactly to sale_price.
-- ============================================================================
do $$
declare v_costs record;
begin
  select * into v_costs from public.compute_sales_item_costs(300.0000, 10.0000, 15.000, 0.0100, 100.00);
  assert v_costs.gold_component_cost = 3.00, format('gold_component_cost متوقَّع 3.00، وجد %s', v_costs.gold_component_cost);
  assert v_costs.manufacturing_component_cost = 0.10, format('manufacturing_component_cost متوقَّع 0.10، وجد %s', v_costs.manufacturing_component_cost);
  assert v_costs.base_cost = 3.10, format('base_cost متوقَّع 3.10، وجد %s', v_costs.base_cost);
  assert v_costs.vat_cost = 0.47, format('vat_cost متوقَّع 0.47 (round-half-away-from-zero لـ 0.465)، وجد %s', v_costs.vat_cost);
  assert v_costs.total_cost = 3.57, format('total_cost متوقَّع 3.57، وجد %s', v_costs.total_cost);
  assert v_costs.gross_profit = 96.43, format('gross_profit متوقَّع 96.43، وجد %s', v_costs.gross_profit);
  assert v_costs.total_cost + v_costs.gross_profit = 100.00, format('total_cost + gross_profit يجب أن يساوي sale_price تمامًا (100.00)، وجد %s', v_costs.total_cost + v_costs.gross_profit);
  raise notice 'OK: L حالة التقريب الحدّية (وزن 0.0100) تُصالح تمامًا: total_cost=3.57 + gross_profit=96.43 = sale_price=100.00';
end $$;

-- Same boundary case wired through the real create_sales_order() RPC, not
-- just the helper in isolation — proves the reconciling policy is actually
-- applied end-to-end, not merely correct on paper.
set role authenticated;
set local request.jwt.claims = '{"sub":"d4000000-0000-4000-8000-000000000001","role":"authenticated"}';
-- Dedicated karat with a fresh 300.0000 gold price, deliberately NOT P31K1
-- (whose price section B corrected to 350.0000, and whose status section F
-- toggled inactive/active) — keeps this boundary case's expected numbers
-- exact and independent of what earlier sections did.
do $$
declare v_karat_id uuid;
begin
  insert into public.karats (code, name_ar, sort_order, status) values ('P31K_L', 'عيار قسم L 3.1', 985, 'active') returning id into v_karat_id;
  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 300.0000, 'd4000000-0000-4000-8000-000000000001');
  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, public.business_today(), 'p31 section L fixture');

  update public.product_categories set status = 'active' where code = 'p31cat_a';
  update public.payment_methods set status = 'active' where key = 'p31_pm_a';
  update public.collection_channels set status = 'active' where key = 'p31_channel_a';
end $$;

do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid; v_result record;
begin
  select id into v_store_id from public.stores where code = 'P31ST';
  select id into v_karat_id from public.karats where code = 'P31K_L';
  select id into v_category_id from public.product_categories where code = 'p31cat_a';
  select id into v_channel_id from public.collection_channels where key = 'p31_channel_a';
  select id into v_pm_id from public.payment_methods where key = 'p31_pm_a';

  select * into v_result from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.0100, 'sale_price', 100.00))
  );
  create temporary table p31_rounding_order (order_id uuid) on commit drop;
  insert into p31_rounding_order values (v_result.id);
end $$;

reset role;
do $$
declare v_order_id uuid; v_item record;
begin
  select order_id into v_order_id from p31_rounding_order;
  select * into v_item from public.sales_order_items where sales_order_id = v_order_id and status = 'active';
  assert v_item.total_cost = 3.57, format('total_cost عبر create_sales_order() الفعلي متوقَّع 3.57، وجد %s', v_item.total_cost);
  assert v_item.gross_profit = 96.43, format('gross_profit عبر create_sales_order() الفعلي متوقَّع 96.43، وجد %s', v_item.gross_profit);
  raise notice 'OK: L2 نفس حالة التقريب الحدّية تُصالح تمامًا عند المرور فعليًا عبر create_sales_order()';
end $$;

-- ============================================================================
-- Done.
-- ============================================================================
do $$ begin raise notice 'OK: ALL Sales Integrity Patch 3.1 (Part 1, single-session) tests passed'; end $$;

rollback;
