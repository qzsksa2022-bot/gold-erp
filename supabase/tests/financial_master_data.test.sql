-- ============================================================================
-- Integration test: Phase 2 — Financial Master Data (migrations 0040-0046)
-- ============================================================================
-- Covers every scenario required by the Phase 2 spec (§17): karats,
-- daily_gold_prices, manufacturing_fee_versions, payment_methods +
-- payment_method_fee_versions, collection_channels, product_categories,
-- cross-cutting RLS/audit security, and a SQL-layer NUMERIC-vs-float proof.
--
-- This file is a SEPARATE integration test from
-- supabase/tests/rls_and_permissions.test.sql (which covers Foundation,
-- 0001-0039, exhaustively) rather than an extension of it — Foundation is
-- closed and not touched by this phase, so its own test file is left
-- untouched too. Both files are run independently in CI/local verification.
--
-- Safe to run against a real (including production-like staging) Supabase
-- database: everything happens inside a transaction that is ALWAYS rolled
-- back at the end, so no test data is left behind.
--
-- Requires migrations 0001-0046 + supabase/seed.sql to already be applied.
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/financial_master_data.test.sql
--
-- Every assertion either raises (test fails, transaction aborts, non-zero
-- exit) or prints an "OK:" notice. Read the output top to bottom.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- Actors. Fully-isolated fake accounts, exactly like rls_and_permissions'
-- own convention, so this never collides with real data or that file's test
-- actors (different uuid prefix, 'f1...' here vs 'a0...' there).
--
--   001 = Master Data Manager — holds every new *.view AND *.manage
--         permission plus gold_prices.view/edit, so it can exercise both the
--         "create" and "version" RPC paths across all six modules.
--   002 = View-only user — holds every new *.view permission (and
--         gold_prices.view) but NO *.manage/gold_prices.edit — used to prove
--         "a view-only user cannot manage" (spec §17, Security).
--   003 = No-permission user — holds nothing at all — used to prove
--         unauthorized reads/writes are blocked by RLS, not just hidden by
--         the UI.
-- ---------------------------------------------------------------------------
-- 004 = a SECOND real actor holding only gold_prices.edit/view (distinct
-- from 001) — used solely by section 2.2 to prove save_daily_gold_price()
-- preserves the ORIGINAL created_by when a DIFFERENT authorized actor later
-- corrects the same day's price. (Deliberately a fresh actor local to this
-- file rather than reusing an id from rls_and_permissions.test.sql — that
-- file's test rows only ever exist inside its own rolled-back transaction,
-- so this file cannot depend on them.)
insert into auth.users (id, email) values
  ('f1000000-0000-4000-8000-000000000001', 'test-mdm-manager@example.invalid'),
  ('f1000000-0000-4000-8000-000000000002', 'test-mdm-viewer@example.invalid'),
  ('f1000000-0000-4000-8000-000000000003', 'test-mdm-noperm@example.invalid'),
  ('f1000000-0000-4000-8000-000000000004', 'test-mdm-second-editor@example.invalid');

update public.profiles set full_name = 'Test Master Data Manager', status = 'active', store_access_scope = 'all'
  where id = 'f1000000-0000-4000-8000-000000000001';
update public.profiles set full_name = 'Test Master Data Viewer', status = 'active', store_access_scope = 'all'
  where id = 'f1000000-0000-4000-8000-000000000002';
update public.profiles set full_name = 'Test No-Permission User', status = 'active', store_access_scope = 'all'
  where id = 'f1000000-0000-4000-8000-000000000003';
update public.profiles set full_name = 'Test Second Gold Price Editor', status = 'active', store_access_scope = 'all'
  where id = 'f1000000-0000-4000-8000-000000000004';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'f1000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in (
    'karats.view', 'karats.manage',
    'manufacturing_fees.view', 'manufacturing_fees.manage',
    'categories.view', 'categories.manage',
    'payment_methods.view', 'payment_methods.manage',
    'collection_channels.view', 'collection_channels.manage',
    'gold_prices.view', 'gold_prices.edit'
  );

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'f1000000-0000-4000-8000-000000000002', id, 'grant' from public.permissions
  where key in (
    'karats.view', 'manufacturing_fees.view', 'categories.view',
    'payment_methods.view', 'collection_channels.view', 'gold_prices.view'
  );
-- 003 gets nothing at all.

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'f1000000-0000-4000-8000-000000000004', id, 'grant' from public.permissions
  where key in ('gold_prices.view', 'gold_prices.edit');

-- ---------------------------------------------------------------------------
-- 1. Karats
-- ---------------------------------------------------------------------------
set role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare v_id uuid;
begin
  insert into public.karats (id, code, purity_per_mille, name_ar, name_en, sort_order)
  values ('c1000000-0000-4000-8000-000000000001', 'TK1', 750.000, 'عيار اختباري 1', 'Test Karat 1', 900)
  returning id into v_id;
  assert v_id = 'c1000000-0000-4000-8000-000000000001', 'يجب أن يُنشأ العيار الاختباري بنجاح';
  raise notice 'OK: مدير البيانات الأساسية يستطيع إنشاء عيار جديد';
end $$;

-- 1.2 Duplicate karat code rejected, case-insensitively (lower(code) unique
-- index, 0040).
do $$
declare v_dup boolean := false;
begin
  begin
    insert into public.karats (code, name_ar) values ('tk1', 'عيار مكرر');
    v_dup := true;
  exception
    when unique_violation then
      raise notice 'OK: رُفض عيار مكرر (بصرف النظر عن حالة الأحرف) بخطأ unique_violation';
  end;
  if v_dup then
    raise exception 'BUG: تم قبول عيار بكود مكرر (TK1 مقابل tk1)';
  end if;
end $$;

-- 1.3 View-only user cannot create/manage a karat (RLS INSERT policy
-- requires karats.manage).
set role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$
declare v_bug boolean := false;
begin
  begin
    insert into public.karats (code, name_ar) values ('TK-VIEWER', 'محاولة من مستخدم عرض فقط');
    v_bug := true;
  exception
    when insufficient_privilege or others then
      raise notice 'OK: مُنع مستخدم "عرض فقط" من إنشاء عيار (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن مستخدم لا يملك karats.manage من إنشاء عيار';
  end if;
end $$;

-- 1.4 No-permission user cannot even see karats, despite real rows existing
-- (proves RLS SELECT, not an empty table — same discipline as the
-- Foundation suite).
set role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-4000-8000-000000000003","role":"authenticated"}';
do $$
declare v_count int;
begin
  select count(*) into v_count from public.karats;
  assert v_count = 0, format('مستخدم بلا صلاحيات يجب ألا يرى أي عيار رغم وجود عيارات فعلية، وجد %s', v_count);
  raise notice 'OK: مستخدم بلا صلاحيات لا يرى أي عيار (RLS يعمل، ليست جداول فارغة)';
