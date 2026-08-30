-- ============================================================================
-- Integration test: Financial Integrity Patch 2.2 (migrations 0051-0054)
-- ============================================================================
-- Covers the three real gaps a follow-up code review found after Patch 2.1
-- shipped, as FORMAL assertions:
--
--   §1  Gold price source_type/source_name/source_reference/is_manual_
--       override can never be forged by an ordinary authenticated actor,
--       via the RPCs OR a raw direct INSERT/UPDATE -- external_api stays
--       reachable only from a trusted (service_role) context.
--   §2  The finance-safe "_safe" read RPCs return every financial value as
--       SQL `text` (the DB half of the transport-boundary fix -- the real
--       HTTP/PostgREST proof lives in scripts/run_postgrest_http_test.sh,
--       documented in DELIVERY_REPORT.md's Patch 2.2 appendix).
--   §3  At most one Future Version per karat/payment method -- scheduling a
--       second one on top of an already-scheduled, not-yet-effective one is
--       rejected outright; cancelling the first re-opens the slot.
--   §4  A brand-new daily price row can never be created for an inactive
--       karat (an existing row for that exact date/karat may still be
--       corrected).
--
-- This file is intentionally SEPARATE from financial_integrity_patch_2_1.
-- test.sql, financial_master_data.test.sql, and rls_and_permissions.test.sql
-- -- none of those are touched or reopened by this patch. All four files run
-- independently in CI/local verification, in order.
--
-- Safe to run against a real (including production-like staging) Supabase
-- database: everything happens inside a transaction that is ALWAYS rolled
-- back at the end, so no test data is left behind.
--
-- Requires migrations 0001-0054 + supabase/seed.sql to already be applied.
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/financial_integrity_patch_2_2.test.sql
--
-- Every assertion either raises (test fails, transaction aborts, non-zero
-- exit) or prints an "OK:" notice. Read the output top to bottom.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- Actors. Prefix 'f4...', distinct from every other test file's actors,
-- even though transaction rollback already isolates each file's own run.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('f4000000-0000-4000-8000-000000000001', 'test-patch22-manager@example.invalid');

update public.profiles set full_name = 'Test Patch 2.2 Manager', status = 'active', store_access_scope = 'all'
  where id = 'f4000000-0000-4000-8000-000000000001';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'f4000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in (
    'karats.view', 'karats.manage',
    'manufacturing_fees.view', 'manufacturing_fees.manage',
    'payment_methods.view', 'payment_methods.manage',
    'gold_prices.view', 'gold_prices.edit'
  );

set role authenticated;
set local request.jwt.claims = '{"sub":"f4000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
begin
  insert into public.karats (id, code, name_ar, sort_order, status) values
    ('e5000000-0000-4000-8000-000000000001', 'P22A', 'عيار اختبار Patch 2.2 — أ', 960, 'active'),
    ('e5000000-0000-4000-8000-000000000002', 'P22B', 'عيار اختبار Patch 2.2 — ب', 961, 'active'),
    ('e5000000-0000-4000-8000-000000000003', 'P22C', 'عيار اختبار Patch 2.2 — ج (سيُعطَّل)', 962, 'active');

  insert into public.payment_methods (id, key, name_ar, fee_model, sort_order, status) values
    ('e6000000-0000-4000-8000-000000000001', 'p22_both', 'اختبار Patch 2.2 — نسبة وثابت', 'percentage_plus_fixed', 960, 'active');
  raise notice 'OK: تجهيز بيانات اختبار Patch 2.2 (ثلاثة عيارات، طريقة دفع واحدة)';
end $$;

-- ---------------------------------------------------------------------------
-- §1. Gold price source integrity (spec item 1, migration 0051).
-- ---------------------------------------------------------------------------

