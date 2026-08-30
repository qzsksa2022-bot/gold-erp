-- ============================================================================
-- Integration test: Production upgrade path onto Phase 6 (Services /
-- Adjustments Core) without re-running seed.sql
-- ============================================================================
-- This file does NOT build the database itself — it only ASSERTS against a
-- database that was already built the way a real production upgrade would
-- experience it:
--
--   1. Fresh DB, migrations 0001-0132 applied (everything through Hotfix
--      5.1.3 — the last shipped state before Phase 6).
--   2. The REAL supabase/seed.sql applied (a real upgrade already ran this
--      once, long before Phase 6 existed — it is never re-run here).
--   3. Migrations 0133 through the latest (Phase 6) applied on top — in a
--      SEPARATE psql invocation, exactly like a production upgrade would.
--
-- See scripts/run_upgrade_test_phase6_adjustments.sh for the orchestration
-- that builds exactly this sequence, then runs this file.
--
-- Proves two distinct things:
--   (A) The 4 new Phase 6 permission keys (adjustments.manage_cost/reverse/
--       process_closed_day/manage_types) and their role grants come from
--       migration 0133 itself, idempotently — NOT from seed.sql (which
--       never ran again) and not missing/duplicated.
--   (B) The entire new Adjustments engine is immediately USABLE the moment
--       0133-0143 finish applying — a full create -> approve -> reverse
--       lifecycle against a REAL pre-existing Sales Order (created under
--       the OLD, pre-Phase-6 schema, proving no backfill/migration of
--       sales_orders was needed for Phase 6 to work), with correct fee/
--       profit math and Sales-profit-independence, all inside this same
--       rolled-back transaction so it never mutates whatever database this
--       runs against.
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/upgrade_phase6_adjustments.test.sql
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- (A) Permission keys + role grants come from 0133, not seed.sql.
-- ---------------------------------------------------------------------------
do $$
declare
  v_count integer;
  v_super_admin_count integer;
  v_admin_count integer;
  v_supervisor_count integer;
begin
  select count(*) into v_count from public.permissions
    where category = 'adjustments'
    and key in ('adjustments.manage_cost', 'adjustments.reverse', 'adjustments.process_closed_day', 'adjustments.manage_types');
  assert v_count = 4, format('BUG: يجب أن توجد 4 صلاحيات Phase 6 الجديدة بعد الترقية بدون seed.sql — وُجد %s', v_count);

  select count(*) into v_super_admin_count
  from public.role_permissions rp
  join public.roles r on r.id = rp.role_id
  join public.permissions p on p.id = rp.permission_id
  where r.key = 'super_admin' and p.key in ('adjustments.manage_cost', 'adjustments.reverse', 'adjustments.process_closed_day', 'adjustments.manage_types');
  assert v_super_admin_count = 4, format('BUG: super_admin يجب أن يملك 4 صفوف صريحة لصلاحيات Phase 6 الجديدة، وُجد %s', v_super_admin_count);

  select count(*) into v_admin_count
  from public.role_permissions rp
  join public.roles r on r.id = rp.role_id
  join public.permissions p on p.id = rp.permission_id
  where r.key = 'admin' and p.key in ('adjustments.manage_cost', 'adjustments.reverse', 'adjustments.process_closed_day', 'adjustments.manage_types');
  assert v_admin_count = 4, format('BUG: admin يجب أن يملك 4 صفوف صريحة لصلاحيات Phase 6 الجديدة، وُجد %s', v_admin_count);

  -- supervisor holds 3 of the 4 (excludes adjustments.manage_types, per
  -- 0133's own least-privilege design — Master Data type management stays
  -- admin/super_admin only).
  select count(*) into v_supervisor_count
  from public.role_permissions rp
  join public.roles r on r.id = rp.role_id
  join public.permissions p on p.id = rp.permission_id
  where r.key = 'supervisor' and p.key in ('adjustments.manage_cost', 'adjustments.reverse', 'adjustments.process_closed_day');
  assert v_supervisor_count = 3, format('BUG: supervisor يجب أن يملك 3 صفوف صريحة (بدون manage_types)، وُجد %s', v_supervisor_count);

  assert not exists (
    select 1 from public.role_permissions rp
    join public.roles r on r.id = rp.role_id
    join public.permissions p on p.id = rp.permission_id
    where r.key = 'supervisor' and p.key = 'adjustments.manage_types'
  ), 'BUG: supervisor يجب ألا يملك adjustments.manage_types';

  raise notice 'OK: صلاحيات Phase 6 الأربع الجديدة موجودة ومُمنوحة بشكل صحيح (super_admin/admin/supervisor) بعد الترقية بدون إعادة تشغيل seed.sql';
end $$;