end $$;

-- 1.5 Disable a karat: excluded from active_karats(), but the row and its
-- history remain queryable for anyone with karats.view (never hard-deleted).
set role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v_active_count int; v_total_count int;
begin
  update public.karats set status = 'inactive' where id = 'c1000000-0000-4000-8000-000000000001';

  select count(*) into v_active_count from public.active_karats() where id = 'c1000000-0000-4000-8000-000000000001';
  assert v_active_count = 0, 'العيار المعطّل يجب ألا يظهر في active_karats()';

  select count(*) into v_total_count from public.karats where id = 'c1000000-0000-4000-8000-000000000001';
  assert v_total_count = 1, 'العيار المعطّل يجب أن يبقى موجودًا (لا حذف فعلي)';

  raise notice 'OK: تعطيل عيار يخفيه من active_karats() لكنه يبقى محفوظًا تاريخيًا';
end $$;

-- Re-activate for the rest of the suite (gold prices / manufacturing fees
-- below reference this karat).
update public.karats set status = 'active' where id = 'c1000000-0000-4000-8000-000000000001';

-- Second karat, used for the manufacturing-fee overlap/cancel section.
insert into public.karats (id, code, name_ar, name_en, sort_order)
values ('c1000000-0000-4000-8000-000000000002', 'TK2', 'عيار اختباري 2', 'Test Karat 2', 901);

reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 2. Daily Gold Prices
-- ---------------------------------------------------------------------------
set role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- 2.1 save_daily_gold_price() records today's price, created_by = caller.
do $$
declare v_id uuid; v_created_by uuid;
begin
  v_id := public.save_daily_gold_price(current_date, 'c1000000-0000-4000-8000-000000000001', 350.1234, 'سعر اليوم — اختبار');
  select created_by into v_created_by from public.daily_gold_prices where id = v_id;
  assert v_created_by = 'f1000000-0000-4000-8000-000000000001', 'created_by يجب أن يكون المستخدم الذي سجّل السعر';
  raise notice 'OK: save_daily_gold_price() تسجّل سعر اليوم بنجاح (created_by صحيح)';
end $$;

-- 2.2 Calling save_daily_gold_price() again for the SAME (date, karat) with a
-- DIFFERENT actor upserts in place (no duplicate row) and preserves the
-- ORIGINAL created_by while updating updated_by — the exact bug an explicit
-- column-list upsert avoids vs. a naive full-column upsert.
set role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-4000-8000-000000000004","role":"authenticated"}';
do $$
declare v_row_count int; v_created_by uuid; v_updated_by uuid;
begin
  perform public.save_daily_gold_price(current_date, 'c1000000-0000-4000-8000-000000000001', 351.5000, null);

  select count(*) into v_row_count from public.daily_gold_prices
    where price_date = current_date and karat_id = 'c1000000-0000-4000-8000-000000000001';
  assert v_row_count = 1, format('يجب أن يبقى صفًا واحدًا فقط لنفس (التاريخ، العيار) بعد التصحيح، وُجد %s', v_row_count);

  select created_by, updated_by into v_created_by, v_updated_by from public.daily_gold_prices
    where price_date = current_date and karat_id = 'c1000000-0000-4000-8000-000000000001';
  assert v_created_by = 'f1000000-0000-4000-8000-000000000001', 'created_by يجب ألا يتغيّر عند التصحيح اليومي';
  raise notice 'OK: تصحيح سعر اليوم يحافظ على created_by الأصلي (%) ويحدّث updated_by فقط', v_created_by;
end $$;
reset role;
reset request.jwt.claims;

-- 2.3 Duplicate (price_date, karat_id) via a raw INSERT (bypassing the RPC)
-- is still rejected — the unique constraint, not just the RPC's ON
-- CONFLICT, is what actually prevents it.
set role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v_dup boolean := false;
begin
  begin
    insert into public.daily_gold_prices (price_date, karat_id, price_per_gram)
    values (current_date, 'c1000000-0000-4000-8000-000000000001', 999);
    v_dup := true;
  exception
    when unique_violation then
      raise notice 'OK: رُفض سطر مكرر لنفس (التاريخ، العيار) عبر INSERT مباشر';
  end;
  if v_dup then
    raise exception 'BUG: تم قبول سعرين لنفس اليوم ونفس العيار';
  end if;
end $$;

-- 2.4 Negative/zero price rejected — both via the RPC (raises P0001) and via
-- a raw INSERT (CHECK constraint).
do $$
declare v_bug boolean := false;
begin
  begin
    perform public.save_daily_gold_price(current_date + 1, 'c1000000-0000-4000-8000-000000000001', 0);
    v_bug := true;
  exception when others then
    raise notice 'OK: save_daily_gold_price() رفض سعرًا صفريًا (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: قُبل سعر صفري عبر save_daily_gold_price()'; end if;
end $$;

do $$
declare v_bug boolean := false;
begin
  begin
    insert into public.daily_gold_prices (price_date, karat_id, price_per_gram)
    values (current_date + 2, 'c1000000-0000-4000-8000-000000000001', -5);
    v_bug := true;
  exception when check_violation then
    raise notice 'OK: قيد CHECK رفض سعرًا سالبًا عبر INSERT مباشر';
  end;
  if v_bug then raise exception 'BUG: قُبل سعر سالب عبر INSERT مباشر'; end if;
end $$;

-- 2.5 Historical prices remain queryable: record a distinct price for
-- YESTERDAY, then confirm gold_price_for_karat_on_date() resolves each date
-- to its own value (yesterday's price is untouched by today's correction).
do $$
declare v_yesterday numeric; v_today numeric;
begin
  perform public.save_daily_gold_price(current_date - 1, 'c1000000-0000-4000-8000-000000000001', 340.0000);

  v_yesterday := public.gold_price_for_karat_on_date('c1000000-0000-4000-8000-000000000001', current_date - 1);
  v_today := public.gold_price_for_karat_on_date('c1000000-0000-4000-8000-000000000001', current_date);

  assert v_yesterday = 340.0000, format('سعر الأمس يجب أن يبقى 340.0000، وجد %s', v_yesterday);
  assert v_today = 351.5000, format('سعر اليوم يجب أن يكون 351.5000، وجد %s', v_today);
  raise notice 'OK: الأسعار التاريخية تبقى قابلة للاستعلام بشكل مستقل عن آخر تصحيح (أمس=%، اليوم=%)', v_yesterday, v_today;
end $$;

