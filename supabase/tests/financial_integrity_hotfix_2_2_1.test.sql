-- ============================================================================
-- Integration test: Final Integrity Hotfix 2.2.1 (migrations 0055-0056)
-- ============================================================================
-- Covers the three items requested as a direct follow-up to Financial
-- Integrity Patch 2.2 (0051-0054):
--
--   §1  A brand-new daily_gold_prices row for an inactive karat is rejected
--       at the TABLE level itself (BEFORE INSERT trigger, migration 0055) --
--       not only inside save_daily_gold_price()/save_daily_gold_prices_
--       bulk() (0054) -- so a direct PostgREST INSERT that bypasses both
--       RPCs entirely can no longer reach the table either. Applies even to
--       a trusted (service_role) context -- no exemption, matching 0047's
--       precedent for the identical kind of rule on the Versioning tables.
--       A correction to an EXISTING row (however reached -- RPC upsert or a
--       direct UPDATE) remains completely unaffected.
--   §2  price_date/karat_id are immutable on an existing daily_gold_prices
--       row (migration 0055) -- a row's identity can never be silently
--       repointed to a different date/karat by ANY writer, including a
--       trusted context. Every other column remains freely correctable.
--   §3  A centralized Asia/Riyadh public.business_today() (migration 0056)
--       is used instead of Postgres' own current_date (which resolves
--       against the DATABASE SERVER's timezone, not this business'
--       calendar) inside create_manufacturing_fee_version()/create_payment_
--       method_fee_version()/cancel_manufacturing_fee_version()/cancel_
--       payment_method_fee_version()/manufacturing_fee_for_karat_on_date()/
--       payment_fee_for_method_on_date().
--
-- This file is intentionally SEPARATE from financial_integrity_patch_2_2.
-- test.sql and every earlier test file -- none of those are touched or
-- reopened by this hotfix. All test files run independently in CI/local
-- verification, in order.
--
-- Safe to run against a real (including production-like staging) Supabase
-- database: everything happens inside a transaction that is ALWAYS rolled
-- back at the end, so no test data is left behind (§3's temporary
-- redefinition of business_today() is also rolled back with everything
-- else -- see that section's own comment).
--
-- Requires migrations 0001-0056 + supabase/seed.sql to already be applied.
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/financial_integrity_hotfix_2_2_1.test.sql
--
-- Every assertion either raises (test fails, transaction aborts, non-zero
-- exit) or prints an "OK:" notice. Read the output top to bottom.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- Actors/data. Prefix 'f5...'/'e7...'/'e8...' -- distinct from every other
-- test file's actors, even though transaction rollback already isolates
-- each file's own run.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('f5000000-0000-4000-8000-000000000001', 'test-hotfix221-manager@example.invalid');

update public.profiles set full_name = 'Test Hotfix 2.2.1 Manager', status = 'active', store_access_scope = 'all'
  where id = 'f5000000-0000-4000-8000-000000000001';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'f5000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in (
    'karats.view', 'karats.manage',
    'manufacturing_fees.view', 'manufacturing_fees.manage',
    'payment_methods.view', 'payment_methods.manage',
    'gold_prices.view', 'gold_prices.edit'
  );

set role authenticated;
set local request.jwt.claims = '{"sub":"f5000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
begin
  insert into public.karats (id, code, name_ar, sort_order, status) values
    ('e7000000-0000-4000-8000-000000000001', 'H221A', 'عيار اختبار Hotfix 2.2.1 — نشط', 970, 'active'),
    ('e7000000-0000-4000-8000-000000000002', 'H221B', 'عيار اختبار Hotfix 2.2.1 — سيُعطَّل', 971, 'active');

  insert into public.payment_methods (id, key, name_ar, fee_model, sort_order, status) values
    ('e8000000-0000-4000-8000-000000000001', 'h221_pct', 'اختبار Hotfix 2.2.1', 'percentage', 970, 'active');
  raise notice 'OK: تجهيز بيانات اختبار Hotfix 2.2.1 (عياران، طريقة دفع واحدة)';
end $$;

-- ---------------------------------------------------------------------------
-- §1. Table-level inactive-karat block on daily_gold_prices (hotfix item 1,
-- migration 0055).
-- ---------------------------------------------------------------------------