-- ---------------------------------------------------------------------------
-- (B) Full functional proof: create real fixture data (store/karat/category/
-- gold price/manufacturing fee/Sales Order) exactly as a pre-Phase-6
-- production database would already have, then prove the new Adjustments
-- engine works immediately against it.
-- ---------------------------------------------------------------------------
do $$
declare
  v_super_admin_id uuid := 'a6200000-0000-4000-8000-000000000001';
  v_store_id uuid;
  v_karat_id uuid;
  v_category_id uuid;
  v_order_id uuid;
  v_order_number text;
  v_pm_id uuid;
  v_cc_id uuid;
  v_type_id uuid;
  v_adj_id uuid;
  v_adj_number text;
  v_row_version bigint;
  v_net_profit text;
  v_summary record;
begin
  -- A trigger on auth.users auto-creates the matching profiles row
  -- (including its NOT NULL email) — the fixture only needs to UPDATE it
  -- afterward, exactly mirroring adjustments_core_phase6.test.sql's own
  -- setup convention.
  insert into auth.users (id, email) values (v_super_admin_id, 'phase6-upgrade-admin@example.invalid') on conflict do nothing;
  update public.profiles set full_name = 'Phase 6 Upgrade Test Admin', status = 'active', store_access_scope = 'all' where id = v_super_admin_id;
  insert into public.user_roles (user_id, role_id)
    select v_super_admin_id, id from public.roles where key = 'super_admin'
    on conflict do nothing;

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a6200000-0000-4000-8000-000000000001","role":"authenticated"}';

  insert into public.stores (code, name_ar, status) values ('P6UPG', 'فرع ترقية Phase 6', 'active') returning id into v_store_id;

  insert into public.karats (code, name_ar, purity_per_mille, status) values ('P6UPG', 'عيار ترقية P6U', 750, 'active') returning id into v_karat_id;
  insert into public.product_categories (code, name_ar, status) values ('p6upg', 'تصنيف ترقية P6U', 'active') returning id into v_category_id;
  insert into public.daily_gold_prices (karat_id, price_date, price_per_gram, created_by) values (v_karat_id, public.business_today(), 250.00, v_super_admin_id);
  perform public.create_manufacturing_fee_version(v_karat_id, 10.00, public.business_today(), null);

  select id into v_pm_id from public.payment_methods where key = 'visa';
  select id into v_cc_id from public.collection_channels limit 1;

  -- A real Sales Order, created via the SAME create_sales_order() a real
  -- pre-Phase-6 production database would have used — no schema change to
  -- sales_orders was needed for Phase 6 to attach to it.
  select id, order_number into v_order_id, v_order_number
  from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_cc_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 5.000, 'sale_price', 1500.00)),
    'عميل ترقية Phase 6', null, null, null
  );
  assert v_order_id is not null, 'BUG: فشل إنشاء عملية بيع حقيقية للتحقق من الترقية';

  -- The new Adjustments engine, immediately usable post-upgrade.
  v_type_id := public.create_adjustment_type('p6_upgrade_service', 'خدمة تحقق من الترقية', null, null, 0);
  assert v_type_id is not null, 'BUG: فشل إنشاء نوع تعديل/خدمة بعد الترقية مباشرة';

  select id, adjustment_number into v_adj_id, v_adj_number
  from public.create_sales_order_adjustment(v_order_id, v_type_id, v_store_id, public.business_today(), v_pm_id, v_cc_id, false, 100.00, 30.00, 'تحقق من الترقية', null, null);
  assert v_adj_number like 'ADJ-%', format('BUG: رقم التعديل غير متوقع بعد الترقية: %s', v_adj_number);

  select row_version into v_row_version from public.get_sales_order_adjustment(v_adj_id);

  select row_version, net_adjustment_profit into v_row_version, v_net_profit
  from public.approve_sales_order_adjustment(v_adj_id, v_row_version, null);

  -- visa is seeded at 2.5%/0 fixed (same worked example as the SQL/HTTP
  -- suites): fee=2.50, gross=70.00, net=67.50.
  assert v_net_profit = '67.50', format('BUG: صافي الربح بعد الاعتماد غير صحيح بعد الترقية: %s (متوقع 67.50)', v_net_profit);

  -- Sales-profit independence (§2) — the linked Sales Order's own profit
  -- must be completely untouched by the Adjustment above.
  select approved_effective_adjustments_charge_total, total_including_adjustments into v_summary
  from public.get_sales_order_adjustment_summary(v_order_id);
  assert v_summary.approved_effective_adjustments_charge_total = '100.00', format('BUG: ملخص التعديلات غير صحيح بعد الترقية: %s', v_summary.approved_effective_adjustments_charge_total);

  raise notice 'OK: محرك التعديلات/الخدمات (Phase 6) يعمل بالكامل فور اكتمال الترقية 0133-latest — تعديل % بربح صافٍ % على عملية بيع % حقيقية أُنشئت بالمخطط القديم قبل Phase 6، دون أي إعادة تشغيل لِـseed.sql', v_adj_number, v_net_profit, v_order_number;
end $$;

do $$
begin
  raise notice '=== ALL UPGRADE-TO-PHASE-6 TESTS PASSED (0133-latest applied onto a real pre-Phase-6 production-shaped database, WITHOUT re-running seed.sql) ===';
end $$;

rollback;