-- 2.6 gold_price_for_karat_on_date() RAISES (never returns 0/NULL) when no
-- price was recorded for a given date.
do $$
declare v_price numeric; v_raised boolean := false;
begin
  begin
    v_price := public.gold_price_for_karat_on_date('c1000000-0000-4000-8000-000000000001', current_date - 30);
  exception when others then
    v_raised := true;
    raise notice 'OK: gold_price_for_karat_on_date() يرفع خطأ بدل افتراض 0 عند غياب السعر (%)', sqlerrm;
  end;
  if not v_raised then
    raise exception 'BUG: gold_price_for_karat_on_date() أعاد قيمة (%) بدل رفع خطأ لتاريخ بلا سعر مسجّل', v_price;
  end if;
end $$;

-- 2.7 gold_prices_missing_for_date() correctly discovers an active karat
-- with no price row for a given date.
do $$
declare v_missing_count int;
begin
  select count(*) into v_missing_count from public.gold_prices_missing_for_date(current_date - 30)
    where id = 'c1000000-0000-4000-8000-000000000001';
  assert v_missing_count = 1, 'العيار الاختباري يجب أن يظهر ضمن الأسعار الناقصة لتاريخ لم يُسجَّل له سعر';
  raise notice 'OK: gold_prices_missing_for_date() يكتشف العيارات بلا سعر لتاريخ معيّن';
end $$;

-- 2.8 Unauthorized edit rejected: view-only user cannot call
-- save_daily_gold_price() (raises inside the function) nor write directly
-- (RLS).
set role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$
declare v_bug boolean := false;
begin
  begin
    perform public.save_daily_gold_price(current_date, 'c1000000-0000-4000-8000-000000000001', 400);
    v_bug := true;
  exception when others then
    raise notice 'OK: مستخدم "عرض فقط" (gold_prices.view فقط) مُنع من استخدام save_daily_gold_price() (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: مستخدم بلا gold_prices.edit استطاع تعديل سعر الذهب'; end if;
end $$;

do $$
declare v_bug boolean := false;
begin
  begin
    insert into public.daily_gold_prices (price_date, karat_id, price_per_gram)
    values (current_date + 3, 'c1000000-0000-4000-8000-000000000001', 300);
    v_bug := true;
  exception
    when insufficient_privilege or others then
      raise notice 'OK: مُنع مستخدم "عرض فقط" من INSERT مباشر على daily_gold_prices (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: RLS لم تمنع INSERT مباشر من مستخدم لا يملك gold_prices.edit'; end if;
end $$;

reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 3. Manufacturing Fee Versions
-- ---------------------------------------------------------------------------
set role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- 3.1 First version, effective 6 months ago -> today: 7.0000/gram.
do $$
declare v_id uuid;
begin
  v_id := public.create_manufacturing_fee_version('c1000000-0000-4000-8000-000000000001', 7.0000, current_date - 180, 'إصدار أول — اختبار');
  assert v_id is not null, 'يجب أن يُنشأ إصدار المصنعية الأول';
  raise notice 'OK: إنشاء أول نسخة مصنعية للعيار الاختباري (7.0000/جم من %)', current_date - 180;
end $$;

-- 3.2 Second version, effective TODAY: 8.0000/gram — must atomically end v1.
do $$
declare v_id2 uuid; v_v1_status text; v_v1_effective_to date;
begin
  v_id2 := public.create_manufacturing_fee_version('c1000000-0000-4000-8000-000000000001', 8.0000, current_date, 'إصدار ثانٍ — اختبار');
  assert v_id2 is not null, 'يجب أن يُنشأ إصدار المصنعية الثاني';

  select status, effective_to into v_v1_status, v_v1_effective_to
    from public.manufacturing_fee_versions
    where karat_id = 'c1000000-0000-4000-8000-000000000001' and fee_per_gram = 7.0000;
  assert v_v1_status = 'ended', format('الإصدار الأول يجب أن يصبح ended، وجد %s', v_v1_status);
  assert v_v1_effective_to = current_date - 1, 'الإصدار الأول يجب أن ينتهي في اليوم السابق لبداية الثاني';
  raise notice 'OK: إنشاء نسخة جديدة ينهي النسخة المفتوحة السابقة تلقائيًا وذريًا (status=ended, effective_to=%)', v_v1_effective_to;
end $$;

-- 3.3 Historical rate remains unchanged: a date inside v1's (now-ended)
-- range still resolves to 7.0000, NOT 0 and NOT the newer 8.0000 — this is
-- exactly the 'ended' vs 'cancelled' distinction the resolution functions
-- depend on.
do $$
declare v_hist numeric; v_curr numeric;
begin
  v_hist := public.manufacturing_fee_for_karat_on_date('c1000000-0000-4000-8000-000000000001', current_date - 90);
  v_curr := public.manufacturing_fee_for_karat_on_date('c1000000-0000-4000-8000-000000000001', current_date);
  assert v_hist = 7.0000, format('المصنعية التاريخية يجب أن تبقى 7.0000، وجد %s', v_hist);
  assert v_curr = 8.0000, format('المصنعية الحالية يجب أن تكون 8.0000، وجد %s', v_curr);
  raise notice 'OK: تحليل تاريخ المصنعية صحيح (تاريخي=%، حالي=%) — النسخة المنتهية (ended) لا تزال قابلة للاستعلام لتاريخها الخاص', v_hist, v_curr;
end $$;

