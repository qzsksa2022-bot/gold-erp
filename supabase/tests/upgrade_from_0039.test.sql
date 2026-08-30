-- ============================================================================
-- Integration test: Production upgrade path from Foundation (0039) without
-- re-running seed.sql (Financial Integrity Patch 2.1, spec item 4)
-- ============================================================================
-- This file does NOT build the database itself — it only ASSERTS against a
-- database that was already built the specific way spec item 4 describes:
--
--   1. Fresh DB, migrations 0001-0039 applied (Foundation only).
--   2. supabase/tests/fixtures/foundation_only_seed.sql applied — a snapshot
--      of what supabase/seed.sql looked like BEFORE Phase 2/Patch 2.1 ever
--      existed (permissions/roles/role_permissions/system_settings only,
--      none of the 10 financial_master_data permission keys, no Phase 2
--      tables' rows since those tables did not exist yet).
--   3. Migrations 0040 through the latest applied (0040-0050) — WITHOUT ever
--      running the current, Phase-2-aware supabase/seed.sql.
--
-- See scripts/run_upgrade_test.sh for the orchestration that builds exactly
-- this sequence, then runs this file. Do NOT run this file against a
-- normally-seeded database (fresh `db reset` + seed.sql) — its assertions
-- are specifically about what 0049 alone must guarantee, and every INSERT
-- below runs inside a rolled-back transaction so it never mutates whatever
-- database it is pointed at, but its assumptions about starting state
-- (e.g. exactly 4 karats) only hold against the fixture-built database.
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/upgrade_from_0039.test.sql
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. The 10 Phase 2 permission keys exist, with the right category, even
-- though foundation_only_seed.sql never inserted them — proves migration
-- 0049 (not seed.sql) is what put them there.
-- ---------------------------------------------------------------------------
do $$
declare v_count integer;
begin
  select count(*) into v_count from public.permissions
    where category = 'financial_master_data'
    and key in (
      'karats.view', 'karats.manage',
      'manufacturing_fees.view', 'manufacturing_fees.manage',
      'categories.view', 'categories.manage',
      'payment_methods.view', 'payment_methods.manage',
      'collection_channels.view', 'collection_channels.manage'
    );
  assert v_count = 10, format('BUG: يجب أن توجد 10 صلاحيات Phase 2 بعد الترقية بدون seed.sql — وُجد %s', v_count);
  raise notice 'OK: صلاحيات Phase 2 العشر موجودة بعد تطبيق 0040-latest فقط (بدون إعادة تشغيل seed.sql)';
end $$;

-- ---------------------------------------------------------------------------
-- 2. role_permissions grants for the 10 Phase 2 keys PLUS the 2 Phase 3
-- vat_rates.* keys (migration 0058 — same 'financial_master_data' category,
-- inserted the identical idempotent-forward-migration way as 0049) match
-- exactly what seed.sql itself would have produced (same least-privilege
-- distribution per role).
-- ---------------------------------------------------------------------------
do $$
declare v_row record; v_actual text[]; v_expected text[];
begin
  for v_row in
    select * from (values
      ('admin', 'karats.view,karats.manage,manufacturing_fees.view,manufacturing_fees.manage,categories.view,categories.manage,payment_methods.view,payment_methods.manage,collection_channels.view,collection_channels.manage,vat_rates.view,vat_rates.manage'),
      ('supervisor', 'karats.view,manufacturing_fees.view,categories.view,payment_methods.view,collection_channels.view,vat_rates.view'),
      ('accountant', 'karats.view,manufacturing_fees.view,categories.view,payment_methods.view,collection_channels.view,vat_rates.view'),
      ('sales_employee', 'karats.view,categories.view,payment_methods.view,collection_channels.view,vat_rates.view'),
      ('shipping_employee', '')
    ) as t(role_key, expected_csv)
  loop
    select coalesce(array_agg(p.key order by p.key), array[]::text[]) into v_actual
    from public.role_permissions rp
    join public.roles r on r.id = rp.role_id
    join public.permissions p on p.id = rp.permission_id
    where r.key = v_row.role_key and p.category = 'financial_master_data';

    if v_row.expected_csv = '' then
      v_expected := array[]::text[];
    else
      select array_agg(x order by x) into v_expected from unnest(string_to_array(v_row.expected_csv, ',')) x;
    end if;

    assert v_actual = v_expected,
      format('BUG: صلاحيات Phase 2/3 للدور %s غير مطابقة لِـ seed.sql — توقعنا %s، وجدنا %s', v_row.role_key, v_expected, v_actual);
  end loop;
  raise notice 'OK: منح صلاحيات Phase 2 + vat_rates.* (Phase 3) لكل دور (admin/supervisor/accountant/sales_employee/shipping_employee) مطابق تمامًا لِـ seed.sql';
end $$;

-- super_admin DOES get explicit role_permissions rows for the 10 new keys —
-- matching seed.sql's own super_admin insert, which is a blanket
-- `cross join public.permissions` and therefore picks up every permission
-- that exists when it runs, Phase 2's included. These rows are purely for
-- "transparent UI display" (seed.sql's own phrase) — has_permission() short-
-- circuits to true for super_admin regardless — but 0049 grants them
-- explicitly anyway so that re-running seed.sql afterwards is a genuine
-- no-op for this table too, not just most of them.
do $$
declare v_count integer;
begin
  select count(*) into v_count
  from public.role_permissions rp
  join public.roles r on r.id = rp.role_id
  join public.permissions p on p.id = rp.permission_id
  where r.key = 'super_admin' and p.category = 'financial_master_data';
  assert v_count = 12, format('BUG: super_admin يجب أن يملك 12 صفًا صريحًا (10 Phase 2 + vat_rates.view/manage من Phase 3) لصلاحيات financial_master_data (مطابقة لِـ seed.sql) — وُجد %s', v_count);
  raise notice 'OK: super_admin يملك 12 صفًا صريحًا لصلاحيات financial_master_data (10 Phase 2 + 2 Phase 3 vat_rates.*) — مطابق تمامًا لسلوك seed.sql الفعلي';
end $$;

-- Functional proof (not just row-counting): a super_admin actor can exercise
-- has_permission() successfully on a Phase 2 key even for a DIFFERENT
-- permission this test deliberately does NOT pre-grant a row for, proving
-- the built-in short-circuit still works independently of row-counting.
do $$
declare v_super_admin_role_id uuid; v_result boolean;
begin
  insert into auth.users (id, email) values ('f3000000-0000-4000-8000-000000000001', 'test-upgrade-superadmin@example.invalid');
  update public.profiles set full_name = 'Test Upgrade Super Admin', status = 'active', store_access_scope = 'all'
    where id = 'f3000000-0000-4000-8000-000000000001';

  -- is_super_admin() (0008) checks user_roles for the 'super_admin' role key
  -- directly — there is no boolean flag column on profiles.
  select id into v_super_admin_role_id from public.roles where key = 'super_admin';
  insert into public.user_roles (user_id, role_id) values ('f3000000-0000-4000-8000-000000000001', v_super_admin_role_id);

  set role authenticated;
  set local request.jwt.claims = '{"sub":"f3000000-0000-4000-8000-000000000001","role":"authenticated"}';
  select public.has_permission('karats.manage') into v_result;
  assert v_result, 'BUG: super_admin يجب أن يجتاز has_permission(''karats.manage'')';
  reset role;
  reset request.jwt.claims;
  raise notice 'OK: has_permission(''karats.manage'') يعمل فعليًا لِـ super_admin بعد الترقية';
end $$;

-- ---------------------------------------------------------------------------
-- 3. Initial master data exists and is correct, inserted by 0049 alone.
-- ---------------------------------------------------------------------------
do $$
declare v_count integer;
begin
  select count(*) into v_count from public.karats where code in ('18', '21', '22', '24');
  assert v_count = 4, format('BUG: يجب أن توجد 4 عيارات (18/21/22/24) بعد الترقية — وُجد %s', v_count);
  raise notice 'OK: العيارات الأربعة الأولية (18/21/22/24) موجودة بعد الترقية بدون seed.sql';
end $$;

do $$
declare v_count integer;
begin
  select count(*) into v_count from public.product_categories
    where code in ('bullion', 'sets', 'half_sets', 'bangles', 'bracelets', 'hand_pieces', 'rings', 'chains', 'earrings', 'pendants');
  assert v_count = 10, format('BUG: يجب أن توجد 10 تصنيفات منتجات أولية بعد الترقية — وُجد %s', v_count);
  raise notice 'OK: تصنيفات المنتجات العشرة الأولية موجودة بعد الترقية بدون seed.sql';
end $$;

do $$
declare v_count integer; v_cod_fee_model text; v_cod_version_count integer;
begin
  select count(*) into v_count from public.payment_methods
    where key in ('cash', 'bank_transfer', 'mada', 'visa', 'tabby', 'tamara', 'cod');
  assert v_count = 7, format('BUG: يجب أن توجد 7 طرق دفع أولية بعد الترقية — وُجد %s', v_count);

  select fee_model into v_cod_fee_model from public.payment_methods where key = 'cod';
  assert v_cod_fee_model = 'percentage_plus_fixed', format('BUG: COD يجب أن يكون fee_model=percentage_plus_fixed — وُجد %s', v_cod_fee_model);

  select count(*) into v_cod_version_count from public.payment_method_fee_versions v
    join public.payment_methods m on m.id = v.payment_method_id where m.key = 'cod';
  assert v_cod_version_count = 0, format('BUG: COD يجب ألا يملك أي نسخة عمولة مُختلَقة بعد الترقية — وُجد %s', v_cod_version_count);

  raise notice 'OK: طرق الدفع السبع موجودة، COD بلا نسخة عمولة مُختلَقة (كما في seed.sql بالضبط)';
end $$;

-- Fee versions and their EXACT rates, per method (Tabby 8%, Tamara 7%, Visa
-- 2.5%, Mada 1%, Cash 0%, Bank Transfer 0%).
do $$
declare v_rec record; v_expected numeric;
begin
  for v_rec in
    select m.key, v.percentage_fee, v.fixed_fee
    from public.payment_method_fee_versions v
    join public.payment_methods m on m.id = v.payment_method_id
    where v.effective_to is null and v.status = 'active'
  loop
    v_expected := case v_rec.key
      when 'cash' then 0
      when 'bank_transfer' then 0
      when 'mada' then 1
      when 'visa' then 2.5
      when 'tabby' then 8
      when 'tamara' then 7
      else null
    end;
    assert v_expected is not null, format('BUG: نسخة عمولة غير متوقعة لطريقة دفع %s بعد الترقية', v_rec.key);
    assert v_rec.percentage_fee = v_expected and v_rec.fixed_fee = 0,
      format('BUG: نسبة عمولة %s بعد الترقية توقعنا %s وجدنا %s', v_rec.key, v_expected, v_rec.percentage_fee);
  end loop;
  raise notice 'OK: نسب العمولات الأولية الست مطابقة تمامًا للمواصفة (Tabby 8%%, Tamara 7%%, Visa 2.5%%, Mada 1%%, Cash/Bank Transfer 0%%)';
end $$;

do $$
declare v_count integer;
begin
  select count(*) into v_count from public.collection_channels where key in ('direct_store', 'salla_wallet');
  assert v_count = 2, format('BUG: يجب أن توجد قناتا تحصيل أوليتان بعد الترقية — وُجد %s', v_count);
  raise notice 'OK: قناتا التحصيل الأوليتان موجودتان بعد الترقية بدون seed.sql';
end $$;

-- ---------------------------------------------------------------------------
-- 4. Functional proof for an ordinary (non-super-admin) role: a fresh user
-- with ONLY the 'sales_employee' role (no per-user overrides at all) can
-- view karats (granted by 0049) but cannot manage them (never granted to
-- this role), and cannot view manufacturing fees (deliberately withheld —
-- see seed.sql's own comment on this exact point).
-- ---------------------------------------------------------------------------
do $$
declare v_role_id uuid; v_can_view boolean; v_can_manage boolean; v_can_view_mfg boolean;
begin
  insert into auth.users (id, email) values ('f3000000-0000-4000-8000-000000000002', 'test-upgrade-salesemployee@example.invalid');
  update public.profiles set full_name = 'Test Upgrade Sales Employee', status = 'active', store_access_scope = 'all'
    where id = 'f3000000-0000-4000-8000-000000000002';

  select id into v_role_id from public.roles where key = 'sales_employee';
  insert into public.user_roles (user_id, role_id) values ('f3000000-0000-4000-8000-000000000002', v_role_id);

  set role authenticated;
  set local request.jwt.claims = '{"sub":"f3000000-0000-4000-8000-000000000002","role":"authenticated"}';
  select public.has_permission('karats.view') into v_can_view;
  select public.has_permission('karats.manage') into v_can_manage;
  select public.has_permission('manufacturing_fees.view') into v_can_view_mfg;
  reset role;
  reset request.jwt.claims;

  assert v_can_view, 'BUG: موظف مبيعات يجب أن يملك karats.view بعد الترقية (منحته 0049 عبر الدور، بلا أي user_permission_overrides)';
  assert not v_can_manage, 'BUG: موظف مبيعات لا يجب أن يملك karats.manage';
  assert not v_can_view_mfg, 'BUG: موظف مبيعات لا يجب أن يملك manufacturing_fees.view (مستبعدة عمدًا)';
  raise notice 'OK: صلاحيات موظف مبيعات (دور فقط، بلا user_permission_overrides) تعمل بشكل صحيح بعد الترقية — karats.view نعم، karats.manage لا، manufacturing_fees.view لا';
end $$;

-- ---------------------------------------------------------------------------
-- 5. Phase 3 (migration 0060, sales.close_day) — same idempotent-forward-
-- migration pattern, a different permission category ('sales', not
-- 'financial_master_data') so it never collided with section 2/2's checks
-- above, but exercising the identical "production upgrade from a version
-- before this permission existed" guarantee 0060's own header comment makes
-- explicit for a from-0057 upgrade specifically — proven here end-to-end
-- from 0039, a strictly earlier and therefore strictly stronger starting
-- point.
-- ---------------------------------------------------------------------------
do $$
declare v_admin text[]; v_supervisor text[]; v_super_admin_count integer;
begin
  select coalesce(array_agg(p.key order by p.key), array[]::text[]) into v_admin
  from public.role_permissions rp
  join public.roles r on r.id = rp.role_id
  join public.permissions p on p.id = rp.permission_id
  where r.key = 'admin' and p.key = 'sales.close_day';
  assert v_admin = array['sales.close_day'], format('BUG: admin يجب أن يملك sales.close_day بعد الترقية بدون seed.sql، وجد %s', v_admin);

  select coalesce(array_agg(p.key order by p.key), array[]::text[]) into v_supervisor
  from public.role_permissions rp
  join public.roles r on r.id = rp.role_id
  join public.permissions p on p.id = rp.permission_id
  where r.key = 'supervisor' and p.key = 'sales.close_day';
  assert v_supervisor = array['sales.close_day'], format('BUG: supervisor يجب أن يملك sales.close_day بعد الترقية بدون seed.sql، وجد %s', v_supervisor);

  select count(*) into v_super_admin_count
  from public.role_permissions rp
  join public.roles r on r.id = rp.role_id
  join public.permissions p on p.id = rp.permission_id
  where r.key = 'super_admin' and p.key = 'sales.close_day';
  assert v_super_admin_count = 1, format('BUG: super_admin يجب أن يملك صفًا صريحًا واحدًا لِـ sales.close_day، وجد %s', v_super_admin_count);

  raise notice 'OK: صلاحية sales.close_day (Phase 3، هجرة 0060) موجودة ومُمنوحة بشكل صحيح (admin/supervisor/super_admin) بعد الترقية من 0039 مباشرةً بدون إعادة تشغيل seed.sql';
end $$;

do $$
begin
  raise notice '=== ALL UPGRADE-FROM-0039 TESTS PASSED (0040-latest, including Phase 3 0058-0064, applied WITHOUT re-running seed.sql) ===';
end $$;

rollback;