-- 1.0 Insert one legitimate price row for the second karat WHILE it is
-- still active, at a distinct historical date (current_date - 950) -- this
-- is the row §1.4/§1.5 below correct AFTER the karat is disabled, proving
-- "correcting an existing row" stays unaffected. Then disable the karat.
do $$
declare v_id uuid;
begin
  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by, updated_by)
  values (current_date - 950, 'e7000000-0000-4000-8000-000000000002', 290.0000, 'f5000000-0000-4000-8000-000000000001', 'f5000000-0000-4000-8000-000000000001')
  returning id into v_id;
  assert v_id is not null, 'BUG: فشل تجهيز سعر شرعي للعيار الثاني قبل تعطيله';

  update public.karats set status = 'inactive' where id = 'e7000000-0000-4000-8000-000000000002';
  raise notice 'OK: تجهيز سعر شرعي للعيار الثاني (بتاريخ current_date-950) ثم تعطيل العيار لاختبار §1';
end $$;

do $$
declare v_bug boolean := false;
begin
  begin
    insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by, updated_by)
    values (current_date - 900, 'e7000000-0000-4000-8000-000000000002', 300.0000, 'f5000000-0000-4000-8000-000000000001', 'f5000000-0000-4000-8000-000000000001');
    v_bug := true;
  exception when others then
    if sqlerrm <> 'لا يمكن تسجيل سعر جديد لعيار غير نشط' then
      raise exception 'BUG: رُفض الإدراج بخطأ غير متوقع: %', sqlerrm;
    end if;
  end;
  assert v_bug = false, 'SECURITY BUG: قُبل INSERT مباشر لسعر جديد لعيار غير نشط -- تجاوز الـTrigger على مستوى الجدول';
  raise notice 'OK: رُفض INSERT مباشر (بلا أي RPC) لسعر جديد لعيار غير نشط عبر Trigger الجدول نفسه (0055)';
end $$;

-- 1.2 Sanity: the SAME direct INSERT shape succeeds for the ACTIVE karat --
-- proves the trigger isn't over-blocking legitimate inserts.
do $$
declare v_id uuid;
begin
  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by, updated_by)
  values (current_date - 900, 'e7000000-0000-4000-8000-000000000001', 300.0000, 'f5000000-0000-4000-8000-000000000001', 'f5000000-0000-4000-8000-000000000001')
  returning id into v_id;
  assert v_id is not null, 'BUG: رُفض INSERT مباشر مشروع لعيار نشط';
  raise notice 'OK: قُبل INSERT مباشر مشروع لعيار نشط بلا مشاكل (لا حظر زائد)';
end $$;

-- 1.3 No trusted-context exemption: service_role is ALSO rejected when
-- attempting a brand-new row for the inactive karat (matches 0047's
-- precedent for the Versioning tables exactly -- see migration 0055 header
-- comment for why no exemption is warranted here, unlike 0051's source-
-- integrity trigger).
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
do $$
declare v_bug boolean := false;
begin
  begin
    insert into public.daily_gold_prices (price_date, karat_id, price_per_gram)
    values (current_date - 850, 'e7000000-0000-4000-8000-000000000002', 305.0000);
    v_bug := true;
  exception when others then
    if sqlerrm <> 'لا يمكن تسجيل سعر جديد لعيار غير نشط' then
      raise exception 'BUG: رُفض إدراج service_role بخطأ غير متوقع: %', sqlerrm;
    end if;
  end;
  assert v_bug = false, 'BUG: قُبل service_role إدراج سعر جديد لعيار غير نشط -- الـTrigger يجب أن يطبَّق بلا استثناء (0055)';
  raise notice 'OK: لا استثناء لسياق موثوق (service_role) -- رُفض إدراج سعر جديد لعيار غير نشط له أيضًا، طبقًا لتصميم 0055';
end $$;
set role authenticated;
set local request.jwt.claims = '{"sub":"f5000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- 1.4 Correcting an EXISTING row (the one prepared in §1.0, BEFORE the
-- karat was disabled) for a karat later disabled remains fully allowed via
-- a direct UPDATE (the trigger only ever fires on INSERT).
do $$
declare v_price numeric;
begin
  update public.daily_gold_prices
    set price_per_gram = 333.3333
    where price_date = current_date - 950 and karat_id = 'e7000000-0000-4000-8000-000000000002';

  select price_per_gram into v_price from public.daily_gold_prices
    where price_date = current_date - 950 and karat_id = 'e7000000-0000-4000-8000-000000000002';
  assert v_price = 333.3333, 'BUG: تصحيح سعر موجود لعيار غير نشط عبر UPDATE مباشر رُفض خطأً';
  raise notice 'OK: تصحيح سعر موجود مسبقًا لعيار غير نشط عبر UPDATE مباشر لا يزال مسموحًا (الـTrigger لا يعمل على UPDATE إطلاقًا)';
