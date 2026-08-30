-- ============================================================================
-- Integration test: Final Date Consistency Hotfix 2.2.2 (migration 0057)
-- ============================================================================
-- Covers the single item this hotfix closes: every DB function whose
-- default parameter value means "today" must resolve that default against
-- public.business_today() (Asia/Riyadh, 0056), never Postgres' own
-- current_date (the database server's own timezone) -- specifically the
-- three finance-safe "_safe" RPCs (0052) that 0056 never touched (they call
-- their underlying function with an EXPLICIT p_date, which resolves their
-- OWN default BEFORE entering the wrapper body -- so 0056's fix on the
-- underlying function silently never took effect for a caller that omits
-- p_date on the "_safe" variant), plus gold_price_for_karat_on_date()/
-- gold_prices_missing_for_date() (0041), which were out of 0056's scope but
-- are explicitly in scope here.
--
-- This file is intentionally SEPARATE from every earlier test file -- none
-- of those are touched or reopened by this hotfix. All test files run
-- independently in CI/local verification, in order.
--
-- Safe to run against a real (including production-like staging) Supabase
-- database: everything happens inside a transaction that is ALWAYS rolled
-- back at the end (including the temporary business_today() redefinition
-- in §1 below), so no test data and no function redefinition is left
-- behind.
--
-- Requires migrations 0001-0057 + supabase/seed.sql to already be applied.
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/financial_integrity_hotfix_2_2_2.test.sql
--
-- Every assertion either raises (test fails, transaction aborts, non-zero
-- exit) or prints an "OK:" notice. Read the output top to bottom.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- Actors/data. Prefix 'f6.../e9.../ea...' -- distinct from every other test
-- file's actors, even though transaction rollback already isolates each
-- file's own run.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('f6000000-0000-4000-8000-000000000001', 'test-hotfix222-manager@example.invalid');

update public.profiles set full_name = 'Test Hotfix 2.2.2 Manager', status = 'active', store_access_scope = 'all'
  where id = 'f6000000-0000-4000-8000-000000000001';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'f6000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in (
    'karats.view', 'karats.manage',
    'manufacturing_fees.view', 'manufacturing_fees.manage',
    'payment_methods.view', 'payment_methods.manage',
    'gold_prices.view', 'gold_prices.edit'
  );

set role authenticated;
set local request.jwt.claims = '{"sub":"f6000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
begin
  insert into public.karats (id, code, name_ar, sort_order, status) values
    ('e9000000-0000-4000-8000-000000000001', 'H222A', 'عيار — اختبار سعر ذهب Hotfix 2.2.2', 980, 'active'),
    ('e9000000-0000-4000-8000-000000000002', 'H222B', 'عيار — اختبار مصنعية Hotfix 2.2.2', 981, 'active'),
    ('e9000000-0000-4000-8000-000000000003', 'H222C', 'عيار — اختبار missing-for-date Hotfix 2.2.2', 982, 'active'),
    ('e9000000-0000-4000-8000-000000000004', 'H222D', 'عيار — بلا سعر إطلاقًا (ضابط سلامة)', 983, 'active'),
    ('e9000000-0000-4000-8000-000000000005', 'H222E', 'عيار — اختبار استقلالية timezone الجلسة (§2)', 984, 'active');

  insert into public.payment_methods (id, key, name_ar, fee_model, sort_order, status) values
    ('ea000000-0000-4000-8000-000000000001', 'h222_pct', 'اختبار عمولة Hotfix 2.2.2', 'percentage', 980, 'active');

  raise notice 'OK: تجهيز بيانات اختبار Hotfix 2.2.2 (أربعة عيارات، طريقة دفع واحدة)';
end $$;

-- Two distinguishing data points, dated at REAL current_date -- the "wrong"
-- default if the bug persists. The §1 sentinel below is a date far away
-- from real current_date (2099-06-15), so a call under the sentinel that
-- returns THIS value instead would prove the bug is still present.
do $$
begin
  perform public.save_daily_gold_price(current_date, 'e9000000-0000-4000-8000-000000000001', 111.1111, 'سعر اليوم الحقيقي (current_date) -- القيمة الخطأ إن استمرت الثغرة');
end $$;

