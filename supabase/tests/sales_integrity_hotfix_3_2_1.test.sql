-- ============================================================================
-- Integration test: Phase 3 — Final Hotfix 3.2.1 (migration 0081), Part 1 —
-- single-session scenarios (item 3: sales_orders.calculation_version
-- semantics)
-- ============================================================================
-- Covers hotfix item 3 exactly as specified: a simulated legacy order
-- header (calculation_version=1) is bumped to 2 by ANY successful
-- update_sales_order() call — even a metadata-only one, since the function
-- unconditionally recomputes the header's aggregate totals every time —
-- while an untouched item's OWN calculation_version is governed
-- independently (stays 1 until ITS financial inputs actually change,
-- exactly as Patch 3.2 item 7 already established and this hotfix does not
-- touch). A brand-new Sale is entirely v2 at both header and item level.
-- The sale.update audit entry's old_values/new_values must reflect the
-- real pre-/post-edit header version, not repeat one value on both sides.
--
-- Hotfix item 2 (service_role EXECUTE grant on the financial-master
-- exclusive lock helper) is a genuine multi-session concurrency scenario
-- and lives in the companion file
-- supabase/tests/sales_integrity_patch_3_1_concurrency.test.sql (sections
-- L1/L2, added by this hotfix). Hotfix item 1 (Edit UI Conflict-reload
-- stale state) is a TypeScript/React fix with its own regression test at
-- tests/sales-entry-form-conflict-reload.test.tsx — nothing to cover here.
--
-- Requires migrations 0001-0081 + supabase/seed.sql to already be applied.
-- Safe to run against a real database: everything happens inside a
-- transaction that is ALWAYS rolled back at the end.
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/sales_integrity_hotfix_3_2_1.test.sql
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0. Setup — one actor, own fixtures. Prefix 'd8...'/'h321' is unused by any
-- other test file's fixtures.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('d8000000-0000-4000-8000-000000000001', 'test-h321-manager@example.invalid');

update public.profiles set full_name = 'Test Hotfix 3.2.1 Manager', status = 'active', store_access_scope = 'all'
  where id = 'd8000000-0000-4000-8000-000000000001';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'd8000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in (
    'stores.view', 'stores.create', 'stores.manage',
    'karats.view', 'karats.manage', 'categories.view', 'categories.manage',
    'collection_channels.view', 'collection_channels.manage',
    'payment_methods.view', 'payment_methods.manage',
    'gold_prices.view', 'gold_prices.edit',
    'manufacturing_fees.view', 'manufacturing_fees.manage',
    'vat_rates.view', 'vat_rates.manage',
    'sales.create', 'sales.edit', 'sales.view', 'sales.view_profit',
    'audit_logs.view'
  );

set role authenticated;
set local request.jwt.claims = '{"sub":"d8000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
begin
  insert into public.stores (code, name_ar, status) values ('H321ST', 'متجر هوتفكس 3.2.1', 'active') returning id into v_store_id;
  insert into public.karats (code, name_ar, sort_order, status) values ('H321K1', 'عيار هوتفكس 3.2.1', 996, 'active') returning id into v_karat_id;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('h321cat', 'تصنيف هوتفكس 3.2.1', 996, 'active') returning id into v_category_id;
  insert into public.collection_channels (key, name_ar, sort_order, status) values ('h321_channel', 'قناة هوتفكس 3.2.1', 996, 'active') returning id into v_channel_id;
  insert into public.payment_methods (key, name_ar, fee_model, sort_order, status) values ('h321_pm', 'طريقة دفع هوتفكس 3.2.1', 'percentage', 996, 'active') returning id into v_pm_id;

  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 300.0000, 'd8000000-0000-4000-8000-000000000001');

  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, public.business_today(), 'h321 fixture');
  perform public.create_payment_method_fee_version(v_pm_id, 2.0, 0, public.business_today(), 'h321 fixture');
end $$;

reset role;

create temporary table h321_row_version (v bigint) on commit drop;
grant select on h321_row_version to authenticated;

-- ============================================================================
-- D) Sanity baseline (mirrors Patch 3.2's own F1, restated here so this
-- hotfix's own test file is self-contained per the request): a brand-new
-- Sale created after Patch 3.2/Hotfix 3.2.1 is entirely v2 at BOTH header
-- and item level. Not a regression this hotfix could plausibly cause
-- (create_sales_order() is untouched by 0081), but explicitly requested.
-- ============================================================================
set role authenticated;
set local request.jwt.claims = '{"sub":"d8000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid; v_result record;
begin
  select id into v_store_id from public.stores where code = 'H321ST';
  select id into v_karat_id from public.karats where code = 'H321K1';
  select id into v_category_id from public.product_categories where code = 'h321cat';
  select id into v_channel_id from public.collection_channels where key = 'h321_channel';
  select id into v_pm_id from public.payment_methods where key = 'h321_pm';

  select * into v_result from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 500.00))
  );
  create temporary table h321_order (order_id uuid) on commit drop;
  insert into h321_order values (v_result.id);