end $$;

-- 1.5 Regression guard: save_daily_gold_price()'s own ON CONFLICT DO UPDATE
-- upsert path for the SAME existing row on a now-inactive karat must still
-- succeed, despite Postgres firing the BEFORE INSERT trigger for the
-- candidate row even when the statement resolves as an UPDATE via ON
-- CONFLICT -- this is the exact regression discovered and fixed while
-- building this migration (see 0055's header comment).
do $$
declare v_price numeric;
begin
  perform public.save_daily_gold_price(current_date - 950, 'e7000000-0000-4000-8000-000000000002', 344.4444, 'تصحيح عبر RPC لعيار عُطِّل لاحقًا');
  select price_per_gram into v_price from public.daily_gold_prices
    where price_date = current_date - 950 and karat_id = 'e7000000-0000-4000-8000-000000000002';
  assert v_price = 344.4444, 'REGRESSION: save_daily_gold_price() upsert لتصحيح سعر موجود لعيار غير نشط رُفض خطأً (البند 1.5 -- انظر تعليق 0055)';
  raise notice 'OK: لا تراجع -- save_daily_gold_price() لا يزال يصحح سعرًا موجودًا لعيار أصبح غير نشط لاحقًا عبر مسار ON CONFLICT DO UPDATE';
end $$;

-- ---------------------------------------------------------------------------
-- §2. price_date/karat_id immutability on daily_gold_prices (hotfix item 2,
-- migration 0055).
-- ---------------------------------------------------------------------------

-- 2.1 Direct UPDATE attempting to move an existing row to a different
-- price_date -- rejected.
do $$
declare v_bug boolean := false;
begin
  begin
    update public.daily_gold_prices set price_date = current_date - 899
      where price_date = current_date - 900 and karat_id = 'e7000000-0000-4000-8000-000000000001';
    v_bug := true;
  exception when others then
    if sqlerrm !~ 'لا يمكن تعديل تاريخ السعر أو العيار' then
      raise exception 'BUG: رُفض التعديل بخطأ غير متوقع: %', sqlerrm;
    end if;
  end;
  assert v_bug = false, 'BUG: قُبل تعديل price_date لسجل سعر موجود -- هوية السجل يجب أن تكون غير قابلة للتغيير';
  raise notice 'OK: رُفض تعديل price_date لسجل سعر موجود (0055)';
end $$;

-- 2.2 Direct UPDATE attempting to move an existing row to a different
-- karat_id -- rejected.
do $$
declare v_bug boolean := false;
begin
  begin
    update public.daily_gold_prices set karat_id = 'e7000000-0000-4000-8000-000000000002'
      where price_date = current_date - 900 and karat_id = 'e7000000-0000-4000-8000-000000000001';
    v_bug := true;
  exception when others then
    if sqlerrm !~ 'لا يمكن تعديل تاريخ السعر أو العيار' then
      raise exception 'BUG: رُفض التعديل بخطأ غير متوقع: %', sqlerrm;
    end if;
  end;
  assert v_bug = false, 'BUG: قُبل تعديل karat_id لسجل سعر موجود -- هوية السجل يجب أن تكون غير قابلة للتغيير';
  raise notice 'OK: رُفض تعديل karat_id لسجل سعر موجود (0055)';
end $$;

-- 2.3 Sanity: updating a non-identity column (price_per_gram/notes) on the
-- same row keeps working normally -- the trigger only guards the two
-- identity columns.
do $$
declare v_price numeric;
begin
  update public.daily_gold_prices set price_per_gram = 355.5555, notes = 'تصحيح شرعي'
    where price_date = current_date - 900 and karat_id = 'e7000000-0000-4000-8000-000000000001';
  select price_per_gram into v_price from public.daily_gold_prices
    where price_date = current_date - 900 and karat_id = 'e7000000-0000-4000-8000-000000000001';
  assert v_price = 355.5555, 'BUG: تعديل عمود غير هوياتي (price_per_gram) رُفض خطأً بعد إضافة قيد الثبات';
  raise notice 'OK: تعديل الأعمدة غير الهوياتية (السعر/الملاحظات) يعمل بشكل طبيعي -- القيد يخص price_date/karat_id فقط';
end $$;

-- 2.4 No trusted-context exemption: service_role is ALSO rejected when
-- attempting to repoint an existing row's karat_id.
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
do $$
declare v_bug boolean := false;
begin
  begin
    update public.daily_gold_prices set karat_id = 'e7000000-0000-4000-8000-000000000002'
      where price_date = current_date - 900 and karat_id = 'e7000000-0000-4000-8000-000000000001';
    v_bug := true;
  exception when others then
    if sqlerrm !~ 'لا يمكن تعديل تاريخ السعر أو العيار' then
      raise exception 'BUG: رُفض تعديل service_role بخطأ غير متوقع: %', sqlerrm;
    end if;
  end;
  assert v_bug = false, 'BUG: قُبل تعديل karat_id عبر service_role -- الثبات يجب أن يُطبَّق بلا استثناء حتى على سياق موثوق';
  raise notice 'OK: لا استثناء لسياق موثوق (service_role) -- رُفض تعديل هوية سجل سعر موجود له أيضًا';
end $$;
set role authenticated;
set local request.jwt.claims = '{"sub":"f5000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- §3. Centralized Asia/Riyadh Business Date (hotfix item 3, migration 0056).
-- ---------------------------------------------------------------------------

-- 3.1 Definitional check + session-TimeZone independence: business_today()
-- must equal (now() at time zone 'Asia/Riyadh')::date exactly, and must NOT
-- change when the session's `TimeZone` GUC changes -- unlike Postgres' own
-- current_date, which is defined to follow the session TimeZone. This is
-- deterministic regardless of the real wall-clock instant the test happens
-- to run at (no reliance on hitting a specific day-boundary window).
do $$
declare
  v_expected date := (now() at time zone 'Asia/Riyadh')::date;
  v_under_utc date;
  v_under_extreme date;
begin
  assert public.business_today() = v_expected, format('BUG: business_today() = %s لا يطابق التعريف المتوقَّع (now() at time zone Asia/Riyadh)::date = %s', public.business_today(), v_expected);

  set local timezone to 'UTC';
  v_under_utc := public.business_today();

  set local timezone to 'Pacific/Kiritimati'; -- UTC+14, an extreme, arbitrary session zone
  v_under_extreme := public.business_today();

  assert v_under_utc = v_expected and v_under_extreme = v_expected,
    format('BUG: business_today() تغيّر بتغيّر إعداد timezone الخاص بالجلسة (UTC=%s, extreme=%s, متوقَّع=%s) -- يجب أن يكون مستقلًا عن إعداد الجلسة، مربوطًا بـAsia/Riyadh دائمًا', v_under_utc, v_under_extreme, v_expected);
  raise notice 'OK: business_today() يطابق تعريفه بدقة (%) ومستقل تمامًا عن إعداد timezone الخاص بجلسة الاتصال -- خلافًا لـcurrent_date المدمجة في Postgres', v_expected;
end $$;

-- Restore a sane session timezone before continuing (SET LOCAL is
-- transaction-scoped and would be rolled back regardless, but this keeps
-- the remaining sections' own date arithmetic unsurprising to read).
set local timezone to 'UTC';

-- 3.2 Functional wiring proof: temporarily redefine public.business_today()
-- (fully transactional -- this whole file runs inside begin;...rollback;,
-- so the redefinition below is undone automatically when the transaction
-- ends, exactly like every other piece of test data in this file) to a
-- fixed, deterministic sentinel date, then exercise create_manufacturing_
-- fee_version()'s "at most one Future Version" check (0053/0056) and
-- confirm its accept/reject pattern tracks the SENTINEL, not the real
-- server current_date -- the only way that pattern makes sense is if the
-- function genuinely calls public.business_today() at runtime, not a
-- hardcoded current_date. Run as the migration-owning connection (NOT
-- `authenticated`/`service_role`, which lack privilege to CREATE OR REPLACE
-- FUNCTION on an object they do not own) -- `reset role` returns to that
-- owning connection for just this block, then re-establishes the
-- `authenticated` actor context immediately after.
reset role;
reset request.jwt.claims;

do $$
declare
  v_sentinel constant date := '2099-06-15'::date;
begin
  create or replace function public.business_today()
  returns date
  language sql
  stable
  as $body$ select '2099-06-15'::date $body$;

  -- Sanity: the override actually took effect, and (crucially) differs from
  -- the real current_date, so the accept/reject pattern below cannot be
  -- explained by current_date coincidentally matching the sentinel.
  assert public.business_today() = v_sentinel, 'اختبار داخلي: فشل استبدال business_today() مؤقتًا';
  assert current_date <> v_sentinel, 'اختبار داخلي: current_date الحقيقي يطابق القيمة الوهمية صدفة -- غيّر v_sentinel';
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"f5000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_sentinel constant date := '2099-06-15'::date;
  v_v1 uuid;
  v_v2 uuid;
  v_rejected boolean := false;
begin
  -- "Current" version, effective exactly on the sentinel's business date --
  -- accepted (effective_from <= business_today(), not a future version).
  v_v1 := public.create_manufacturing_fee_version('e7000000-0000-4000-8000-000000000001', 9.0000, v_sentinel, 'حالي وفق business_today() المُستبدَلة');

  -- A genuinely future version relative to the SENTINEL (one day after it)
  -- -- accepted as the single scheduled Future Version.
  v_v2 := public.create_manufacturing_fee_version('e7000000-0000-4000-8000-000000000001', 9.5000, v_sentinel + 1, 'مستقبلي وفق business_today() المُستبدَلة');
  assert v_v2 is not null, 'BUG: رُفضت جدولة إصدار مستقبلي مشروع وفق business_today() المُستبدَلة';

  -- A SECOND future version, one more day out -- must be REJECTED because
  -- v_v2 (sentinel+1) is itself still "in the future" relative to the
  -- SENTINEL (business_today()) -- exactly the 0053 rule, but the only way
  -- this rejection is correct here is if the function is comparing against
  -- the sentinel, not the real (very different) server current_date, which
  -- would see sentinel+1 as a date decades in the past, not the future.
  begin
    perform public.create_manufacturing_fee_version('e7000000-0000-4000-8000-000000000001', 10.0000, v_sentinel + 2, 'يجب أن يُرفَض');
  exception when others then
    if sqlerrm ~ 'يوجد بالفعل إصدار مصنعية مستقبلي مجدوَل' then
      v_rejected := true;
    else
      raise exception 'BUG: رُفض الإصدار الثالث بخطأ غير متوقع: %', sqlerrm;
    end if;
  end;

  assert v_rejected, 'BUG: create_manufacturing_fee_version() لم يرفض إصدارًا مستقبليًا ثانيًا فوق إصدار مستقبلي قائم -- الدالة لا تستخدم business_today() فعليًا في وقت التشغيل (لا يزال يعتمد على current_date الحقيقي، الذي كان سيقبل هذا لأن sentinel+2 يقع في الماضي البعيد فعليًا وفق التاريخ الحقيقي)';
  raise notice 'OK: create_manufacturing_fee_version() يستخدم public.business_today() فعليًا في وقت التشغيل (لا current_date المدمجة) -- أُثبت عبر استبدال مؤقت لِـbusiness_today() بقيمة وهمية بعيدة عن current_date الحقيقي، والسلوك تبع القيمة الوهمية تمامًا';
end $$;

-- Restore the real business_today() definition (belt-and-suspenders --
-- ROLLBACK at the end of this file undoes it regardless, but this keeps
-- the session correct for any assertion added after this point in the
-- future).
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
set local request.jwt.claims = '{"sub":"f5000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- 3.3 Static source-inspection proof: every one of the six functions this
-- hotfix targets must reference business_today() in its actual body, and
-- must NOT reference the bare token current_date anywhere in that body
-- (pg_get_functiondef returns only the CREATE FUNCTION body, not the
-- separate COMMENT ON text, so this cannot be fooled by a comment merely
-- mentioning "current_date" in prose).
do $$
declare
  v_fn record;
  v_def text;
  v_targets text[] := array[
    'create_manufacturing_fee_version(uuid,numeric,date,text)',
    'create_payment_method_fee_version(uuid,numeric,numeric,date,text)',
    'cancel_manufacturing_fee_version(uuid)',
    'cancel_payment_method_fee_version(uuid)',
    'manufacturing_fee_for_karat_on_date(uuid,date)',
    'payment_fee_for_method_on_date(uuid,date)'
  ];
  v_target text;
begin
  foreach v_target in array v_targets loop
    v_def := pg_get_functiondef(('public.' || v_target)::regprocedure);
    assert v_def ~ 'business_today', format('BUG: تعريف %s لا يستدعي business_today() إطلاقًا', v_target);
    assert v_def !~ 'current_date', format('BUG: تعريف %s لا يزال يحتوي current_date -- الاستبدال غير مكتمل', v_target);
  end loop;
  raise notice 'OK: الدوال الست المستهدَفة (إنشاء/إلغاء المصنعية والعمولات + دالتا الاستعلام) تستدعي business_today() فعليًا في تعريفها ولا تحتوي current_date إطلاقًا';
end $$;

do $$
begin
  raise notice '=== ALL FINANCIAL INTEGRITY HOTFIX 2.2.1 TESTS PASSED (migrations 0055-0056) ===';
end $$;

rollback;