-- A price row dated at the REAL (non-overridden) public.business_today(),
-- for §2's TimeZone-independence check specifically -- deliberately a
-- separate karat from the one above, so this row's date is correct
-- regardless of whether real current_date and real business_today() happen
-- to coincide (true most of the day) or differ (true only during the
-- ~21:00-23:59 UTC window) -- §2 must be deterministic at any hour.
do $$
begin
  perform public.save_daily_gold_price(public.business_today(), 'e9000000-0000-4000-8000-000000000005', 144.4400, 'سعر عند business_today() الحقيقي -- لاختبار §2 فقط');
end $$;

-- Manufacturing fee "A" (real-current_date-covering) and payment fee "A" --
-- inserted directly as service_role (authenticated has no direct write path
-- on these two tables since 0047). effective_to for each is set to
-- (sentinel - 1) so the range spans from deep in the past through the
-- instant right before the §1 sentinel -- covering REAL current_date fully.
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
do $$
declare v_sentinel constant date := '2099-06-15'::date;
begin
  insert into public.manufacturing_fee_versions (karat_id, fee_per_gram, effective_from, effective_to, status, created_by)
  values ('e9000000-0000-4000-8000-000000000002', 5.0000, '2000-01-01'::date, v_sentinel - 1, 'ended', 'f6000000-0000-4000-8000-000000000001');

  insert into public.manufacturing_fee_versions (karat_id, fee_per_gram, effective_from, effective_to, status, created_by)
  values ('e9000000-0000-4000-8000-000000000002', 9.0000, v_sentinel, null, 'active', 'f6000000-0000-4000-8000-000000000001');

  insert into public.payment_method_fee_versions (payment_method_id, percentage_fee, fixed_fee, effective_from, effective_to, status, created_by)
  values ('ea000000-0000-4000-8000-000000000001', 3.000, 0, '2000-01-01'::date, v_sentinel - 1, 'ended', 'f6000000-0000-4000-8000-000000000001');

  insert into public.payment_method_fee_versions (payment_method_id, percentage_fee, fixed_fee, effective_from, effective_to, status, created_by)
  values ('ea000000-0000-4000-8000-000000000001', 7.000, 0, v_sentinel, null, 'active', 'f6000000-0000-4000-8000-000000000001');

  raise notice 'OK: تجهيز إصدارَي مصنعية/عمولة متجاورين زمنيًا (A يغطي current_date الحقيقي وينتهي عند sentinel-1، B يبدأ من sentinel) لاختبار §1';
end $$;
set role authenticated;
set local request.jwt.claims = '{"sub":"f6000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- §1. Temporarily override public.business_today() with a fixed sentinel
-- date far from real current_date, then prove every function this hotfix
-- targets resolves its "today" default against the SENTINEL, not real
-- current_date. Fully transactional -- this whole file runs inside
-- begin;...rollback;, so the redefinition is undone automatically. Must run
-- as the migration-owning connection (not `authenticated`/`service_role`,
-- which lack privilege to CREATE OR REPLACE FUNCTION on an object they do
-- not own).
-- ---------------------------------------------------------------------------
reset role;
reset request.jwt.claims;

do $$
declare v_sentinel constant date := '2099-06-15'::date;
begin
  create or replace function public.business_today()
  returns date
  language sql
  stable
  as $body$ select '2099-06-15'::date $body$;

  assert public.business_today() = v_sentinel, 'اختبار داخلي: فشل استبدال business_today() مؤقتًا';
  assert current_date <> v_sentinel, 'اختبار داخلي: current_date الحقيقي يطابق القيمة الوهمية صدفة -- غيّر v_sentinel';
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"f6000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare v_sentinel constant date := '2099-06-15'::date;
begin
  perform public.save_daily_gold_price(v_sentinel, 'e9000000-0000-4000-8000-000000000001', 222.2222, 'سعر عند sentinel -- القيمة الصحيحة المتوقَّعة');
  perform public.save_daily_gold_price(v_sentinel, 'e9000000-0000-4000-8000-000000000003', 250.0000, 'سعر عند sentinel لعيار اختبار missing-for-date');
  raise notice 'OK: تجهيز بيانات مؤرَّخة بـsentinel (بعد الاستبدال المؤقت لـbusiness_today())';
end $$;

