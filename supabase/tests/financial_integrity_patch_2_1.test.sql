-- ============================================================================
-- Integration test: Financial Integrity Patch 2.1 (migrations 0047-0050)
-- ============================================================================
-- Dedicated to the scenarios the Patch 2.1 spec itself calls out explicitly,
-- as FORMAL assertions (not ad hoc psql exploration):
--
--   §1  Versioning tables locked from direct edit; RPCs are the sole write
--       path; a version's value/identity can never change once created.
--   §2  Cancelling a not-yet-effective Future Version reopens the correct
--       predecessor atomically (manufacturing fees AND payment fees).
--   §3  System-managed columns (created_by/created_at/updated_by/updated_at)
--       cannot be forged by `authenticated`, across all 7 Phase 2 tables.
--   §6  fee_model is a DB invariant: shape rules, inactive-entity rejection,
--       percentage_fee <= 100, and fee_model-change-consistency.
--
-- This file is intentionally SEPARATE from financial_master_data.test.sql
-- (Phase 2, 0040-0046) and rls_and_permissions.test.sql (Foundation,
-- 0001-0039) rather than an extension of either — neither of those files is
-- touched or reopened by this patch; this file covers only what 0047-0050
-- newly added. All three files are run independently in CI/local
-- verification, in order (Foundation -> Phase 2 -> this file).
--
-- Safe to run against a real (including production-like staging) Supabase
-- database: everything happens inside a transaction that is ALWAYS rolled
-- back at the end, so no test data is left behind.
--
-- Requires migrations 0001-0050 + supabase/seed.sql to already be applied.
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/financial_integrity_patch_2_1.test.sql
--
-- Every assertion either raises (test fails, transaction aborts, non-zero
-- exit) or prints an "OK:" notice. Read the output top to bottom.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- Actors. Fully-isolated fake accounts with a prefix ('f2...') distinct from
-- both rls_and_permissions.test.sql ('a0...') and financial_master_data.
-- test.sql ('f1...'), even though transaction rollback already isolates
-- each file's own run.
--
--   0001 = Manager — holds every Phase 2 *.view/*.manage permission, used to
--          exercise the RPC paths and the direct-write tables' legitimate
--          INSERT/UPDATE path.
--   0002 = A second real profile, used only as the FK target for a "forged
--          created_by" attempt (created_by references profiles(id), so the
--          forged value must be a real row for the forgery attempt to even
--          reach the trigger instead of failing on an unrelated FK error).
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('f2000000-0000-4000-8000-000000000001', 'test-patch21-manager@example.invalid'),
  ('f2000000-0000-4000-8000-000000000002', 'test-patch21-other@example.invalid');

update public.profiles set full_name = 'Test Patch 2.1 Manager', status = 'active', store_access_scope = 'all'
  where id = 'f2000000-0000-4000-8000-000000000001';
update public.profiles set full_name = 'Test Patch 2.1 Other Profile', status = 'active', store_access_scope = 'all'
  where id = 'f2000000-0000-4000-8000-000000000002';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'f2000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in (
    'karats.view', 'karats.manage',
    'manufacturing_fees.view', 'manufacturing_fees.manage',
    'categories.view', 'categories.manage',
    'payment_methods.view', 'payment_methods.manage',
    'collection_channels.view', 'collection_channels.manage',
    'gold_prices.view', 'gold_prices.edit'
  );

set role authenticated;
set local request.jwt.claims = '{"sub":"f2000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- Test karats/payment methods local to this file (own uuid prefixes so they
-- never collide with seed data or the other two test files' rows).
do $$
begin
  insert into public.karats (id, code, name_ar, sort_order, status) values
    ('e1000000-0000-4000-8000-000000000001', 'P21A', 'عيار اختبار Patch 2.1 — أ', 950, 'active'),
    ('e1000000-0000-4000-8000-000000000002', 'P21B', 'عيار اختبار Patch 2.1 — ب (غير نشط)', 951, 'active');

  insert into public.payment_methods (id, key, name_ar, fee_model, sort_order, status) values
    ('e2000000-0000-4000-8000-000000000001', 'p21_pct', 'اختبار Patch 2.1 — نسبة', 'percentage', 950, 'active'),
    ('e2000000-0000-4000-8000-000000000002', 'p21_fixed', 'اختبار Patch 2.1 — ثابت', 'fixed', 951, 'active'),
    ('e2000000-0000-4000-8000-000000000003', 'p21_none', 'اختبار Patch 2.1 — بدون رسوم', 'none', 952, 'active'),
    ('e2000000-0000-4000-8000-000000000004', 'p21_both', 'اختبار Patch 2.1 — نسبة+ثابت', 'percentage_plus_fixed', 953, 'active'),
    ('e2000000-0000-4000-8000-000000000005', 'p21_inactive', 'اختبار Patch 2.1 — طريقة معطّلة', 'percentage', 954, 'inactive');
  raise notice 'OK: تجهيز بيانات اختبار Patch 2.1 (عياران، خمس طرق دفع)';
end $$;

-- ---------------------------------------------------------------------------
-- §1. Direct-write lockdown + immutability (spec item 1, migration 0047 PART
-- A/B). The base "authenticated cannot INSERT directly" case is already
-- covered end-to-end in financial_master_data.test.sql sections 3.5/4.5
-- (mirrored) — this section adds what that file does not: an UPDATE attempt
-- (not just INSERT), and immutability against a TRUSTED (service_role)
-- writer on an EXISTING row, for both tables.
-- ---------------------------------------------------------------------------

-- 1.1 A real historical version, created the only sanctioned way, to attempt
-- to edit against.
do $$
declare v_hist_id uuid;
begin
  v_hist_id := public.create_manufacturing_fee_version('e1000000-0000-4000-8000-000000000001', 7.0000, current_date - 90, 'نسخة تاريخية للاختبار');
  perform public.create_manufacturing_fee_version('e1000000-0000-4000-8000-000000000001', 8.0000, current_date - 30, 'نسخة ثانية تُنهي الأولى');
  -- v_hist_id (fee=7) is now status='ended' — a genuine Historical Version.
  assert (select status from public.manufacturing_fee_versions where id = v_hist_id) = 'ended',
    'يجب أن تصبح النسخة الأولى ended بعد إنشاء الثانية';
  raise notice 'OK: نسخة تاريخية (ended) جاهزة للاختبار — %', v_hist_id;
end $$;

-- 1.2 authenticated (even the manager, holding manufacturing_fees.manage)
-- cannot UPDATE a manufacturing_fee_versions row directly at all — RLS has
-- no UPDATE policy for this table as of 0047. Unlike INSERT (which raises
-- "new row violates row-level security policy" the moment WITH CHECK is
-- implicitly false), a missing UPDATE policy is an implicit USING (false):
-- the UPDATE does NOT raise, it simply matches zero rows. So the correct
-- assertion is ROW_COUNT = 0 and the underlying value provably unchanged —
-- not "an exception was raised".
do $$
declare v_count integer;
begin
  update public.manufacturing_fee_versions set fee_per_gram = 999 where fee_per_gram = 7.0000;
  get diagnostics v_count = row_count;
  if v_count <> 0 then
    raise exception 'SECURITY BUG: نجح UPDATE مباشر من authenticated على manufacturing_fee_versions (% صف متأثر)', v_count;
  end if;
  assert (select count(*) from public.manufacturing_fee_versions where fee_per_gram = 999) = 0,
    'SECURITY BUG: القيمة تغيّرت فعليًا رغم عدم تأثر أي صف ظاهريًا';
  raise notice 'OK (0047): مُنع authenticated من UPDATE مباشر على manufacturing_fee_versions حتى مع manufacturing_fees.manage (0 صف متأثر — RLS بلا سياسة UPDATE = USING(false) ضمنيًا)';
end $$;

-- 1.3 As a TRUSTED bootstrap context (service_role — BYPASSRLS), attempt to
-- edit the Historical Version's karat_id/fee_per_gram/effective_from
-- directly. Must still fail: immutability is unconditional (PART B), not
-- merely an RLS gate.
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
do $$
declare v_bug boolean := false;
begin
  begin
    update public.manufacturing_fee_versions set fee_per_gram = 999 where fee_per_gram = 7.0000;
    v_bug := true;
  exception when others then
    raise notice 'OK: قيمة نسخة مصنعية تاريخية رُفض تعديلها حتى عبر service_role (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: عُدِّلت قيمة نسخة مصنعية تاريخية عبر service_role'; end if;
end $$;

do $$
declare v_bug boolean := false;
begin
  begin
    update public.manufacturing_fee_versions set karat_id = 'e1000000-0000-4000-8000-000000000002' where fee_per_gram = 7.0000;
    v_bug := true;
  exception when others then
    raise notice 'OK: karat_id لنسخة مصنعية موجودة رُفض تعديله حتى عبر service_role (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: عُدِّل karat_id لنسخة مصنعية موجودة عبر service_role'; end if;
end $$;

do $$
declare v_bug boolean := false;
begin
  begin
    update public.manufacturing_fee_versions set effective_from = effective_from - 1 where fee_per_gram = 7.0000;
    v_bug := true;
  exception when others then
    raise notice 'OK: effective_from لنسخة مصنعية موجودة رُفض تعديله حتى عبر service_role (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: عُدِّل effective_from لنسخة مصنعية موجودة عبر service_role'; end if;
end $$;

-- 1.4 Sanity check the other direction: effective_to/status ARE legitimately
-- mutable columns (that is how cancel_*_version() itself works) — proves the
-- trigger is scoped precisely, not blocking every UPDATE outright.
do $$
begin
  update public.manufacturing_fee_versions set effective_to = effective_to where fee_per_gram = 7.0000;
  raise notice 'OK: تعديل effective_to (بقيمة غير متغيرة فعليًا هنا فقط للتأكد من عدم رفض العمود نفسه) لا يُرفض من مُشغِّل الثبات — النطاق محصور في karat_id/fee_per_gram/effective_from تحديدًا';
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"f2000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- 1.5-1.9 Same five checks, mirrored exactly, for payment_method_fee_versions.
do $$
declare v_hist_id uuid;
begin
  v_hist_id := public.create_payment_method_fee_version('e2000000-0000-4000-8000-000000000001', 2.0, 0, current_date - 90, 'نسخة تاريخية للاختبار');
  perform public.create_payment_method_fee_version('e2000000-0000-4000-8000-000000000001', 3.0, 0, current_date - 30, 'نسخة ثانية تُنهي الأولى');
  assert (select status from public.payment_method_fee_versions where id = v_hist_id) = 'ended',
    'يجب أن تصبح نسخة العمولة الأولى ended بعد إنشاء الثانية';
  raise notice 'OK: نسخة عمولة تاريخية (ended) جاهزة للاختبار — %', v_hist_id;
end $$;

-- Same ROW_COUNT-based check as manufacturing fees above (a missing UPDATE
-- policy is USING(false) implicitly, not a raised exception).
do $$
declare v_count integer;
begin
  update public.payment_method_fee_versions set percentage_fee = 99 where percentage_fee = 2.0;
  get diagnostics v_count = row_count;
  if v_count <> 0 then
    raise exception 'SECURITY BUG: نجح UPDATE مباشر من authenticated على payment_method_fee_versions (% صف متأثر)', v_count;
  end if;
  assert (select count(*) from public.payment_method_fee_versions where percentage_fee = 99) = 0,
    'SECURITY BUG: القيمة تغيّرت فعليًا رغم عدم تأثر أي صف ظاهريًا';
  raise notice 'OK (0047): مُنع authenticated من UPDATE مباشر على payment_method_fee_versions حتى مع payment_methods.manage (0 صف متأثر)';
end $$;

set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
do $$
declare v_bug boolean := false;
begin
  begin
    update public.payment_method_fee_versions set percentage_fee = 99 where percentage_fee = 2.0;
    v_bug := true;
  exception when others then
    raise notice 'OK: قيمة نسخة عمولة تاريخية رُفض تعديلها حتى عبر service_role (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: عُدِّلت قيمة نسخة عمولة تاريخية عبر service_role'; end if;
end $$;

do $$
declare v_bug boolean := false;
begin
  begin
    update public.payment_method_fee_versions set payment_method_id = 'e2000000-0000-4000-8000-000000000002' where percentage_fee = 2.0;
    v_bug := true;
  exception when others then
    raise notice 'OK: payment_method_id لنسخة عمولة موجودة رُفض تعديله حتى عبر service_role (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: عُدِّل payment_method_id لنسخة عمولة موجودة عبر service_role'; end if;
end $$;

do $$
declare v_bug boolean := false;
begin
  begin
    update public.payment_method_fee_versions set effective_from = effective_from - 1 where percentage_fee = 2.0;
    v_bug := true;
  exception when others then
    raise notice 'OK: effective_from لنسخة عمولة موجودة رُفض تعديله حتى عبر service_role (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: عُدِّل effective_from لنسخة عمولة موجودة عبر service_role'; end if;
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"f2000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- §2. Cancelling a Future Version reopens the correct predecessor (spec item
-- 2), as a FORMAL assertion of the user's own literal scenario: Current=8,
-- schedule future=10, cancel 10 before it takes effect -> resolver after
-- 10's supposed start date must return 8 (not raise/gap). Manufacturing
-- fees first, then the identical scenario repeated for payment fees
-- ("كرر الاختبار نفسه للعمولات").
-- ---------------------------------------------------------------------------
do $$
declare
  v_future_id uuid;
  v_predecessor record;
  v_resolved numeric;
begin
  -- karat 'e1...0002' is fresh (no versions yet in this file) — Current=8.
  perform public.create_manufacturing_fee_version('e1000000-0000-4000-8000-000000000002', 8.0000, current_date - 10, 'الحالي = 8');

  -- Schedule Future=10.
  v_future_id := public.create_manufacturing_fee_version('e1000000-0000-4000-8000-000000000002', 10.0000, current_date + 20, 'المستقبلي = 10');

  select * into v_predecessor from public.manufacturing_fee_versions
    where karat_id = 'e1000000-0000-4000-8000-000000000002' and fee_per_gram = 8.0000;
  assert v_predecessor.status = 'ended' and v_predecessor.effective_to = (current_date + 20) - 1,
    'الإصدار 8 يجب أن يصبح ended بتاريخ انتهاء = يوم قبل سريان 10 بالضبط';

  -- Cancel 10 BEFORE it takes effect.
  perform public.cancel_manufacturing_fee_version(v_future_id);
  assert (select status from public.manufacturing_fee_versions where id = v_future_id) = 'cancelled',
    'الإصدار المستقبلي (10) يجب أن يصبح cancelled';

  -- The bug this closes: 8 must be REOPENED (effective_to=null, status=active), not left permanently ended.
  select * into v_predecessor from public.manufacturing_fee_versions
    where karat_id = 'e1000000-0000-4000-8000-000000000002' and fee_per_gram = 8.0000;
  assert v_predecessor.status = 'active' and v_predecessor.effective_to is null,
    format('BUG: الإصدار 8 لم يُعَد فتحه بعد إلغاء 10 — status=%s, effective_to=%s', v_predecessor.status, v_predecessor.effective_to);

  -- The resolver, queried AFTER 10's supposed effective date, must return 8 (no gap).
  v_resolved := public.manufacturing_fee_for_karat_on_date('e1000000-0000-4000-8000-000000000002', current_date + 20);
  assert v_resolved = 8.0000, format('BUG: بعد إلغاء 10، المُحلِّل بتاريخ سريان 10 المفترض أعاد %s بدل 8', v_resolved);

  raise notice 'OK (spec item 2, مصنعية): 8 -> جدولة 10 -> إلغاء 10 -> إعادة فتح 8 تلقائيًا -> المُحلِّل يعيد 8 بلا فجوة مالية';
end $$;

-- Identical scenario, payment fees.
do $$
declare
  v_future_id uuid;
  v_predecessor record;
  v_resolved_pct numeric;
begin
  perform public.create_payment_method_fee_version('e2000000-0000-4000-8000-000000000004', 8.0, 0, current_date - 10, 'الحالي = 8%');
  v_future_id := public.create_payment_method_fee_version('e2000000-0000-4000-8000-000000000004', 10.0, 0, current_date + 20, 'المستقبلي = 10%');

  select * into v_predecessor from public.payment_method_fee_versions
    where payment_method_id = 'e2000000-0000-4000-8000-000000000004' and percentage_fee = 8.0;
  assert v_predecessor.status = 'ended' and v_predecessor.effective_to = (current_date + 20) - 1,
    'إصدار العمولة 8%% يجب أن يصبح ended بتاريخ انتهاء = يوم قبل سريان 10%% بالضبط';

  perform public.cancel_payment_method_fee_version(v_future_id);
  assert (select status from public.payment_method_fee_versions where id = v_future_id) = 'cancelled',
    'إصدار العمولة المستقبلي (10%%) يجب أن يصبح cancelled';

  select * into v_predecessor from public.payment_method_fee_versions
    where payment_method_id = 'e2000000-0000-4000-8000-000000000004' and percentage_fee = 8.0;
  assert v_predecessor.status = 'active' and v_predecessor.effective_to is null,
    format('BUG: إصدار العمولة 8%% لم يُعَد فتحه بعد إلغاء 10%% — status=%s, effective_to=%s', v_predecessor.status, v_predecessor.effective_to);

  select percentage_fee into v_resolved_pct from public.payment_fee_for_method_on_date('e2000000-0000-4000-8000-000000000004', current_date + 20);
  assert v_resolved_pct = 8.0, format('BUG: بعد إلغاء 10%%، المُحلِّل بتاريخ سريان 10%% المفترض أعاد %s بدل 8', v_resolved_pct);

  raise notice 'OK (spec item 2, عمولات — كرر الاختبار نفسه): 8%% -> جدولة 10%% -> إلغاء 10%% -> إعادة فتح 8%% تلقائيًا -> المُحلِّل يعيد 8%% بلا فجوة مالية';
end $$;

-- No-predecessor case: cancelling a karat's very FIRST-EVER version must not
-- invent a value — nothing further happens, and the resolver correctly
-- raises (no version at all covers that date anymore).
do $$
declare v_only_id uuid; v_raised boolean := false;
begin
  insert into public.karats (id, code, name_ar, sort_order, status)
    values ('e1000000-0000-4000-8000-000000000003', 'P21C', 'عيار اختبار Patch 2.1 — ج (بلا سلف)', 952, 'active');

  v_only_id := public.create_manufacturing_fee_version('e1000000-0000-4000-8000-000000000003', 5.0000, current_date + 15, 'الإصدار الوحيد — مستقبلي');
  perform public.cancel_manufacturing_fee_version(v_only_id);
  assert (select status from public.manufacturing_fee_versions where id = v_only_id) = 'cancelled',
    'الإصدار الوحيد يجب أن يصبح cancelled بعد الإلغاء';

  begin
    perform public.manufacturing_fee_for_karat_on_date('e1000000-0000-4000-8000-000000000003', current_date + 15);
  exception when others then
    v_raised := true;
  end;
  assert v_raised, 'BUG: المُحلِّل يجب أن يرفع خطأً بعد إلغاء الإصدار الوحيد لهذا العيار (لا سلف لإعادة فتحه — لا يُختلق قيمة)';
  raise notice 'OK: إلغاء الإصدار الأول/الوحيد لعيار لا سلف له لا يختلق أي قيمة — المُحلِّل يرفع خطأً بدل قيمة زائفة';
end $$;

-- ---------------------------------------------------------------------------
-- §3. System-managed columns cannot be forged (spec item 3, migration 0048).
-- Direct-write tables (karats, product_categories, payment_methods,
-- collection_channels, daily_gold_prices) are tested as `authenticated`,
-- forging created_by/created_at on INSERT and again on UPDATE. The two
-- versioning tables have NO direct authenticated write path at all as of
-- 0047 (already proven in §1 above) — so for THOSE two, the meaningful test
-- is that enforce_created_by_immutable()'s UPDATE branch unconditionally
-- pins created_at/created_by back to their original values even for a
-- TRUSTED (service_role) writer, which is the one case that can still
-- physically reach an UPDATE on these tables at all.
-- ---------------------------------------------------------------------------

-- 3.1 karats: forge created_by/created_at on INSERT.
do $$
declare v_id uuid; v_created_by uuid; v_created_at timestamptz;
begin
  insert into public.karats (id, code, name_ar, sort_order, status, created_by, created_at)
    values ('e1000000-0000-4000-8000-000000000004', 'P21D', 'اختبار تزوير الأعمدة', 953, 'active',
            'f2000000-0000-4000-8000-000000000002', '2000-01-01T00:00:00Z')
    returning id into v_id;
  select created_by, created_at into v_created_by, v_created_at from public.karats where id = v_id;
  assert v_created_by = 'f2000000-0000-4000-8000-000000000001', format('BUG: قُبل تزوير created_by على karats عند الإدراج — وجد %s', v_created_by);
  assert v_created_at > '2000-01-02T00:00:00Z'::timestamptz, format('BUG: قُبل تزوير created_at على karats عند الإدراج — وجد %s', v_created_at);
  raise notice 'OK: محاولة تزوير created_by/created_at على karats عند الإدراج صُحِّحت تلقائيًا إلى الفاعل الحقيقي/الوقت الحقيقي';

  update public.karats set name_ar = 'اسم مُحدَّث', created_by = 'f2000000-0000-4000-8000-000000000002', created_at = '2000-01-01T00:00:00Z' where id = v_id;
  select created_by, created_at into v_created_by, v_created_at from public.karats where id = v_id;
  assert v_created_by = 'f2000000-0000-4000-8000-000000000001', format('BUG: قُبل تزوير created_by على karats عند التعديل — وجد %s', v_created_by);
  assert v_created_at > '2000-01-02T00:00:00Z'::timestamptz, format('BUG: قُبل تزوير created_at على karats عند التعديل — وجد %s', v_created_at);
  raise notice 'OK: محاولة تزوير created_by/created_at على karats عند التعديل رُفضت (ثُبِّتا على القيم الأصلية)';
end $$;

-- 3.2 product_categories: same two checks.
do $$
declare v_id uuid; v_created_by uuid; v_created_at timestamptz;
begin
  insert into public.product_categories (name_ar, sort_order, status, created_by, created_at)
    values ('اختبار تزوير الأعمدة', 953, 'active', 'f2000000-0000-4000-8000-000000000002', '2000-01-01T00:00:00Z')
    returning id into v_id;
  select created_by, created_at into v_created_by, v_created_at from public.product_categories where id = v_id;
  assert v_created_by = 'f2000000-0000-4000-8000-000000000001', 'BUG: قُبل تزوير created_by على product_categories عند الإدراج';
  assert v_created_at > '2000-01-02T00:00:00Z'::timestamptz, 'BUG: قُبل تزوير created_at على product_categories عند الإدراج';

  update public.product_categories set name_ar = 'اسم مُحدَّث', created_by = 'f2000000-0000-4000-8000-000000000002', created_at = '2000-01-01T00:00:00Z' where id = v_id;
  select created_by, created_at into v_created_by, v_created_at from public.product_categories where id = v_id;
  assert v_created_by = 'f2000000-0000-4000-8000-000000000001', 'BUG: قُبل تزوير created_by على product_categories عند التعديل';
  assert v_created_at > '2000-01-02T00:00:00Z'::timestamptz, 'BUG: قُبل تزوير created_at على product_categories عند التعديل';
  raise notice 'OK: تزوير created_by/created_at على product_categories مرفوض عند الإدراج والتعديل معًا';
end $$;

-- 3.3 payment_methods: same two checks.
do $$
declare v_created_by uuid; v_created_at timestamptz;
begin
  insert into public.payment_methods (id, key, name_ar, fee_model, sort_order, status, created_by, created_at)
    values ('e2000000-0000-4000-8000-000000000006', 'p21_forge', 'اختبار تزوير الأعمدة', 'percentage', 955, 'active',
            'f2000000-0000-4000-8000-000000000002', '2000-01-01T00:00:00Z');
  select created_by, created_at into v_created_by, v_created_at from public.payment_methods where id = 'e2000000-0000-4000-8000-000000000006';
  assert v_created_by = 'f2000000-0000-4000-8000-000000000001', 'BUG: قُبل تزوير created_by على payment_methods عند الإدراج';
  assert v_created_at > '2000-01-02T00:00:00Z'::timestamptz, 'BUG: قُبل تزوير created_at على payment_methods عند الإدراج';

  update public.payment_methods set name_ar = 'اسم مُحدَّث', created_by = 'f2000000-0000-4000-8000-000000000002', created_at = '2000-01-01T00:00:00Z' where id = 'e2000000-0000-4000-8000-000000000006';
  select created_by, created_at into v_created_by, v_created_at from public.payment_methods where id = 'e2000000-0000-4000-8000-000000000006';
  assert v_created_by = 'f2000000-0000-4000-8000-000000000001', 'BUG: قُبل تزوير created_by على payment_methods عند التعديل';
  assert v_created_at > '2000-01-02T00:00:00Z'::timestamptz, 'BUG: قُبل تزوير created_at على payment_methods عند التعديل';
  raise notice 'OK: تزوير created_by/created_at على payment_methods مرفوض عند الإدراج والتعديل معًا';
end $$;

-- 3.4 collection_channels: same two checks.
do $$
declare v_id uuid; v_created_by uuid; v_created_at timestamptz;
begin
  insert into public.collection_channels (key, name_ar, sort_order, status, created_by, created_at)
    values ('p21_forge_channel', 'اختبار تزوير الأعمدة', 953, 'active', 'f2000000-0000-4000-8000-000000000002', '2000-01-01T00:00:00Z')
    returning id into v_id;
  select created_by, created_at into v_created_by, v_created_at from public.collection_channels where id = v_id;
  assert v_created_by = 'f2000000-0000-4000-8000-000000000001', 'BUG: قُبل تزوير created_by على collection_channels عند الإدراج';
  assert v_created_at > '2000-01-02T00:00:00Z'::timestamptz, 'BUG: قُبل تزوير created_at على collection_channels عند الإدراج';

  update public.collection_channels set name_ar = 'اسم مُحدَّث', created_by = 'f2000000-0000-4000-8000-000000000002', created_at = '2000-01-01T00:00:00Z' where id = v_id;
  select created_by, created_at into v_created_by, v_created_at from public.collection_channels where id = v_id;
  assert v_created_by = 'f2000000-0000-4000-8000-000000000001', 'BUG: قُبل تزوير created_by على collection_channels عند التعديل';
  assert v_created_at > '2000-01-02T00:00:00Z'::timestamptz, 'BUG: قُبل تزوير created_at على collection_channels عند التعديل';
  raise notice 'OK: تزوير created_by/created_at على collection_channels مرفوض عند الإدراج والتعديل معًا';
end $$;

-- 3.5 daily_gold_prices: same two checks (via a direct authenticated INSERT,
-- distinct from — and in addition to — save_daily_gold_price()/
-- save_daily_gold_prices_bulk()'s own explicit-column upsert defense; see
-- 0048's closing comment for why both layers coexist).
do $$
declare v_id uuid; v_created_by uuid; v_created_at timestamptz;
begin
  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by, created_at)
    values (current_date - 200, 'e1000000-0000-4000-8000-000000000001', 123.4567,
            'f2000000-0000-4000-8000-000000000002', '2000-01-01T00:00:00Z')
    returning id into v_id;
  select created_by, created_at into v_created_by, v_created_at from public.daily_gold_prices where id = v_id;
  assert v_created_by = 'f2000000-0000-4000-8000-000000000001', 'BUG: قُبل تزوير created_by على daily_gold_prices عند الإدراج المباشر';
  assert v_created_at > '2000-01-02T00:00:00Z'::timestamptz, 'BUG: قُبل تزوير created_at على daily_gold_prices عند الإدراج المباشر';

  update public.daily_gold_prices set price_per_gram = 200.0000, created_by = 'f2000000-0000-4000-8000-000000000002', created_at = '2000-01-01T00:00:00Z' where id = v_id;
  select created_by, created_at into v_created_by, v_created_at from public.daily_gold_prices where id = v_id;
  assert v_created_by = 'f2000000-0000-4000-8000-000000000001', 'BUG: قُبل تزوير created_by على daily_gold_prices عند التعديل';
  assert v_created_at > '2000-01-02T00:00:00Z'::timestamptz, 'BUG: قُبل تزوير created_at على daily_gold_prices عند التعديل';
  raise notice 'OK: تزوير created_by/created_at على daily_gold_prices مرفوض عند الإدراج المباشر والتعديل معًا';
end $$;

-- 3.6 manufacturing_fee_versions / payment_method_fee_versions: authenticated
-- has no direct write path at all (proven in §1), so the meaningful check
-- here is that enforce_created_by_immutable()'s UPDATE branch pins
-- created_at/created_by back to the original values UNCONDITIONALLY — even
-- for a trusted service_role writer, which is the only context that can
-- physically reach an UPDATE on these two tables.
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
do $$
declare v_created_by uuid; v_created_at timestamptz; v_id uuid;
begin
  select id, created_by, created_at into v_id, v_created_by, v_created_at
    from public.manufacturing_fee_versions where fee_per_gram = 8.0000 and karat_id = 'e1000000-0000-4000-8000-000000000001';

  update public.manufacturing_fee_versions
    set effective_to = effective_to, created_by = 'f2000000-0000-4000-8000-000000000002', created_at = '2000-01-01T00:00:00Z'
    where id = v_id;

  assert (select created_by from public.manufacturing_fee_versions where id = v_id) = v_created_by,
    'BUG: تغيّر created_by لنسخة مصنعية موجودة عبر UPDATE حتى مع service_role';
  assert (select created_at from public.manufacturing_fee_versions where id = v_id) = v_created_at,
    'BUG: تغيّر created_at لنسخة مصنعية موجودة عبر UPDATE حتى مع service_role';
  raise notice 'OK: created_by/created_at لنسخة مصنعية موجودة مثبَّتان حتى عبر UPDATE من service_role';
end $$;

do $$
declare v_created_by uuid; v_created_at timestamptz; v_id uuid;
begin
  select id, created_by, created_at into v_id, v_created_by, v_created_at
    from public.payment_method_fee_versions where percentage_fee = 3.0 and payment_method_id = 'e2000000-0000-4000-8000-000000000001';

  update public.payment_method_fee_versions
    set effective_to = effective_to, created_by = 'f2000000-0000-4000-8000-000000000002', created_at = '2000-01-01T00:00:00Z'
    where id = v_id;

  assert (select created_by from public.payment_method_fee_versions where id = v_id) = v_created_by,
    'BUG: تغيّر created_by لنسخة عمولة موجودة عبر UPDATE حتى مع service_role';
  assert (select created_at from public.payment_method_fee_versions where id = v_id) = v_created_at,
    'BUG: تغيّر created_at لنسخة عمولة موجودة عبر UPDATE حتى مع service_role';
  raise notice 'OK: created_by/created_at لنسخة عمولة موجودة مثبَّتان حتى عبر UPDATE من service_role';
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"f2000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- §6. fee_model as a DB invariant (spec item 6, migration 0047 PART C/D).
-- ---------------------------------------------------------------------------

-- 6.1 percentage_fee > 100 rejected by the CHECK constraint.
do $$
declare v_bug boolean := false;
begin
  begin
    perform public.create_payment_method_fee_version('e2000000-0000-4000-8000-000000000004', 101, 0, current_date + 200, 'نسبة أعلى من 100');
    v_bug := true;
  exception when check_violation then
    raise notice 'OK: قيد CHECK رفض percentage_fee > 100 (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: قُبلت نسبة عمولة أعلى من 100'; end if;
end $$;

-- 6.2 Negative values rejected (the RPC's own explicit check).
do $$
declare v_bug boolean := false;
begin
  begin
    perform public.create_payment_method_fee_version('e2000000-0000-4000-8000-000000000004', -1, 0, current_date + 200, 'نسبة سالبة');
    v_bug := true;
  exception when others then
    raise notice 'OK: قيمة عمولة سالبة (نسبة) رُفضت (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: قُبلت نسبة عمولة سالبة'; end if;
end $$;

do $$
declare v_bug boolean := false;
begin
  begin
    perform public.create_manufacturing_fee_version('e1000000-0000-4000-8000-000000000001', -5, current_date + 200, 'مصنعية سالبة');
    v_bug := true;
  exception when others then
    raise notice 'OK: قيمة مصنعية سالبة رُفضت (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: قُبلت قيمة مصنعية سالبة'; end if;
end $$;

-- 6.3 Shape violations: fee_model='percentage' with fixed_fee > 0.
do $$
declare v_bug boolean := false;
begin
  begin
    perform public.create_payment_method_fee_version('e2000000-0000-4000-8000-000000000001', 2, 5, current_date + 200, 'شكل غير متوافق — نسبة+ثابت لطريقة percentage');
    v_bug := true;
  exception when others then
    raise notice 'OK: رُفض إنشاء نسخة بشكل غير متوافق (fee_model=percentage لكن fixed_fee>0) — %', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: قُبلت نسخة عمولة بشكل غير متوافق مع fee_model=percentage'; end if;
end $$;

-- 6.4 Shape violation: fee_model='fixed' with percentage_fee > 0.
do $$
declare v_bug boolean := false;
begin
  begin
    perform public.create_payment_method_fee_version('e2000000-0000-4000-8000-000000000002', 2, 5, current_date + 200, 'شكل غير متوافق — نسبة+ثابت لطريقة fixed');
    v_bug := true;
  exception when others then
    raise notice 'OK: رُفض إنشاء نسخة بشكل غير متوافق (fee_model=fixed لكن percentage_fee>0) — %', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: قُبلت نسخة عمولة بشكل غير متوافق مع fee_model=fixed'; end if;
end $$;

-- 6.5 Shape violation: fee_model='none' with either value > 0.
do $$
declare v_bug boolean := false;
begin
  begin
    perform public.create_payment_method_fee_version('e2000000-0000-4000-8000-000000000003', 1, 0, current_date + 200, 'شكل غير متوافق — none بقيمة غير صفرية');
    v_bug := true;
  exception when others then
    raise notice 'OK: رُفض إنشاء نسخة بشكل غير متوافق (fee_model=none لكن percentage_fee>0) — %', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: قُبلت نسخة عمولة بشكل غير متوافق مع fee_model=none'; end if;
end $$;

-- 6.6 Inactive payment method rejected (create_payment_method_fee_version).
do $$
declare v_bug boolean := false;
begin
  begin
    perform public.create_payment_method_fee_version('e2000000-0000-4000-8000-000000000005', 2, 0, current_date + 200, 'طريقة معطّلة');
    v_bug := true;
  exception when others then
    raise notice 'OK: رُفض إنشاء نسخة عمولة لطريقة دفع غير نشطة (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: قُبلت نسخة عمولة لطريقة دفع غير نشطة'; end if;
end $$;

-- 6.7 Inactive karat rejected (create_manufacturing_fee_version), properly
-- run as an AUTHENTICATED manager this time — a prior ad hoc manual check
-- (during development of this patch) accidentally ran with no JWT claims
-- set at all, so it only proved the has_permission() check fires first, not
-- that the active-karat invariant itself works. Fixed here.
do $$
begin
  update public.karats set status = 'inactive' where id = 'e1000000-0000-4000-8000-000000000002';
end $$;

do $$
declare v_bug boolean := false;
begin
  begin
    perform public.create_manufacturing_fee_version('e1000000-0000-4000-8000-000000000002', 6, current_date + 200, 'عيار معطّل');
    v_bug := true;
  exception when others then
    raise notice 'OK: رُفض إنشاء نسخة مصنعية لعيار غير نشط، من مستخدم authenticated يملك manufacturing_fees.manage فعليًا (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: قُبلت نسخة مصنعية لعيار غير نشط'; end if;
end $$;

-- 6.8 fee_model-change-consistency (migration 0047 PART D): an incompatible
-- change is rejected while the currently open version stays exactly as it
-- was (no silent mutation); a compatible change is allowed.
do $$
declare v_bug boolean := false;
begin
  -- 'e2...0004' currently has an open version (percentage_fee=8, fixed_fee=0,
  -- from §2's reopen-predecessor scenario above) under fee_model=
  -- percentage_plus_fixed. Changing to 'fixed' would leave that open
  -- version's percentage_fee=8 inconsistent with 'fixed' (percentage_fee
  -- must be 0) -- must be rejected.
  begin
    update public.payment_methods set fee_model = 'fixed' where id = 'e2000000-0000-4000-8000-000000000004';
    v_bug := true;
  exception when others then
    raise notice 'OK: رُفض تغيير fee_model إلى fixed لأن الإصدار الساري (8%%, 0) غير متوافق معه (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: قُبل تغيير fee_model رغم عدم توافق الإصدار الساري معه'; end if;

  assert (select fee_model from public.payment_methods where id = 'e2000000-0000-4000-8000-000000000004') = 'percentage_plus_fixed',
    'BUG: يجب ألا يتغيّر fee_model فعليًا بعد رفض المحاولة';

  -- A compatible change (percentage_plus_fixed -> percentage) IS allowed,
  -- since the open version's fixed_fee is already 0.
  update public.payment_methods set fee_model = 'percentage' where id = 'e2000000-0000-4000-8000-000000000004';
  assert (select fee_model from public.payment_methods where id = 'e2000000-0000-4000-8000-000000000004') = 'percentage',
    'BUG: تغيير fee_model المتوافق مع الإصدار الساري كان يجب أن يُقبل';
  raise notice 'OK: تغيير fee_model المتوافق مع شكل الإصدار الساري (percentage_plus_fixed -> percentage، fixed_fee=0 بالفعل) قُبل بنجاح';
end $$;

-- 6.9 Historical (ended) versions are never touched or re-validated by a
-- fee_model change — the earlier ended version (percentage_fee=2.0, from
-- §1's setup on 'e2...0001') must remain exactly as it was regardless of
-- any fee_model change on that same payment method.
do $$
declare v_before record; v_after record;
begin
  select percentage_fee, fixed_fee, status into v_before from public.payment_method_fee_versions
    where payment_method_id = 'e2000000-0000-4000-8000-000000000001' and percentage_fee = 2.0;

  -- 'e2...0001' is fee_model=percentage; its currently open version (3.0%,
  -- fixed_fee=0) is already compatible with 'percentage_plus_fixed', so this
  -- change is allowed and must not touch the historical 2.0% row at all.
  update public.payment_methods set fee_model = 'percentage_plus_fixed' where id = 'e2000000-0000-4000-8000-000000000001';

  select percentage_fee, fixed_fee, status into v_after from public.payment_method_fee_versions
    where payment_method_id = 'e2000000-0000-4000-8000-000000000001' and percentage_fee = 2.0;

  assert v_before.status = v_after.status and v_before.fixed_fee = v_after.fixed_fee,
    'BUG: تغيير fee_model عدّل نسخة عمولة تاريخية (ended) — يجب ألا يُعاد التحقق منها أو تعديلها إطلاقًا';
  raise notice 'OK: تغيير fee_model لا يمس النسخ التاريخية (ended) إطلاقًا — تبقى صحيحة للنموذج الذي كان ساريًا وقت إنشائها';
end $$;

do $$
begin
  raise notice '=== ALL FINANCIAL INTEGRITY PATCH 2.1 TESTS PASSED (migrations 0047-0050) ===';
end $$;

rollback;