-- 1.1 Direct INSERT by an authenticated actor holding gold_prices.edit,
-- attempting to fabricate source_type=external_api + source attribution +
-- is_manual_override=false -- must be silently forced back to safe manual
-- defaults, not merely rejected outright (RLS INSERT is still allowed here,
-- see 0051's design-choice rationale).
do $$
declare v_id uuid; v_source_type text; v_is_manual boolean; v_source_name text; v_source_ref text;
begin
  insert into public.daily_gold_prices
    (price_date, karat_id, price_per_gram, source_type, source_name, source_reference, is_manual_override)
  values
    (current_date - 500, 'e5000000-0000-4000-8000-000000000001', 250.0000, 'external_api', 'Fake Central Feed', 'FAKE-REF-001', false)
  returning id into v_id;

  select source_type, source_name, source_reference, is_manual_override
    into v_source_type, v_source_name, v_source_ref, v_is_manual
    from public.daily_gold_prices where id = v_id;

  assert v_source_type = 'manual', format('SECURITY BUG: قُبل source_type=external_api عبر INSERT مباشر من authenticated — وُجد %s', v_source_type);
  assert v_is_manual = true, 'SECURITY BUG: قُبل is_manual_override=false عبر INSERT مباشر من authenticated';
  assert v_source_name is null, format('SECURITY BUG: قُبل تلفيق source_name عبر INSERT مباشر — وُجد %s', v_source_name);
  assert v_source_ref is null, format('SECURITY BUG: قُبل تلفيق source_reference عبر INSERT مباشر — وُجد %s', v_source_ref);
  raise notice 'OK: محاولة تزوير source_type=external_api (+ بيانات مصدر ملفَّقة + is_manual_override=false) عبر INSERT مباشر من authenticated صُحِّحت تلقائيًا إلى manual/true/بلا مصدر';
end $$;

-- 1.2 Direct UPDATE on an existing (now-manual) row, same forgery attempt --
-- must also be forced back.
do $$
declare v_source_type text; v_is_manual boolean;
begin
  update public.daily_gold_prices
    set source_type = 'external_api', source_name = 'Fake Feed 2', source_reference = 'FAKE-REF-002', is_manual_override = false
    where price_date = current_date - 500 and karat_id = 'e5000000-0000-4000-8000-000000000001';

  select source_type, is_manual_override into v_source_type, v_is_manual
    from public.daily_gold_prices where price_date = current_date - 500 and karat_id = 'e5000000-0000-4000-8000-000000000001';

  assert v_source_type = 'manual', format('SECURITY BUG: قُبل source_type=external_api عبر UPDATE مباشر من authenticated — وُجد %s', v_source_type);
  assert v_is_manual = true, 'SECURITY BUG: قُبل is_manual_override=false عبر UPDATE مباشر من authenticated';
  raise notice 'OK: نفس محاولة التزوير عبر UPDATE مباشر صُحِّحت تلقائيًا أيضًا';
end $$;

-- 1.3 save_daily_gold_price()/save_daily_gold_prices_bulk() never accepted a
-- source_type field from the caller to begin with (already true since 0041/
-- 0050) -- confirm both RPCs still land on manual/true after 0051's trigger
-- is layered on top (belt-and-suspenders, not a regression).
do $$
declare v_source_type text; v_is_manual boolean;
begin
  perform public.save_daily_gold_price(current_date - 400, 'e5000000-0000-4000-8000-000000000002', 100.0000, null);
  select source_type, is_manual_override into v_source_type, v_is_manual
    from public.daily_gold_prices where price_date = current_date - 400 and karat_id = 'e5000000-0000-4000-8000-000000000002';
  assert v_source_type = 'manual' and v_is_manual = true, 'BUG: save_daily_gold_price() لم يعد ينتج manual/true بعد 0051';

  perform public.save_daily_gold_prices_bulk(current_date - 300, jsonb_build_array(
    jsonb_build_object('karat_id', 'e5000000-0000-4000-8000-000000000002', 'price_per_gram', 101.0000)
  ));
  select source_type, is_manual_override into v_source_type, v_is_manual
    from public.daily_gold_prices where price_date = current_date - 300 and karat_id = 'e5000000-0000-4000-8000-000000000002';
  assert v_source_type = 'manual' and v_is_manual = true, 'BUG: save_daily_gold_prices_bulk() لم يعد ينتج manual/true بعد 0051';
  raise notice 'OK: الدالتان save_daily_gold_price()/save_daily_gold_prices_bulk() ما زالتا تنتجان source_type=manual/is_manual_override=true بعد 0051 (طبقة حماية إضافية، لا كسر)';
end $$;

-- 1.4 external_api stays reachable from a TRUSTED context (service_role) --
-- proves the reserved path for a future integration actually still works,
-- not just that the exploit is closed.
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
do $$
declare v_source_type text; v_source_name text;
begin
  insert into public.daily_gold_prices
    (price_date, karat_id, price_per_gram, source_type, source_name, source_reference, is_manual_override)
  values
    (current_date - 200, 'e5000000-0000-4000-8000-000000000002', 260.0000, 'external_api', 'Real Future Feed', 'REF-100', false)
  returning source_type, source_name into v_source_type, v_source_name;

  assert v_source_type = 'external_api', 'BUG: سياق موثوق (service_role) يجب أن يستطيع تسجيل source_type=external_api لمسار تكامل مستقبلي';
  assert v_source_name = 'Real Future Feed', 'BUG: سياق موثوق يجب أن يستطيع تسجيل source_name فعليًا';
  raise notice 'OK: سياق موثوق (service_role) ما زال قادرًا على تسجيل source_type=external_api — المسار محجوز فعليًا لتكامل مستقبلي، لا مغلقًا بالكامل';
end $$;
set role authenticated;
set local request.jwt.claims = '{"sub":"f4000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- §2. Finance-safe read boundary — DB half (spec item 2). Every "_safe" RPC
-- must return `text`, not `numeric`, at the SQL level -- this is what makes
-- PostgREST serialize it as a quoted JSON string. pg_typeof() proves the
-- actual SQL return type directly (not just "the value looks numeric").
-- ---------------------------------------------------------------------------
do $$
begin
  perform public.save_daily_gold_price(current_date, 'e5000000-0000-4000-8000-000000000001', 275.1234, null);
  perform public.create_manufacturing_fee_version('e5000000-0000-4000-8000-000000000001', 12.3456, current_date - 30, 'اختبار الحدود المالية');
  perform public.create_payment_method_fee_version('e6000000-0000-4000-8000-000000000001', 2.750, 5.2500, current_date - 30, 'اختبار الحدود المالية');
end $$;

do $$
declare v_price_typeof text; v_price_text text; v_expected numeric;
begin
  select pg_typeof(public.gold_price_for_karat_on_date_safe('e5000000-0000-4000-8000-000000000001', current_date))::text into v_price_typeof;
  assert v_price_typeof = 'text', format('BUG: gold_price_for_karat_on_date_safe() يجب أن يُعيد text، وُجد %s', v_price_typeof);

  select public.gold_price_for_karat_on_date_safe('e5000000-0000-4000-8000-000000000001', current_date) into v_price_text;
  select public.gold_price_for_karat_on_date('e5000000-0000-4000-8000-000000000001', current_date) into v_expected;
  assert v_price_text::numeric = v_expected, format('BUG: قيمة gold_price_for_karat_on_date_safe() (%s) لا تطابق النسخة numeric الأصلية (%s)', v_price_text, v_expected);
  raise notice 'OK: gold_price_for_karat_on_date_safe() يُعيد text (نوع SQL فعلي) بقيمة مطابقة تمامًا للنسخة numeric الأصلية (%)', v_price_text;
end $$;

do $$
declare v_fee_typeof text; v_fee_text text; v_expected numeric;
begin
  select pg_typeof(public.manufacturing_fee_for_karat_on_date_safe('e5000000-0000-4000-8000-000000000001', current_date))::text into v_fee_typeof;
  assert v_fee_typeof = 'text', format('BUG: manufacturing_fee_for_karat_on_date_safe() يجب أن يُعيد text، وُجد %s', v_fee_typeof);

  select public.manufacturing_fee_for_karat_on_date_safe('e5000000-0000-4000-8000-000000000001', current_date) into v_fee_text;
  select public.manufacturing_fee_for_karat_on_date('e5000000-0000-4000-8000-000000000001', current_date) into v_expected;
  assert v_fee_text::numeric = v_expected, format('BUG: قيمة manufacturing_fee_for_karat_on_date_safe() (%s) لا تطابق النسخة numeric الأصلية (%s)', v_fee_text, v_expected);
  raise notice 'OK: manufacturing_fee_for_karat_on_date_safe() يُعيد text بقيمة مطابقة تمامًا (%)', v_fee_text;
end $$;

do $$
declare v_pct_typeof text; v_fixed_typeof text; v_pct_text text; v_fixed_text text; v_expected_pct numeric; v_expected_fixed numeric;
begin
  select pg_typeof(percentage_fee)::text, pg_typeof(fixed_fee)::text
    into v_pct_typeof, v_fixed_typeof
    from public.payment_fee_for_method_on_date_safe('e6000000-0000-4000-8000-000000000001', current_date);
  assert v_pct_typeof = 'text', format('BUG: payment_fee_for_method_on_date_safe().percentage_fee يجب أن يكون text، وُجد %s', v_pct_typeof);
  assert v_fixed_typeof = 'text', format('BUG: payment_fee_for_method_on_date_safe().fixed_fee يجب أن يكون text، وُجد %s', v_fixed_typeof);

  select percentage_fee, fixed_fee into v_pct_text, v_fixed_text
    from public.payment_fee_for_method_on_date_safe('e6000000-0000-4000-8000-000000000001', current_date);
  select percentage_fee, fixed_fee into v_expected_pct, v_expected_fixed
    from public.payment_fee_for_method_on_date('e6000000-0000-4000-8000-000000000001', current_date);
  assert v_pct_text::numeric = v_expected_pct and v_fixed_text::numeric = v_expected_fixed,
    format('BUG: قيم payment_fee_for_method_on_date_safe() (%s, %s) لا تطابق النسخة numeric الأصلية (%s, %s)', v_pct_text, v_fixed_text, v_expected_pct, v_expected_fixed);
  raise notice 'OK: payment_fee_for_method_on_date_safe() يُعيد percentage_fee/fixed_fee كـtext بقيمتين مطابقتين تمامًا (%, %)', v_pct_text, v_fixed_text;
end $$;

-- High-precision literal proof AT THE SQL LAYER (the HTTP/PostgREST-level
-- proof — the part that actually matters, since Postgres's own ::text cast
-- never loses precision by construction — lives in
-- scripts/run_postgrest_http_test.sh; see DELIVERY_REPORT.md's Patch 2.2
-- appendix for that run's actual output).
do $$
declare
  v_high_precision constant text := '123456789012345678.123456789';
  v_as_text text;
begin
  select (v_high_precision::numeric)::text into v_as_text;
  assert v_as_text = v_high_precision, format('BUG: تحويل numeric->text فقد الدقة عند مستوى SQL — توقعنا %s، وجدنا %s', v_high_precision, v_as_text);
  raise notice 'OK: قيمة عالية الدقة (%) تنجو من numeric->text بلا أي فقدان دقة على مستوى SQL — الإثبات عبر HTTP/PostgREST الفعلي موثَّق في تقرير التسليم', v_high_precision;
end $$;

-- ---------------------------------------------------------------------------
-- §3. At most one Future Version (spec item 3, migration 0053). The user's
-- own literal scenario, formalized, for BOTH manufacturing fees and payment
-- fees.
-- ---------------------------------------------------------------------------
do $$
declare v_future_10_id uuid; v_bug boolean := false;
begin
  -- Current = 8 (karat e5...0003, entirely fresh in this file).
  perform public.create_manufacturing_fee_version('e5000000-0000-4000-8000-000000000003', 8.0000, current_date - 10, 'الحالي = 8');

  -- Schedule Future = 10.
  v_future_10_id := public.create_manufacturing_fee_version('e5000000-0000-4000-8000-000000000003', 10.0000, current_date + 15, 'المستقبلي = 10 (1 سبتمبر بحسب المثال)');

  -- Attempt to schedule ANOTHER Future = 12 on top of 10, before 10 takes effect.
  begin
    perform public.create_manufacturing_fee_version('e5000000-0000-4000-8000-000000000003', 12.0000, current_date + 45, 'المستقبلي الثاني = 12 (1 أكتوبر) — يجب أن يُرفض');
    v_bug := true;
  exception when others then
    raise notice 'OK (spec item 3, مصنعية): رُفضت محاولة جدولة إصدار مستقبلي ثانٍ (12) فوق إصدار مستقبلي قائم (10) لم يسرِ بعد — %', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: قُبل إصدار مصنعية مستقبلي ثانٍ فوق إصدار مستقبلي قائم لم يسرِ بعد'; end if;

  -- Cancel 10 -> 8 must reopen -> scheduling 12 must now succeed.
  perform public.cancel_manufacturing_fee_version(v_future_10_id);
  assert (select status from public.manufacturing_fee_versions where karat_id = 'e5000000-0000-4000-8000-000000000003' and fee_per_gram = 8.0000) = 'active',
    'BUG: 8 يجب أن يُعاد فتحه بعد إلغاء 10';

  perform public.create_manufacturing_fee_version('e5000000-0000-4000-8000-000000000003', 12.0000, current_date + 45, 'المستقبلي الثاني = 12 — يجب أن يُقبل الآن بعد إلغاء 10');
  raise notice 'OK (spec item 3, مصنعية): بعد إلغاء 10 وإعادة فتح 8، قُبلت جدولة 12 بنجاح';
end $$;

-- Identical scenario, payment fees ("كرر للمصنعية وPayment Fees").
do $$
declare v_future_10_id uuid; v_bug boolean := false;
begin
  perform public.create_payment_method_fee_version('e6000000-0000-4000-8000-000000000001', 8.0, 0, current_date - 10, 'الحالي = 8% (تجاوز نسخة 2.75% السابقة)');
  -- (Note: 'e6...0001' already has an open version from §2's setup at
  -- current_date-30 -- this call ends it and becomes the new "current",
  -- itself already-effective as of current_date-10, i.e. genuinely current,
  -- not future -- required for the §3 invariant below to even be
  -- exercisable the same way as the manufacturing-fee case above.)

  v_future_10_id := public.create_payment_method_fee_version('e6000000-0000-4000-8000-000000000001', 10.0, 0, current_date + 45, 'المستقبلي = 10%');

  begin
    perform public.create_payment_method_fee_version('e6000000-0000-4000-8000-000000000001', 12.0, 0, current_date + 75, 'المستقبلي الثاني = 12% — يجب أن يُرفض');
    v_bug := true;
  exception when others then
    raise notice 'OK (spec item 3, عمولات): رُفضت محاولة جدولة إصدار عمولة مستقبلي ثانٍ (12%%) فوق إصدار مستقبلي قائم (10%%) لم يسرِ بعد — %', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: قُبل إصدار عمولة مستقبلي ثانٍ فوق إصدار مستقبلي قائم لم يسرِ بعد'; end if;

  perform public.cancel_payment_method_fee_version(v_future_10_id);
  assert (select status from public.payment_method_fee_versions where payment_method_id = 'e6000000-0000-4000-8000-000000000001' and percentage_fee = 8.0) = 'active',
    'BUG: عمولة 8%% يجب أن يُعاد فتحها بعد إلغاء 10%%';

  perform public.create_payment_method_fee_version('e6000000-0000-4000-8000-000000000001', 12.0, 0, current_date + 75, 'المستقبلي الثاني = 12%% — يجب أن يُقبل الآن');
  raise notice 'OK (spec item 3, عمولات — كرر الاختبار نفسه): بعد إلغاء 10%% وإعادة فتح 8%%، قُبلت جدولة 12%% بنجاح';
end $$;

-- ---------------------------------------------------------------------------
-- §4. Inactive-karat check for daily gold prices (spec item 4, migration
-- 0054). karat 'e5...0003' gets exactly one legitimate price row (for
-- current_date - 5) WHILE STILL ACTIVE, is THEN disabled, so §4.1-4.2 (a
-- date it never had a row for) and §4.3 (the one date it already has a row
-- for) can both be tested against the SAME now-inactive karat.
-- ---------------------------------------------------------------------------
do $$
begin
  perform public.save_daily_gold_price(current_date - 5, 'e5000000-0000-4000-8000-000000000003', 111.1111, 'سعر شرعي قبل التعطيل');
  update public.karats set status = 'inactive' where id = 'e5000000-0000-4000-8000-000000000003';
end $$;

-- 4.1 Brand-new price (a date this karat never had a row for) — rejected,
-- via save_daily_gold_price().
do $$
declare v_bug boolean := false;
begin
  begin
    perform public.save_daily_gold_price(current_date - 999, 'e5000000-0000-4000-8000-000000000003', 50.0000, null);
    v_bug := true;
  exception when others then
    raise notice 'OK: رُفض تسجيل سعر جديد لعيار غير نشط عبر save_daily_gold_price() (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: قُبل سعر جديد لعيار غير نشط عبر save_daily_gold_price()'; end if;
end $$;

-- 4.2 Same, via save_daily_gold_prices_bulk() — and the whole batch must
-- roll back (a valid karat in the SAME payload must not get saved either).
do $$
declare v_bug boolean := false; v_valid_saved boolean;
begin
  begin
    perform public.save_daily_gold_prices_bulk(current_date - 998, jsonb_build_array(
      jsonb_build_object('karat_id', 'e5000000-0000-4000-8000-000000000001', 'price_per_gram', 280.0000),
      jsonb_build_object('karat_id', 'e5000000-0000-4000-8000-000000000003', 'price_per_gram', 50.0000)
    ));
    v_bug := true;
  exception when others then
    raise notice 'OK: رُفضت الدفعة كاملة (تضم عيارًا غير نشط) عبر save_daily_gold_prices_bulk() (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: قُبلت دفعة تضم عيارًا غير نشط عبر save_daily_gold_prices_bulk()'; end if;

  select true into v_valid_saved from public.daily_gold_prices
    where price_date = current_date - 998 and karat_id = 'e5000000-0000-4000-8000-000000000001';
  assert v_valid_saved is null, 'BUG: العيار الصالح في نفس الدفعة الفاشلة لم يُرجَع بالكامل (تأكيد الذرّية)';
  raise notice 'OK: فشل عيار واحد غير نشط في الدفعة أرجع كل الدفعة بالكامل (لا حفظ جزئي)';
end $$;

-- 4.3 The ONE existing price row for the now-inactive karat (current_date -
-- 5, saved while it was still active, above) may still be corrected —
-- history/authorized corrections stay unblocked.
do $$
declare v_new_price numeric;
begin
  perform public.save_daily_gold_price(current_date - 5, 'e5000000-0000-4000-8000-000000000003', 999.9999, 'تصحيح لعيار عُطِّل لاحقًا');
  select price_per_gram into v_new_price from public.daily_gold_prices
    where price_date = current_date - 5 and karat_id = 'e5000000-0000-4000-8000-000000000003';
  assert v_new_price = 999.9999, 'BUG: تصحيح سعر موجود لعيار غير نشط يجب أن يُقبل';
  raise notice 'OK: تصحيح سعر موجود مسبقًا لعيار أصبح غير نشط لاحقًا لا يزال مسموحًا — لا يُحظَر إلا إنشاء سعر جديد';
end $$;

do $$
begin
  raise notice '=== ALL FINANCIAL INTEGRITY PATCH 2.2 TESTS PASSED (migrations 0051-0054) ===';
end $$;

rollback;