-- 1.1 gold_price_for_karat_on_date_safe() without p_date -- must resolve to
-- the SENTINEL-dated price (222.2222), not the real-current_date-dated one
-- (111.1111).
do $$
declare v_sentinel constant date := '2099-06-15'::date; v_result text;
begin
  v_result := public.gold_price_for_karat_on_date_safe('e9000000-0000-4000-8000-000000000001');
  assert v_result = '222.2222', format('BUG: gold_price_for_karat_on_date_safe() بلا p_date أرجع %s -- المتوقَّع 222.2222 (قيمة sentinel). لو أرجعت 111.1111 فالدالة لا تزال تستخدم current_date الحقيقي بدل business_today()', v_result);
  raise notice 'OK: gold_price_for_karat_on_date_safe() بلا p_date يستخدم business_today() (sentinel) فعليًا، لا current_date -- أرجع %', v_result;
end $$;

-- 1.2 manufacturing_fee_for_karat_on_date_safe() without p_date -- must
-- resolve to version B's fee (9.0000), not version A's (5.0000).
do $$
declare v_result text;
begin
  v_result := public.manufacturing_fee_for_karat_on_date_safe('e9000000-0000-4000-8000-000000000002');
  assert v_result = '9.0000', format('BUG: manufacturing_fee_for_karat_on_date_safe() بلا p_date أرجع %s -- المتوقَّع 9.0000 (إصدار B عند sentinel). لو أرجعت 5.0000 فالدالة لا تزال تستخدم current_date الحقيقي', v_result);
  raise notice 'OK: manufacturing_fee_for_karat_on_date_safe() بلا p_date يستخدم business_today() (sentinel) فعليًا -- أرجع %', v_result;
end $$;

-- 1.3 payment_fee_for_method_on_date_safe() without p_date -- must resolve
-- to version B's percentage (7.000), not version A's (3.000).
do $$
declare v_pct text; v_fixed text;
begin
  select percentage_fee, fixed_fee into v_pct, v_fixed
    from public.payment_fee_for_method_on_date_safe('ea000000-0000-4000-8000-000000000001');
  assert v_pct = '7.000', format('BUG: payment_fee_for_method_on_date_safe() بلا p_date أرجع percentage_fee=%s -- المتوقَّع 7.000 (إصدار B عند sentinel). لو أرجعت 3.000 فالدالة لا تزال تستخدم current_date الحقيقي', v_pct);
  raise notice 'OK: payment_fee_for_method_on_date_safe() بلا p_date يستخدم business_today() (sentinel) فعليًا -- أرجع percentage_fee=%', v_pct;
end $$;

-- 1.4 gold_price_for_karat_on_date() (non-"_safe" original) without p_date
-- -- same distinguishing proof as 1.1, directly on the underlying function.
do $$
declare v_result numeric;
begin
  v_result := public.gold_price_for_karat_on_date('e9000000-0000-4000-8000-000000000001');
  assert v_result = 222.2222, format('BUG: gold_price_for_karat_on_date() بلا p_date أرجع %s -- المتوقَّع 222.2222 (قيمة sentinel)', v_result);
  raise notice 'OK: gold_price_for_karat_on_date() بلا p_date يستخدم business_today() (sentinel) فعليًا -- أرجع %', v_result;
end $$;

-- 1.5 gold_prices_missing_for_date() without p_date -- e9...0003 (has a
-- price ONLY at the sentinel) must NOT appear as missing; e9...0004 (no
-- price at all, anywhere) must still appear as missing (sanity control,
-- proves the function still works correctly, not just "always empty").
do $$
declare v_karat3_missing boolean; v_karat4_missing boolean;
begin
  select exists(select 1 from public.gold_prices_missing_for_date() m where m.id = 'e9000000-0000-4000-8000-000000000003') into v_karat3_missing;
  select exists(select 1 from public.gold_prices_missing_for_date() m where m.id = 'e9000000-0000-4000-8000-000000000004') into v_karat4_missing;

  assert v_karat3_missing = false, 'BUG: gold_prices_missing_for_date() بلا p_date اعتبر عيارًا لديه سعر عند sentinel "مفقودًا" -- الدالة لا تزال تستخدم current_date الحقيقي بدل business_today()';
  assert v_karat4_missing = true, 'BUG: gold_prices_missing_for_date() لم يعتبر عيارًا بلا أي سعر إطلاقًا "مفقودًا" -- ضابط السلامة فشل';
  raise notice 'OK: gold_prices_missing_for_date() بلا p_date يستخدم business_today() (sentinel) فعليًا -- العيار الذي له سعر عند sentinel غير مُدرَج كمفقود، والعيار بلا أي سعر لا يزال مُدرَجًا كمفقود';
end $$;