end $$;

reset role;
do $$
declare v_order_id uuid;
begin
  select order_id into v_order_id from h321_order;
  assert (select calculation_version from public.sales_orders where id = v_order_id) = 2,
    'FAIL D: رأس عملية بيع جديدة بعد Hotfix 3.2.1 يجب أن يحمل calculation_version=2';
  assert exists (
    select 1 from public.sales_order_items where sales_order_id = v_order_id and status = 'active' and calculation_version = 2
  ), 'FAIL D: بند عملية بيع جديدة بعد Hotfix 3.2.1 يجب أن يحمل calculation_version=2';
  raise notice 'OK: D عملية بيع جديدة بالكامل بعد Hotfix 3.2.1 مُعلَّمة calculation_version=2 على مستوى الرأس والبند معًا (خط أساس، لم يتأثر بهذا الهوتفكس)';
end $$;

-- Simulate a LEGACY order header (v1) on this same order — a fresh test
-- database has no organically pre-Patch-3.2 data, so this directly stamps
-- sales_orders.calculation_version=1 the same way an order created before
-- Patch 3.2 would actually have it. Also stamp its one item v1, to prove
-- the header and item columns are governed independently from here on.
reset role;
do $$
declare v_order_id uuid; v_item_id uuid;
begin
  select order_id into v_order_id from h321_order;
  update public.sales_orders set calculation_version = 1 where id = v_order_id;
  select id into v_item_id from public.sales_order_items where sales_order_id = v_order_id and status = 'active';
  update public.sales_order_items set calculation_version = 1 where id = v_item_id;

  create temporary table h321_item (item_id uuid, category_id uuid, karat_id uuid, weight_grams numeric, sale_price numeric) on commit drop;
  insert into h321_item
    select id, category_id, karat_id, weight_grams, sale_price from public.sales_order_items where id = v_item_id;
end $$;
grant select on h321_item to authenticated;

do $$
declare v_order_id uuid; v_version bigint;
begin
  select order_id into v_order_id from h321_order;
  select row_version into v_version from public.sales_orders where id = v_order_id;
  delete from h321_row_version;
  insert into h321_row_version values (v_version);
end $$;

-- ============================================================================
-- A + B) A metadata-only update_sales_order() call on a simulated legacy
-- order (header v1, item v1) — no financial input on the item changes at
-- all — must still (A) bump the HEADER to calculation_version=2, because
-- this call unconditionally recomputes subtotal/gross_profit/
-- payment_fee_amount/net_sales_profit using the current engine, while (B)
-- leaving the untouched ITEM at calculation_version=1 exactly as Patch 3.2
-- item 7 already established (no forced item upgrade for a metadata-only
-- edit). This is the exact "Order header = v2, Item A untouched = v1"
-- state the migration 0081 comment describes as the intended outcome.
-- ============================================================================
set role authenticated;
set local request.jwt.claims = '{"sub":"d8000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_order_id uuid; v_channel_id uuid; v_pm_id uuid; v_version bigint; v_item_id uuid;
  v_category_id uuid; v_karat_id uuid; v_weight numeric; v_sale_price numeric;
begin
  select order_id into v_order_id from h321_order;
  select id into v_channel_id from public.collection_channels where key = 'h321_channel';
  select id into v_pm_id from public.payment_methods where key = 'h321_pm';
  select v into v_version from h321_row_version;
  select item_id, category_id, karat_id, weight_grams, sale_price
    into v_item_id, v_category_id, v_karat_id, v_weight, v_sale_price
    from h321_item;

  -- Notes-only change; the item payload is byte-for-byte identical to its
  -- current stored values (metadata-only, not even item_name/description/
  -- sku change) -- purely a header-level edit.
  perform public.update_sales_order(
    v_order_id, v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('id', v_item_id, 'category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', v_weight, 'sale_price', v_sale_price)),
    null, null, 'ملاحظة فقط — بلا أي تغيير مالي', null, v_version
  );
end $$;