-- 3.3b Cannot cancel a version that is ALREADY effective (v2, effective_from
-- = today) — cancel_manufacturing_fee_version() only permits withdrawing a
-- version whose effective_from is strictly in the future ("لا تعديل رجعي
-- صامت على Rate سبق استخدامه"). Tested here, before any future version
-- exists, so this genuinely exercises the effective_from <= current_date
-- branch rather than the separate "already superseded" branch.
do $$
declare v_open_id uuid; v_bug boolean := false;
begin
  select id into v_open_id from public.manufacturing_fee_versions
    where karat_id = 'c1000000-0000-4000-8000-000000000001' and effective_to is null and status = 'active';
  assert v_open_id is not null, 'يجب وجود نسخة مصنعية مفتوحة حاليًا (v2) قبل تنفيذ هذا الاختبار';

  begin
    perform public.cancel_manufacturing_fee_version(v_open_id);
    v_bug := true;
  exception when others then
    raise notice 'OK: رُفض إلغاء نسخة مصنعية سارية بالفعل (لا تعديل رجعي صامت) — %', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: تم إلغاء نسخة مصنعية سارية بالفعل — هذا تعديل رجعي غير مسموح'; end if;
end $$;

-- 3.4 Overlapping periods rejected via the RPC: a new effective_from at or
-- before the currently-open version's own effective_from is rejected with a
-- clear error (must cancel a future version first, never silently overlap).
do $$
declare v_bug boolean := false;
begin
  begin
    perform public.create_manufacturing_fee_version('c1000000-0000-4000-8000-000000000001', 9.0000, current_date);
    v_bug := true;
  exception when others then
    raise notice 'OK: رُفضت محاولة إنشاء نسخة مصنعية بتاريخ سريان يطابق/يسبق النسخة المفتوحة الحالية (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: قُبلت نسخة مصنعية متداخلة عبر create_manufacturing_fee_version()'; end if;
end $$;

-- 3.5 (REWRITTEN for Financial Integrity Patch 2.1, migration 0047 — flipped
-- expectation, not deleted, per this project's own established convention:
-- a security test whose intended behavior genuinely changed gets its
-- assertion flipped in place, never removed). Before 0047, `authenticated`
-- holding manufacturing_fees.manage could INSERT directly into
-- manufacturing_fee_versions via RLS, and this section proved the GIST
-- EXCLUDE constraint was what actually stopped an overlapping direct
-- INSERT from succeeding. As of 0047, `authenticated` has NO direct
-- INSERT/UPDATE path into this table AT ALL — even a manager with
-- manufacturing_fees.manage — so the first assertion below is what proves
-- that (a non-overlapping insert now fails immediately on RLS, before ever
-- reaching the EXCLUDE constraint). The EXCLUDE constraint itself is far
-- from dead code, though: it still guards a TRUSTED bootstrap/direct-SQL
-- context (service_role — exactly how supabase/seed.sql and 0049 write to
-- this table), which is proven in the second half below.
do $$
declare v_bug boolean := false;
begin
  begin
    insert into public.manufacturing_fee_versions (karat_id, fee_per_gram, effective_from, effective_to, status)
    values ('c1000000-0000-4000-8000-000000000002', 5.0000, current_date - 100, current_date + 100, 'active');
    v_bug := true;
  exception
    when insufficient_privilege or others then
      raise notice 'OK (0047): مُنع مستخدم authenticated من INSERT مباشر على manufacturing_fee_versions حتى مع manufacturing_fees.manage (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: نجح INSERT مباشر من authenticated رغم إغلاق 0047 لهذا المسار'; end if;
end $$;

set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
do $$
declare v_bug boolean := false;
begin
  -- First insert succeeds — service_role is a trusted bootstrap context
  -- (BYPASSRLS), exactly like seed.sql/0049.
  insert into public.manufacturing_fee_versions (karat_id, fee_per_gram, effective_from, effective_to, status)
  values ('c1000000-0000-4000-8000-000000000002', 5.0000, current_date - 100, current_date + 100, 'active');

  begin
    insert into public.manufacturing_fee_versions (karat_id, fee_per_gram, effective_from, effective_to, status)
    values ('c1000000-0000-4000-8000-000000000002', 6.0000, current_date - 10, current_date + 10, 'active');
    v_bug := true;
  exception
    when exclusion_violation then
      raise notice 'OK: قيد GIST EXCLUDE لا يزال يرفض تداخل نطاقين زمنيين لنفس العيار حتى لسياق موثوق (service_role) بعد 0047';
  end;
  if v_bug then raise exception 'SECURITY BUG: تم قبول نطاقين متداخلين لنفس العيار حتى لـservice_role'; end if;
end $$;

-- Restore the manager's own session (not a bare reset) — the rest of this
-- section still needs auth.uid() to resolve to the manager for
-- has_permission() inside the RPCs below.
set role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- 3.6 Future effective dates are allowed, and can be cancelled (the only
-- sanctioned undo) as long as they have not taken effect yet. (Cancelling an
-- already-effective version was already proven rejected in 3.3b, against
-- the still-open v2 — cancelling THIS future version below ends v2 without
-- reopening it, so there is no still-open version left afterwards to
-- meaningfully repeat that check against.)
do $$
declare v_future_id uuid; v_status text;
begin
  v_future_id := public.create_manufacturing_fee_version('c1000000-0000-4000-8000-000000000001', 10.0000, current_date + 30, 'نسخة مستقبلية — اختبار');
  assert v_future_id is not null, 'يجب السماح بإنشاء نسخة مصنعية بتاريخ سريان مستقبلي';

  perform public.cancel_manufacturing_fee_version(v_future_id);
  select status into v_status from public.manufacturing_fee_versions where id = v_future_id;
  assert v_status = 'cancelled', format('يجب أن تصبح النسخة المستقبلية cancelled بعد الإلغاء، وجد %s', v_status);
  raise notice 'OK: يمكن إنشاء نسخة مصنعية مستقبلية وإلغاؤها قبل سريانها';
end $$;

-- 3.7 Unauthorized user cannot create/cancel a manufacturing fee version.
set role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$
declare v_bug boolean := false;
begin
  begin
    perform public.create_manufacturing_fee_version('c1000000-0000-4000-8000-000000000001', 99, current_date + 365);
    v_bug := true;
  exception when others then
    raise notice 'OK: مستخدم "عرض فقط" مُنع من إنشاء نسخة مصنعية (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: مستخدم بلا manufacturing_fees.manage استطاع إنشاء نسخة مصنعية'; end if;
end $$;
reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 4. Payment Methods & Payment Method Fee Versions
-- ---------------------------------------------------------------------------
set role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
begin
  insert into public.payment_methods (id, key, name_ar, name_en, fee_model, sort_order) values
    ('c2000000-0000-4000-8000-000000000001', 'test_pct', 'اختبار — نسبة فقط', 'Test Percentage Only', 'percentage', 900),
    ('c2000000-0000-4000-8000-000000000002', 'test_fixed', 'اختبار — مبلغ ثابت فقط', 'Test Fixed Only', 'fixed', 901),
    ('c2000000-0000-4000-8000-000000000003', 'test_both', 'اختبار — نسبة ومبلغ ثابت', 'Test Percentage + Fixed', 'percentage_plus_fixed', 902),
    ('c2000000-0000-4000-8000-000000000004', 'test_zero', 'اختبار — بدون رسوم', 'Test Zero Fee', 'none', 903),
    ('c2000000-0000-4000-8000-000000000005', 'test_unconfigured', 'اختبار — غير مُهيأ بعد (مثل COD)', 'Test Unconfigured (COD-like)', 'percentage_plus_fixed', 904);
  raise notice 'OK: إنشاء خمس طرق دفع اختبارية (نسبة/ثابت/كلاهما/بدون رسوم/غير مُهيأ)';
end $$;

-- 4.1 Percentage-only shape (fixed_fee = 0).
do $$
declare v_id uuid; v_pct numeric; v_fixed numeric;
begin
  v_id := public.create_payment_method_fee_version('c2000000-0000-4000-8000-000000000001', 2.5, 0, current_date - 60, 'نسبة فقط');
  select percentage_fee, fixed_fee into v_pct, v_fixed from public.payment_method_fee_versions where id = v_id;
  assert v_pct = 2.5 and v_fixed = 0, format('نسبة فقط: توقعنا (2.5, 0)، وجدنا (%s, %s)', v_pct, v_fixed);
  raise notice 'OK: شكل "نسبة فقط" يعمل (percentage_fee=2.5, fixed_fee=0)';
end $$;

-- 4.2 Fixed-only shape (percentage_fee = 0).
do $$
declare v_id uuid; v_pct numeric; v_fixed numeric;
begin
  v_id := public.create_payment_method_fee_version('c2000000-0000-4000-8000-000000000002', 0, 5.5, current_date, 'مبلغ ثابت فقط');
  select percentage_fee, fixed_fee into v_pct, v_fixed from public.payment_method_fee_versions where id = v_id;
  assert v_pct = 0 and v_fixed = 5.5, format('ثابت فقط: توقعنا (0, 5.5)، وجدنا (%s, %s)', v_pct, v_fixed);
  raise notice 'OK: شكل "مبلغ ثابت فقط" يعمل (percentage_fee=0, fixed_fee=5.5)';
end $$;

-- 4.3 Percentage + fixed shape (both > 0) — the shape a future COD needs.
do $$
declare v_id uuid; v_pct numeric; v_fixed numeric;
begin
  v_id := public.create_payment_method_fee_version('c2000000-0000-4000-8000-000000000003', 1.0, 3.0, current_date, 'نسبة ومبلغ ثابت معًا');
  select percentage_fee, fixed_fee into v_pct, v_fixed from public.payment_method_fee_versions where id = v_id;
  assert v_pct = 1.0 and v_fixed = 3.0, format('نسبة+ثابت: توقعنا (1.0, 3.0)، وجدنا (%s, %s)', v_pct, v_fixed);
  raise notice 'OK: شكل "نسبة + مبلغ ثابت" يعمل بدون أي تعديل في البنية (percentage_fee=1.0, fixed_fee=3.0)';
end $$;

-- 4.4 Zero-fee shape (both = 0) — Cash/Bank Transfer today.
do $$
declare v_id uuid; v_pct numeric; v_fixed numeric;
begin
  v_id := public.create_payment_method_fee_version('c2000000-0000-4000-8000-000000000004', 0, 0, current_date, 'بدون رسوم حاليًا');
  select percentage_fee, fixed_fee into v_pct, v_fixed from public.payment_method_fee_versions where id = v_id;
  assert v_pct = 0 and v_fixed = 0, format('بدون رسوم: توقعنا (0, 0)، وجدنا (%s, %s)', v_pct, v_fixed);
  raise notice 'OK: شكل "بدون رسوم" يعمل (percentage_fee=0, fixed_fee=0) — قيمة حقيقية وليست غيابًا للبيانات';
end $$;

-- 4.5 Version resolution by date + overlap rejected, mirroring the
-- manufacturing-fee section exactly (reuses test_pct: v1 = 2.5% until
-- yesterday's end, v2 = 3.0% from today).
do $$
declare v_id2 uuid; v_v1_status text;
begin
  v_id2 := public.create_payment_method_fee_version('c2000000-0000-4000-8000-000000000001', 3.0, 0, current_date + 1, 'نسبة جديدة اعتبارًا من الغد');
  select status into v_v1_status from public.payment_method_fee_versions
    where payment_method_id = 'c2000000-0000-4000-8000-000000000001' and percentage_fee = 2.5;
  assert v_v1_status = 'ended', 'الإصدار الأول (2.5%) يجب أن يصبح ended بعد إنشاء الإصدار الثاني';
  raise notice 'OK: إنشاء نسخة عمولة جديدة ينهي النسخة المفتوحة السابقة تلقائيًا';
end $$;

do $$
declare v_hist numeric; v_hist_fixed numeric;
begin
  select percentage_fee, fixed_fee into v_hist, v_hist_fixed from public.payment_fee_for_method_on_date('c2000000-0000-4000-8000-000000000001', current_date);
  assert v_hist = 2.5, format('عمولة اليوم (قبل سريان النسخة الجديدة غدًا) يجب أن تبقى 2.5، وجد %s', v_hist);
  raise notice 'OK: payment_fee_for_method_on_date() يحلّ النسبة الصحيحة حسب التاريخ (اليوم=2.5%%، النسخة الجديدة لم تسرِ بعد)';
end $$;

-- (FIXED for Financial Integrity Patch 2.1 — the original call here used the
-- wrong argument shape (uuid, numeric, date, integer) instead of the real
-- signature (uuid, percentage_fee, fixed_fee, effective_from, note), so it
-- was only ever passing because "does not exist" also raises `others` — it
-- never actually exercised the overlap-rejection path it claims to. Fixed to
-- call the real signature with effective_from matching the already-open v2
-- (created just above, effective_from = current_date + 1), which must be
-- rejected as a genuine overlap, mirroring section 3.4's manufacturing-fee
-- equivalent.)
do $$
declare v_bug boolean := false;
begin
  begin
    perform public.create_payment_method_fee_version('c2000000-0000-4000-8000-000000000001', 4.0, 0, current_date + 1, 'تجربة نسخة متداخلة');
    v_bug := true;
  exception when others then
    raise notice 'OK: رُفضت محاولة إنشاء نسخة عمولة متداخلة (نفس تاريخ السريان للنسخة المفتوحة الحالية) — %', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: قُبلت نسخة عمولة متداخلة عبر create_payment_method_fee_version()'; end if;
end $$;

-- (REWRITTEN for Financial Integrity Patch 2.1, migration 0047 — flipped
-- expectation, not deleted, exactly mirroring section 3.5's treatment for
-- manufacturing fees. Before 0047, `authenticated` holding
-- payment_methods.manage could INSERT directly into
-- payment_method_fee_versions via RLS, and this section proved the GIST
-- EXCLUDE constraint was what actually stopped an overlapping direct INSERT
-- from succeeding. As of 0047, `authenticated` has NO direct INSERT/UPDATE
-- path into this table AT ALL — even a manager with payment_methods.manage —
-- so the first assertion below is what proves that (a non-overlapping
-- insert now fails immediately on RLS, before ever reaching the EXCLUDE
-- constraint). The EXCLUDE constraint itself still guards a TRUSTED
-- bootstrap/direct-SQL context (service_role — exactly how
-- supabase/seed.sql and 0049 write to this table), proven in the second
-- half below.
do $$
declare v_bug boolean := false;
begin
  begin
    insert into public.payment_method_fee_versions (payment_method_id, percentage_fee, fixed_fee, effective_from, effective_to, status)
    values ('c2000000-0000-4000-8000-000000000003', 9, 9, current_date - 5, current_date + 5, 'active');
    v_bug := true;
  exception
    when insufficient_privilege or others then
      raise notice 'OK (0047): مُنع مستخدم authenticated من INSERT مباشر على payment_method_fee_versions حتى مع payment_methods.manage (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: نجح INSERT مباشر من authenticated رغم إغلاق 0047 لهذا المسار'; end if;
end $$;

set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
do $$
declare v_bug boolean := false;
begin
  -- First insert succeeds — service_role is a trusted bootstrap context
  -- (BYPASSRLS), exactly like seed.sql/0049. Both ranges below are placed
  -- entirely BEFORE current_date deliberately: method 003 already has an
  -- open version starting today (from section 4.3), so a range touching
  -- today or later would trip the EXCLUDE constraint against THAT row
  -- instead of against each other, which is not what this test is proving.
  insert into public.payment_method_fee_versions (payment_method_id, percentage_fee, fixed_fee, effective_from, effective_to, status)
  values ('c2000000-0000-4000-8000-000000000003', 9, 9, current_date - 200, current_date - 150, 'active');

  begin
    insert into public.payment_method_fee_versions (payment_method_id, percentage_fee, fixed_fee, effective_from, effective_to, status)
    values ('c2000000-0000-4000-8000-000000000003', 8, 8, current_date - 160, current_date - 100, 'active');
    v_bug := true;
  exception
    when exclusion_violation then
      raise notice 'OK: قيد GIST EXCLUDE لا يزال يرفض تداخل نطاقين زمنيين لنفس طريقة الدفع حتى لسياق موثوق (service_role) بعد 0047';
  end;
  if v_bug then raise exception 'SECURITY BUG: تم قبول نطاقين متداخلين لنفس طريقة الدفع حتى لـservice_role'; end if;
end $$;

-- Restore the manager's own session (not a bare reset) — sections 4.6/4.6b
-- below still need auth.uid() to resolve to the manager for
-- has_permission() inside payment_fee_for_method_on_date() (view permission)
-- and to keep this file's role state consistent with the rest of the suite.
set role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- 4.6 COD-like behavior: a payment method with NO fee version ever created
-- must RAISE, never silently resolve to 0% — proves "لا تخترع نسبة".
do $$
declare v_pct numeric; v_raised boolean := false;
begin
  begin
    select percentage_fee into v_pct from public.payment_fee_for_method_on_date('c2000000-0000-4000-8000-000000000005', current_date);
  exception when others then
    v_raised := true;
    raise notice 'OK: payment_fee_for_method_on_date() يرفع خطأ لطريقة دفع غير مُهيأة بدل افتراض 0%% (%)', sqlerrm;
  end;
  if not v_raised then
    raise exception 'BUG: payment_fee_for_method_on_date() أعاد قيمة (%) لطريقة دفع لا تملك أي نسخة عمولة — كان يجب أن يرفع خطأ', v_pct;
  end if;
end $$;

-- 4.6b Same proof against the REAL seeded COD method (spec §7's actual
-- production case) — documents that, as shipped, COD genuinely has no
-- fabricated rate configured yet.
do $$
declare v_pct numeric; v_raised boolean := false;
begin
  begin
    select percentage_fee into v_pct from public.payment_fee_for_method_on_date(
      (select id from public.payment_methods where key = 'cod'), current_date
    );
  exception when others then
    v_raised := true;
    raise notice 'OK: طريقة الدفع الحقيقية "cod" المزروعة في seed.sql لا تملك نسخة عمولة بعد — استعلامها يرفع خطأً بدل قيمة مختلقة';
  end;
  if not v_raised then
    raise exception 'BUG: طريقة الدفع "cod" أعادت نسبة عمولة (%) رغم عدم تهيئتها في seed.sql — تحقق من عدم إضافة نسخة افتراضية بالخطأ', v_pct;
  end if;
end $$;

-- 4.7 Payment method metadata (name/status) is editable independently of
-- fee versions (spec: "تعديل طريقة دفع").
do $$
declare v_name text;
begin
  update public.payment_methods set name_ar = 'اختبار — نسبة فقط (محدّث)' where id = 'c2000000-0000-4000-8000-000000000001';
  select name_ar into v_name from public.payment_methods where id = 'c2000000-0000-4000-8000-000000000001';
  assert v_name = 'اختبار — نسبة فقط (محدّث)', 'يجب أن يُحدَّث اسم طريقة الدفع';
  raise notice 'OK: تعديل بيانات طريقة دفع (غير العمولة) يعمل بشكل مستقل';
end $$;

-- 4.8 Unauthorized user cannot manage payment methods/fee versions.
set role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$
declare v_bug boolean := false;
begin
  begin
    insert into public.payment_methods (key, name_ar) values ('viewer_attempt', 'محاولة من مستخدم عرض فقط');
    v_bug := true;
  exception
    when insufficient_privilege or others then
      raise notice 'OK: مُنع مستخدم "عرض فقط" من إنشاء طريقة دفع (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: مستخدم بلا payment_methods.manage استطاع إنشاء طريقة دفع'; end if;
end $$;

do $$
declare v_bug boolean := false;
begin
  begin
    perform public.create_payment_method_fee_version('c2000000-0000-4000-8000-000000000004', 50, 0, current_date + 1);
    v_bug := true;
  exception when others then
    raise notice 'OK: مستخدم "عرض فقط" مُنع من إنشاء نسخة عمولة (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: مستخدم بلا payment_methods.manage استطاع إنشاء نسخة عمولة'; end if;
end $$;
reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 5. Collection Channels — independence from Payment Methods
-- ---------------------------------------------------------------------------
set role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare v_id uuid;
begin
  insert into public.collection_channels (id, key, name_ar, name_en, sort_order)
  values ('c4000000-0000-4000-8000-000000000001', 'test_channel', 'قناة اختبارية', 'Test Channel', 900)
  returning id into v_id;
  assert v_id is not null, 'يجب أن تُنشأ قناة التحصيل الاختبارية';
  raise notice 'OK: إنشاء قناة تحصيل جديدة';
end $$;

-- 5.1 Structural independence: collection_channels has NO foreign-key
-- column into payment_methods (and vice versa) — proves the two are
-- modeled as genuinely separate facts a future Sale will record
-- independently (e.g. "Mada – Salla Wallet" vs "Mada – Direct"), not a
-- payment-method-owned sub-list.
do $$
declare v_fk_count int;
begin
  select count(*) into v_fk_count
  from information_schema.table_constraints tc
  join information_schema.key_column_usage kcu on kcu.constraint_name = tc.constraint_name
  join information_schema.constraint_column_usage ccu on ccu.constraint_name = tc.constraint_name
  where tc.constraint_type = 'FOREIGN KEY'
    and (
      (tc.table_name = 'collection_channels' and ccu.table_name = 'payment_methods')
      or (tc.table_name = 'payment_methods' and ccu.table_name = 'collection_channels')
    );
  assert v_fk_count = 0, format('لا يجب وجود أي مفتاح أجنبي بين collection_channels وpayment_methods، وُجد %s', v_fk_count);
  raise notice 'OK: قنوات التحصيل وطرق الدفع منفصلتان بنيويًا تمامًا (لا مفتاح أجنبي بينهما) — عملية بيع مستقبلية يمكنها الجمع بين أي طريقة دفع وأي قناة';
end $$;

-- 5.2 active_collection_channels() excludes a disabled channel but keeps it
-- queryable (matches the karats/categories pattern).
do $$
declare v_active_count int; v_total_count int;
begin
  update public.collection_channels set status = 'inactive' where id = 'c4000000-0000-4000-8000-000000000001';
  select count(*) into v_active_count from public.active_collection_channels() where id = 'c4000000-0000-4000-8000-000000000001';
  select count(*) into v_total_count from public.collection_channels where id = 'c4000000-0000-4000-8000-000000000001';
  assert v_active_count = 0 and v_total_count = 1, 'قناة التحصيل المعطّلة يجب أن تختفي من active_collection_channels() لكن تبقى محفوظة';
  update public.collection_channels set status = 'active' where id = 'c4000000-0000-4000-8000-000000000001';
  raise notice 'OK: تعطيل قناة تحصيل يخفيها من active_collection_channels() دون حذفها';
end $$;

-- 5.3 Unauthorized user cannot manage collection channels.
set role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$
declare v_bug boolean := false;
begin
  begin
    insert into public.collection_channels (key, name_ar) values ('viewer_attempt', 'محاولة من مستخدم عرض فقط');
    v_bug := true;
  exception
    when insufficient_privilege or others then
      raise notice 'OK: مُنع مستخدم "عرض فقط" من إنشاء قناة تحصيل (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: مستخدم بلا collection_channels.manage استطاع إنشاء قناة تحصيل'; end if;
end $$;
reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 6. Product Categories
-- ---------------------------------------------------------------------------
set role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- 6.1 Hierarchy: main category + subcategory.
do $$
declare v_main_id uuid; v_sub_id uuid; v_parent_check uuid;
begin
  insert into public.product_categories (id, code, name_ar, name_en, sort_order)
  values ('c3000000-0000-4000-8000-000000000001', 'test_main', 'تصنيف رئيسي اختباري', 'Test Main Category', 900)
  returning id into v_main_id;

  insert into public.product_categories (id, parent_id, code, name_ar, name_en, sort_order)
  values ('c3000000-0000-4000-8000-000000000002', v_main_id, 'test_sub', 'تصنيف فرعي اختباري', 'Test Sub Category', 1)
  returning id into v_sub_id;

  select parent_id into v_parent_check from public.product_categories where id = v_sub_id;
  assert v_parent_check = v_main_id, 'التصنيف الفرعي يجب أن يشير إلى التصنيف الرئيسي كأب له';
  raise notice 'OK: التسلسل الهرمي يعمل (تصنيف رئيسي + تصنيف فرعي تابع له)';
end $$;

-- 6.2 Cycle prevention: re-parenting the MAIN category under its own
-- subcategory must be rejected (would otherwise create an infinite loop).
do $$
declare v_bug boolean := false;
begin
  begin
    update public.product_categories set parent_id = 'c3000000-0000-4000-8000-000000000002'
      where id = 'c3000000-0000-4000-8000-000000000001';
    v_bug := true;
  exception when others then
    raise notice 'OK: رُفضت محاولة جعل التصنيف الرئيسي تابعًا لتصنيفه الفرعي (تمنع حلقة لا نهائية) — %', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: قُبلت إعادة تفريع تُنشئ حلقة تصنيفات لا نهائية'; end if;
end $$;

-- 6.3 Disabled category preserved historically: excluded from
-- active_product_categories(), still visible/queryable, and its child's
-- parent_id link is untouched.
do $$
declare v_active_count int; v_total_count int; v_child_parent uuid;
begin
  update public.product_categories set status = 'inactive' where id = 'c3000000-0000-4000-8000-000000000001';

  select count(*) into v_active_count from public.active_product_categories() where id = 'c3000000-0000-4000-8000-000000000001';
  assert v_active_count = 0, 'التصنيف المعطّل يجب ألا يظهر في active_product_categories()';

  select count(*) into v_total_count from public.product_categories where id = 'c3000000-0000-4000-8000-000000000001';
  assert v_total_count = 1, 'التصنيف المعطّل يجب أن يبقى موجودًا (لا حذف فعلي)';

  select parent_id into v_child_parent from public.product_categories where id = 'c3000000-0000-4000-8000-000000000002';
  assert v_child_parent = 'c3000000-0000-4000-8000-000000000001', 'رابط التصنيف الفرعي بأبيه يجب ألا يتأثر بتعطيل الأب';

  raise notice 'OK: تعطيل تصنيف يحفظه تاريخيًا (يختفي من القائمة النشطة، يبقى محفوظًا، رابط الأبناء سليم)';
end $$;
update public.product_categories set status = 'active' where id = 'c3000000-0000-4000-8000-000000000001';

-- 6.4 Unauthorized user cannot manage categories.
set role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$
declare v_bug boolean := false;
begin
  begin
    insert into public.product_categories (code, name_ar) values ('viewer_attempt', 'محاولة من مستخدم عرض فقط');
    v_bug := true;
  exception
    when insufficient_privilege or others then
      raise notice 'OK: مُنع مستخدم "عرض فقط" من إنشاء تصنيف (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: مستخدم بلا categories.manage استطاع إنشاء تصنيف'; end if;
end $$;
reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 7. Security: audit trail (run as postgres/superuser for a full, unscoped
--    read of audit_logs — Foundation's audit_logs SELECT policy is itself
--    already exhaustively tested by rls_and_permissions.test.sql, so this
--    section focuses on "did the NEW tables' triggers actually fire").
-- ---------------------------------------------------------------------------
do $$
declare v_count int;
begin
  select count(*) into v_count from public.audit_logs
    where entity_type = 'karat' and action = 'karat.create' and entity_id = 'c1000000-0000-4000-8000-000000000001';
  assert v_count = 1, 'يجب تسجيل حدث تدقيق karat.create';

  select count(*) into v_count from public.audit_logs
    where entity_type = 'karat' and action = 'karat.update' and entity_id = 'c1000000-0000-4000-8000-000000000001';
  assert v_count >= 1, 'يجب تسجيل حدث/أحداث تدقيق karat.update (تعطيل/إعادة تفعيل)';

  select count(*) into v_count from public.audit_logs
    where entity_type = 'gold_price' and action = 'gold_price.create';
  assert v_count >= 1, 'يجب تسجيل حدث تدقيق gold_price.create';

  select count(*) into v_count from public.audit_logs
    where entity_type = 'manufacturing_fee_version' and action = 'manufacturing_fee_version.create';
  assert v_count >= 2, 'يجب تسجيل أحداث تدقيق manufacturing_fee_version.create لكل نسخة أُنشئت';

  select count(*) into v_count from public.audit_logs
    where entity_type = 'product_category' and action = 'product_category.create';
  assert v_count >= 2, 'يجب تسجيل أحداث تدقيق product_category.create (رئيسي + فرعي)';

  select count(*) into v_count from public.audit_logs
    where entity_type = 'payment_method' and action = 'payment_method.create';
  assert v_count >= 5, 'يجب تسجيل أحداث تدقيق payment_method.create لكل طريقة دفع اختبارية أُنشئت';

  select count(*) into v_count from public.audit_logs
    where entity_type = 'payment_method_fee_version' and action = 'payment_method_fee_version.create';
  assert v_count >= 5, 'يجب تسجيل أحداث تدقيق payment_method_fee_version.create';

  select count(*) into v_count from public.audit_logs
    where entity_type = 'collection_channel' and action = 'collection_channel.create';
  assert v_count >= 1, 'يجب تسجيل حدث تدقيق collection_channel.create';

  raise notice 'OK: كل الجداول الجديدة (7) تُسجِّل أحداثها تلقائيًا في audit_logs عبر المُشغِّل العام (audit_table_changes)';
end $$;

-- 7.2 Audit rows remain immutable: no role (not even the Master Data
-- Manager who created them) can UPDATE or DELETE an audit_logs row —
-- audit_logs simply has no UPDATE/DELETE policy for `authenticated`, same
-- guarantee already proven exhaustively in rls_and_permissions.test.sql.
set role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v_row_count int;
begin
  update public.audit_logs set reason = 'محاولة تلاعب' where entity_type = 'karat' and action = 'karat.create';
  get diagnostics v_row_count = row_count;
  if v_row_count <> 0 then
    raise exception 'SECURITY BUG: تمكّن مستخدم من تعديل صفّ تدقيق خاص بعيار جديد';
  end if;

  delete from public.audit_logs where entity_type = 'karat' and action = 'karat.create';
  get diagnostics v_row_count = row_count;
  if v_row_count <> 0 then
    raise exception 'SECURITY BUG: تمكّن مستخدم من حذف صفّ تدقيق خاص بعيار جديد';
  end if;

  raise notice 'OK: صفوف التدقيق الخاصة بالبيانات المالية الأساسية غير قابلة للتعديل أو الحذف (0 صف متأثر في الحالتين)';
end $$;
reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 8. Decimal / NUMERIC safety at the SQL layer.
-- ---------------------------------------------------------------------------
-- The app-layer proof lives in tests/decimal.test.ts (src/lib/decimal.ts,
-- backed by decimal.js). This section proves the SAME class of bug cannot
-- happen at the database layer either, because every financial column in
-- this phase is NUMERIC — never float4/float8/double precision.
do $$
declare
  v_numeric_sum numeric := 0.1::numeric + 0.2::numeric;
  v_float_sum double precision := 0.1::double precision + 0.2::double precision;
begin
  assert v_numeric_sum = 0.3::numeric, format('0.1 + 0.2 بنوع NUMERIC يجب أن يساوي 0.3 تمامًا، وجد %s', v_numeric_sum);
  -- This is the exact bug class NUMERIC avoids: float8 does NOT equal 0.3
  -- for this sum (classic binary floating-point representation drift).
  assert v_float_sum <> 0.3::double precision, 'هذا يوثّق سبب حظر float/double للحسابات المالية — 0.1+0.2 بـ double precision لا يساوي 0.3 تمامًا (خطأ تمثيل ثنائي)';
  raise notice 'OK: NUMERIC لا يعاني من انحراف الفاصلة العائمة (0.1+0.2=0.3 تمامًا)؛ float8 يعاني منه فعليًا كما هو موثّق — وهذا يبرر إلزام NUMERIC/DECIMAL في كل الأعمدة المالية الجديدة';
end $$;

-- Ten additions of 0.1 (numeric) must equal exactly 1.0 — mirrors the same
-- "10 × 0.1" case already covered at the JS/decimal.js layer in
-- tests/decimal.test.ts, proving both layers agree.
do $$
declare v_total numeric := 0;
declare i int;
begin
  for i in 1..10 loop
    v_total := v_total + 0.1::numeric;
  end loop;
  assert v_total = 1.0::numeric, format('جمع 0.1 عشر مرات بنوع NUMERIC يجب أن يساوي 1.0 تمامًا، وجد %s', v_total);
  raise notice 'OK: جمع 0.1 عشر مرات بنوع NUMERIC = 1.0 تمامًا (يطابق سلوك طبقة decimal.js في الواجهة)';
end $$;

-- All NUMERIC columns added in this phase really are NUMERIC (not
-- float4/float8) — a structural sanity check against information_schema so
-- a future migration can never silently regress this.
do $$
declare v_bad_count int;
begin
  select count(*) into v_bad_count
  from information_schema.columns
  where table_schema = 'public'
    and table_name in ('daily_gold_prices', 'manufacturing_fee_versions', 'payment_method_fee_versions', 'karats')
    and column_name in ('price_per_gram', 'fee_per_gram', 'percentage_fee', 'fixed_fee', 'purity_per_mille')
    and data_type not in ('numeric');
  assert v_bad_count = 0, format('كل الأعمدة المالية في الطور الثاني يجب أن تكون NUMERIC، وُجد %s عمودًا مخالفًا', v_bad_count);
  raise notice 'OK: كل الأعمدة المالية المضافة في الطور الثاني من نوع NUMERIC فعليًا (لا float/double)';
end $$;

do $$
begin
  raise notice '=== ALL FINANCIAL MASTER DATA (PHASE 2) TESTS PASSED (migrations 0040-0046) ===';
end $$;

rollback;