-- Restore the real business_today() definition (belt-and-suspenders --
-- ROLLBACK at the end of this file undoes it regardless).
reset role;
reset request.jwt.claims;
do $$
begin
  create or replace function public.business_today()
  returns date
  language sql
  stable
  as $body$ select (now() at time zone 'Asia/Riyadh')::date; $body$;
end $$;
set role authenticated;
set local request.jwt.claims = '{"sub":"f6000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- §2. Session-TimeZone independence: the same real "today" default must be
-- identical regardless of the connecting session's `timezone` GUC --
-- exercised on the real, non-overridden business_today() this time (the
-- override in §1 is fully reverted above).
-- ---------------------------------------------------------------------------
do $$
declare v_under_utc text; v_under_extreme text;
begin
  set local timezone to 'UTC';
  v_under_utc := public.gold_price_for_karat_on_date_safe('e9000000-0000-4000-8000-000000000005');

  set local timezone to 'Pacific/Kiritimati'; -- UTC+14, an extreme, arbitrary session zone
  v_under_extreme := public.gold_price_for_karat_on_date_safe('e9000000-0000-4000-8000-000000000005');

  assert v_under_utc = '144.4400' and v_under_extreme = '144.4400',
    format('BUG: gold_price_for_karat_on_date_safe() بلا p_date تغيّرت نتيجته بتغيّر إعداد timezone الخاص بجلسة الاتصال (UTC=%s, extreme=%s) -- المتوقَّع 144.4400 في الحالتين، default اليوم يجب أن يكون مستقلًا عن إعداد الجلسة', v_under_utc, v_under_extreme);
  raise notice 'OK: gold_price_for_karat_on_date_safe() بلا p_date يُرجِع نفس النتيجة الصحيحة (%) تحت إعدادي timezone مختلفين تمامًا للجلسة (UTC وPacific/Kiritimati) -- مستقل تمامًا عن إعداد الجلسة، تمامًا كـbusiness_today() نفسها', v_under_utc;
end $$;

set local timezone to 'UTC';

-- ---------------------------------------------------------------------------
-- §3. Static source-inspection: the five target functions must reference
-- business_today() in their actual body and must NOT contain the bare
-- token current_date anywhere in that body (pg_get_functiondef returns only
-- the CREATE FUNCTION body, not the separate COMMENT ON text, so a comment
-- merely mentioning "current_date" in prose cannot fool this).
-- ---------------------------------------------------------------------------
do $$
declare
  v_def text;
  v_targets text[] := array[
    'gold_price_for_karat_on_date(uuid,date)',
    'gold_prices_missing_for_date(date)',
    'gold_price_for_karat_on_date_safe(uuid,date)',
    'manufacturing_fee_for_karat_on_date_safe(uuid,date)',
    'payment_fee_for_method_on_date_safe(uuid,date)'
  ];
  v_target text;
begin
  foreach v_target in array v_targets loop
    v_def := pg_get_functiondef(('public.' || v_target)::regprocedure);
    assert v_def ~ 'business_today', format('BUG: تعريف %s لا يستدعي business_today() إطلاقًا', v_target);
    assert v_def !~ 'current_date', format('BUG: تعريف %s لا يزال يحتوي current_date -- الاستبدال غير مكتمل', v_target);
  end loop;
  raise notice 'OK: الدوال الخمس المستهدَفة (gold_price_for_karat_on_date، gold_prices_missing_for_date، والثلاث _safe) تستدعي business_today() فعليًا في تعريفها ولا تحتوي current_date إطلاقًا';
end $$;

-- ---------------------------------------------------------------------------
-- §4. Sanity: an explicit p_date is completely unaffected -- proves this
-- hotfix changes ONLY the default, never behavior for a caller that already
-- passes a date.
-- ---------------------------------------------------------------------------
do $$
declare v_result text;
begin
  v_result := public.gold_price_for_karat_on_date_safe('e9000000-0000-4000-8000-000000000001', current_date);
  assert v_result = '111.1111', format('BUG: تمرير p_date صريحًا (current_date) لم يعد يعمل كما هو متوقَّع -- أرجع %s بدل 111.1111', v_result);
  raise notice 'OK: تمرير p_date صريحًا لا يزال يعمل تمامًا كما كان -- لا تغيير في السلوك عند تمرير التاريخ صراحةً (أرجع %)', v_result;
end $$;

do $$
begin
  raise notice '=== ALL FINANCIAL INTEGRITY HOTFIX 2.2.2 TESTS PASSED (migration 0057) ===';
end $$;

rollback;