reset role;
do $$
declare v_order_id uuid; v_item_id uuid; v_header_version int; v_item_version int;
begin
  select order_id into v_order_id from h321_order;
  select item_id into v_item_id from h321_item;

  select calculation_version into v_header_version from public.sales_orders where id = v_order_id;
  assert v_header_version = 2, format('FAIL A: تعديل وصفي فقط على رأس عملية بيع كان v1 يجب أن يرفعه إلى calculation_version=2 (لأن الحقول الإجمالية أُعيد حسابها فعليًا في نفس الاستدعاء)، وجد %s', v_header_version);
  raise notice 'OK: A رأس عملية بيع كان v1 أصبح calculation_version=2 بعد تعديل ناجح واحد (حتى لو وصفي فقط)، لأن update_sales_order() تعيد بناء subtotal/gross_profit/payment_fee_amount/net_sales_profit فعليًا في كل استدعاء ناجح';

  select calculation_version into v_item_version from public.sales_order_items where id = v_item_id and status = 'active';
  assert v_item_version = 1, format('FAIL B: البند غير المتغيّر ماليًا يجب أن يبقى calculation_version=1 (سياسة عدم الترقية القسرية، بند 7، لم يتغيّر بهذا الهوتفكس) رغم أن رأس نفس العملية أصبح v2 الآن، وجد %s', v_item_version);
  raise notice 'OK: B البند القديم (v1) بقي دون ترقية قسرية رغم أن رأس نفس العملية أصبح v2 — دلالتان مستقلتان تمامًا لِـcalculation_version على مستوى الرأس مقابل البند، بالضبط كما يوثّق 0081';
end $$;

-- ============================================================================
-- E) Audit old/new: the sale.update entry for the edit above must report
-- the REAL pre-/post-edit header calculation_version on each side (1 then
-- 2) — not the pre-hotfix bug where new_values repeated the OLD value.
-- ============================================================================
reset role;
do $$
declare v_order_id uuid; v_old_version int; v_new_version int;
begin
  select order_id into v_order_id from h321_order;

  select (old_values ->> 'calculation_version')::int, (new_values ->> 'calculation_version')::int
    into v_old_version, v_new_version
    from public.audit_logs
    where action = 'sale.update' and entity_id = v_order_id
    order by created_at desc limit 1;

  assert v_old_version = 1, format('FAIL E: old_values.calculation_version يجب أن يساوي 1 (القيمة الفعلية قبل التعديل)، وجد %s', v_old_version);
  assert v_new_version = 2, format('FAIL E: new_values.calculation_version يجب أن يساوي 2 (القيمة الفعلية بعد التعديل) لا أن يكرر القيمة القديمة، وجد %s', v_new_version);
  raise notice 'OK: E تدقيق sale.update يحمل old_values.calculation_version=1 وnew_values.calculation_version=2 -- القيمتان الفعليتان قبل/بعد، لا تكرار القيمة القديمة على الجانبين';
end $$;

-- ============================================================================
-- C) A subsequent edit that DOES change the item's financial inputs stamps
-- the item v2 too (unchanged Patch 3.2 item 7 behavior) — header stays v2
-- (was already v2 from the A/B edit above; still exercised end-to-end to
-- prove the header never regresses back to 1).
-- ============================================================================
do $$
declare v_order_id uuid; v_version bigint;
begin
  select order_id into v_order_id from h321_order;
  select row_version into v_version from public.sales_orders where id = v_order_id;
  delete from h321_row_version;
  insert into h321_row_version values (v_version);
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"d8000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_order_id uuid; v_channel_id uuid; v_pm_id uuid; v_version bigint; v_item_id uuid;
  v_category_id uuid; v_karat_id uuid;
begin
  select order_id into v_order_id from h321_order;
  select id into v_channel_id from public.collection_channels where key = 'h321_channel';
  select id into v_pm_id from public.payment_methods where key = 'h321_pm';
  select v into v_version from h321_row_version;
  select item_id, category_id, karat_id into v_item_id, v_category_id, v_karat_id from h321_item;

  perform public.update_sales_order(
    v_order_id, v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('id', v_item_id, 'category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 3.0000, 'sale_price', 900.00)),
    null, null, null, null, v_version
  );
end $$;

reset role;
do $$
declare v_order_id uuid; v_item_id uuid; v_header_version int; v_item_version int;
begin
  select order_id into v_order_id from h321_order;
  select item_id into v_item_id from h321_item;

  select calculation_version into v_header_version from public.sales_orders where id = v_order_id;
  assert v_header_version = 2, format('FAIL C: رأس العملية يجب أن يبقى calculation_version=2 (لم يرتد إلى 1)، وجد %s', v_header_version);

  select calculation_version into v_item_version from public.sales_order_items where id = v_item_id and status = 'active';
  assert v_item_version = 2, format('FAIL C: البند الذي تغيّرت مدخلاته المالية فعليًا يجب أن يصبح calculation_version=2، وجد %s', v_item_version);

  raise notice 'OK: C تعديل مالي فعلي على نفس البند رفعه إلى calculation_version=2، ورأس العملية بقي v2 (لم يرتد) — سلوك البند مطابق تمامًا لبند 7 من Patch 3.2 دون أي تغيير';
end $$;

do $$ begin raise notice 'OK: ALL Sales Integrity Hotfix 3.2.1 (Part 1, single-session) tests passed'; end $$;

rollback;
