-- ============================================================================
-- Patch 6.1 item 35/37 — POST-upgrade assertions for the real pre-existing-
-- data upgrade path (0001-0143 + seed.sql + real Phase-6-Core fixture data,
-- created under the OLD RPC/schema contracts, THEN 0144-latest applied on
-- top in a SEPARATE psql invocation — exactly like a real production
-- upgrade).
--
-- This file does NOT build anything and does NOT create the fixtures — it
-- only reads back public.p6u61_scratch (populated by
-- supabase/tests/fixtures/patch_6_1_upgrade_pre_fixture.sql, which ran
-- BEFORE 0144+ were applied) and asserts, against the NOW-migrated schema
-- and the NEW v2 RPCs:
--
--   (a) Fixture 1 (pending, cost already set under the old ungated RPC) —
--       still pending, has_direct_cost=true, original_direct_cost visible.
--   (b) Fixture 2 (approved, paid) — original_net_adjustment_profit AND
--       effective_net_adjustment_profit both still 67.50 (approved,
--       non-reversed) — untouched by the migration, as expected.
--   (c) Fixture 3 (approved, free, pre-patch BUGGY net=-15.00/fee=5.00) —
--       THE critical proof: 0144's rewritten backfill (this window's fix)
--       must have deterministically corrected this to fee=0.00/net=-10.00,
--       nulled payment_method_id/collection_channel_id/payment_reference/
--       the fee snapshot columns, and forced participates_in_settlement to
--       false — checked both via the new get_sales_order_adjustment() RPC
--       and via a direct service_role read of the base table.
--   (d) Fixture 4 (approved then reversed, under the OLD 0141 reversal RPC,
--       predating the 5 signed impact columns) — 0150's own backfill must
--       have populated all 5 columns correctly from the pre-existing
--       snapshot, and effective_net_adjustment_profit must now read 0.00
--       via the new RPC while original_net_adjustment_profit stays 30.00.
--   (e) Fixture 5 (approved, type renamed AFTER approval, entirely under the
--       OLD schema) — the historical name snapshot must still show the OLD
--       name post-migration, proving the snapshot survived the SCHEMA
--       MIGRATION itself, not merely subsequent live RPC calls.
--   (f) Historical IDs/adjustment_numbers/order_number are byte-identical to
--       what the pre-fixture script recorded — no row was ever re-created,
--       renumbered, or lost by the migration.
--   (g) No duplicate/missing permission rows — Patch 6.1 introduces zero new
--       permission keys (unlike Phase 6 Core's own 0133), so a simple count
--       sanity check is sufficient here.
--   (h) Final unconditional cleanup: drop the scratch table.
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/upgrade_patch_6_1_fixtures.test.sql
--
-- See scripts/run_upgrade_test_patch_6_1.sh for the full 3-phase
-- orchestration this file is the final step of.
-- ============================================================================

begin;

set role authenticated;
set local request.jwt.claims = '{"sub":"a6300000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- (a) Fixture 1 — pending with direct_cost set under the OLD ungated RPC.
-- ---------------------------------------------------------------------------
do $$
declare
  v_id uuid := (select value::uuid from public.p6u61_scratch where label = 'adj_pending_id');
  v_number text := (select value from public.p6u61_scratch where label = 'adj_pending_number');
  v_row record;
begin
  select * into v_row from public.get_sales_order_adjustment(v_id);
  assert v_row.adjustment_number = v_number, format('BUG (a): رقم التعديل تغيّر بعد الترقية: %s <> %s', v_row.adjustment_number, v_number);
  assert v_row.status = 'pending', format('BUG (a): يجب أن يبقى قيد الانتظار بعد الترقية، الحالة الحالية %s', v_row.status);
  assert v_row.has_direct_cost = true, 'BUG (a): has_direct_cost يجب أن تكون true (تكلفة مباشرة مضبوطة مسبقًا تحت المخطط القديم)';
  assert v_row.original_direct_cost = '22.50', format('BUG (a): original_direct_cost المتوقع 22.50، وُجد %s', v_row.original_direct_cost);
  raise notice 'PASS (a): fixture 1 (pending, cost pre-set) نجت من الترقية بدون تغيير — %', v_number;
end $$;

-- ---------------------------------------------------------------------------
-- (b) Fixture 2 — approved, paid (visa 2.5%/0): untouched by the migration.
-- ---------------------------------------------------------------------------
do $$
declare
  v_id uuid := (select value::uuid from public.p6u61_scratch where label = 'adj_paid_id');
  v_number text := (select value from public.p6u61_scratch where label = 'adj_paid_number');
  v_row record;
begin
  select * into v_row from public.get_sales_order_adjustment(v_id);
  assert v_row.adjustment_number = v_number, format('BUG (b): رقم التعديل تغيّر: %s <> %s', v_row.adjustment_number, v_number);
  assert v_row.status = 'approved', format('BUG (b): الحالة المتوقعة approved، وُجد %s', v_row.status);
  assert v_row.payment_method_id is not null, 'BUG (b): طريقة الدفع يجب ألا تُمسح لسجل مدفوع حقيقي';
  assert v_row.original_payment_fee_amount = '2.50', format('BUG (b): العمولة الأصلية المتوقعة 2.50، وُجد %s', v_row.original_payment_fee_amount);
  assert v_row.original_net_adjustment_profit = '67.50', format('BUG (b): صافي الربح الأصلي المتوقع 67.50، وُجد %s', v_row.original_net_adjustment_profit);
  assert v_row.effective_net_adjustment_profit = '67.50', format('BUG (b): صافي الربح الفعلي المتوقع 67.50 (معتمد وغير معكوس)، وُجد %s', v_row.effective_net_adjustment_profit);
  raise notice 'PASS (b): fixture 2 (approved, paid) صافي ربحه 67.50 لم يتأثر بالترقية — %', v_number;
end $$;

-- ---------------------------------------------------------------------------
-- (c) Fixture 3 — approved, FREE, pre-patch buggy net=-15.00/fee=5.00.
-- THE critical proof: 0144's backfill must have corrected this.
-- ---------------------------------------------------------------------------
do $$
declare
  v_id uuid := (select value::uuid from public.p6u61_scratch where label = 'adj_free_id');
  v_number text := (select value from public.p6u61_scratch where label = 'adj_free_number');
  v_row record;
begin
  select * into v_row from public.get_sales_order_adjustment(v_id);
  assert v_row.adjustment_number = v_number, format('BUG (c): رقم التعديل تغيّر: %s <> %s', v_row.adjustment_number, v_number);
  assert v_row.status = 'approved', format('BUG (c): الحالة المتوقعة approved، وُجد %s', v_row.status);
  assert v_row.payment_method_id is null, 'BUG (c): طريقة الدفع يجب أن تُصبح NULL بعد إعادة الضبط لخدمة مجانية';
  assert v_row.collection_channel_id is null, 'BUG (c): قناة التحصيل يجب أن تُصبح NULL بعد إعادة الضبط';
  assert v_row.payment_reference is null, 'BUG (c): مرجع الدفع يجب أن يكون NULL لخدمة مجانية';
  assert v_row.participates_in_settlement = false, 'BUG (c): participates_in_settlement يجب أن تُصبح false';
  assert v_row.original_payment_fee_amount = '0.00', format('BUG (c) — إصلاح الترقية 6.1 (البندان 9/10) لم يعمل: العمولة الأصلية المتوقعة بعد الإصلاح 0.00 (كانت خاطئة 5.00 قبل الترقية)، وُجد %s', v_row.original_payment_fee_amount);
  assert v_row.original_gross_adjustment_profit = '-10.00', format('BUG (c): الربح الإجمالي الأصلي يجب أن يبقى -10.00 (لم يعتمد يومًا على العمولة)، وُجد %s', v_row.original_gross_adjustment_profit);
  assert v_row.original_net_adjustment_profit = '-10.00', format('BUG (c) — إصلاح الترقية 6.1 لم يعمل: صافي الربح الأصلي المتوقع بعد الإصلاح -10.00 (كان خاطئًا -15.00 قبل الترقية)، وُجد %s', v_row.original_net_adjustment_profit);
  assert v_row.effective_net_adjustment_profit = '-10.00', format('BUG (c): صافي الربح الفعلي المتوقع -10.00 (معتمد وغير معكوس)، وُجد %s', v_row.effective_net_adjustment_profit);
  raise notice 'PASS (c): fixture 3 (approved, free — العطل ما قبل الترقية) صُحح بنجاح بعد 0144: العمولة 5.00->0.00، صافي الربح -15.00->-10.00 — %', v_number;
end $$;

-- Extra rigor for (c): a direct service_role read of the base table snapshot
-- columns themselves (not merely the RPC's projection), proving the backfill
-- actually rewrote the row and did not merely mask it in the read RPC.
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
do $$
declare
  v_id uuid := (select value::uuid from public.p6u61_scratch where label = 'adj_free_id');
  v_row public.sales_order_adjustments;
begin
  select * into v_row from public.sales_order_adjustments where id = v_id;
  assert v_row.payment_fee_version_id is null, 'BUG (c raw): payment_fee_version_id يجب أن يُصبح NULL بعد الترحيل';
  assert v_row.payment_fee_percentage_snapshot is null, 'BUG (c raw): payment_fee_percentage_snapshot يجب أن يُصبح NULL';
  assert v_row.payment_fee_fixed_snapshot is null, 'BUG (c raw): payment_fee_fixed_snapshot يجب أن يُصبح NULL';
  assert v_row.payment_method_name_snapshot is null, 'BUG (c raw): payment_method_name_snapshot يجب أن يُصبح NULL';
  assert v_row.collection_channel_name_snapshot is null, 'BUG (c raw): collection_channel_name_snapshot يجب أن يُصبح NULL';
  assert v_row.payment_fee_amount = 0, format('BUG (c raw): payment_fee_amount المتوقع 0.00، وُجد %s', v_row.payment_fee_amount);
  assert v_row.net_adjustment_profit = v_row.gross_adjustment_profit, format('BUG (c raw): net_adjustment_profit (%s) يجب أن يساوي gross_adjustment_profit (%s) لخدمة مجانية', v_row.net_adjustment_profit, v_row.gross_adjustment_profit);
  raise notice 'PASS (c raw): قراءة مباشرة (service_role) للجدول الأساسي تؤكد أن الترحيل أعاد كتابة أعمدة اللقطة فعليًا، وليس فقط إخفاءها في RPC القراءة';
end $$;
set role authenticated;
reset request.jwt.claims;
set local request.jwt.claims = '{"sub":"a6300000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- (d) Fixture 4 — approved then reversed under the OLD 0141 reversal RPC,
-- whose row predates the 5 signed impact columns entirely. 0150's own
-- backfill must have populated them correctly.
-- ---------------------------------------------------------------------------
do $$
declare
  v_id uuid := (select value::uuid from public.p6u61_scratch where label = 'adj_reversed_id');
  v_number text := (select value from public.p6u61_scratch where label = 'adj_reversed_number');
  v_row record;
begin
  select * into v_row from public.get_sales_order_adjustment(v_id);
  assert v_row.adjustment_number = v_number, format('BUG (d): رقم التعديل تغيّر: %s <> %s', v_row.adjustment_number, v_number);
  assert v_row.status = 'approved', format('BUG (d): الحالة المخزنة يجب أن تبقى approved (العكس سجل إداري منفصل)، وُجد %s', v_row.status);
  assert v_row.effective_status = 'reversed', format('BUG (d): الحالة الفعلية المتوقعة reversed، وُجد %s', v_row.effective_status);
  assert v_row.original_net_adjustment_profit = '30.00', format('BUG (d): صافي الربح الأصلي (اللقطة المعتمدة) يجب أن يبقى 30.00 دون تغيير، وُجد %s', v_row.original_net_adjustment_profit);
  assert v_row.effective_net_adjustment_profit = '0.00', format('BUG (d): صافي الربح الفعلي المتوقع 0.00 بعد العكس، وُجد %s', v_row.effective_net_adjustment_profit);
  raise notice 'PASS (d): fixture 4 (approved ثم معكوس تحت RPC 0141 القديم) — original=30.00 effective=0.00 عبر RPC الجديد — %', v_number;
end $$;

set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
do $$
declare
  v_reversal_id uuid := (select value::uuid from public.p6u61_scratch where label = 'reversal_id');
  v_row public.sales_order_adjustment_reversals;
begin
  select * into v_row from public.sales_order_adjustment_reversals where id = v_reversal_id;
  assert v_row.id is not null, 'BUG (d raw): سجل العكس القديم يجب أن يكون موجودًا بعد الترقية';
  assert v_row.customer_charge_reversal_amount = -50.00, format('BUG (d raw) — إصلاح 0150 لم يعمل: customer_charge_reversal_amount المتوقع -50.00، وُجد %s', v_row.customer_charge_reversal_amount);
  assert v_row.direct_cost_reversal_amount = 20.00, format('BUG (d raw) — إصلاح 0150 لم يعمل: direct_cost_reversal_amount المتوقع 20.00، وُجد %s', v_row.direct_cost_reversal_amount);
  assert v_row.payment_fee_reversal_amount = 0.00, format('BUG (d raw) — إصلاح 0150 لم يعمل: payment_fee_reversal_amount المتوقع 0.00، وُجد %s', v_row.payment_fee_reversal_amount);
  assert v_row.gross_profit_reversal_amount = -30.00, format('BUG (d raw) — إصلاح 0150 لم يعمل: gross_profit_reversal_amount المتوقع -30.00، وُجد %s', v_row.gross_profit_reversal_amount);
  assert v_row.net_profit_reversal_amount = -30.00, format('BUG (d raw) — إصلاح 0150 لم يعمل: net_profit_reversal_amount المتوقع -30.00، وُجد %s', v_row.net_profit_reversal_amount);
  raise notice 'PASS (d raw): backfill 0150 ملأ الأعمدة الخمسة المُوقّعة الجديدة بشكل صحيح لسجل عكس أُنشئ بالكامل تحت المخطط القديم (0141)';
end $$;
set role authenticated;
reset request.jwt.claims;
set local request.jwt.claims = '{"sub":"a6300000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- (e) Fixture 5 — approved, type renamed AFTERWARD (entirely under the OLD
-- schema) — the historical name snapshot must survive the SCHEMA MIGRATION
-- itself, not merely subsequent live RPC calls (already proven separately
-- in adjustments_core_phase6.test.sql's own item-25 tests).
-- ---------------------------------------------------------------------------
do $$
declare
  v_id uuid := (select value::uuid from public.p6u61_scratch where label = 'adj_renamed_id');
  v_number text := (select value from public.p6u61_scratch where label = 'adj_renamed_number');
  v_type_id uuid := (select value::uuid from public.p6u61_scratch where label = 'type_renamed_id');
  v_row record;
  v_live_name text;
begin
  select * into v_row from public.get_sales_order_adjustment(v_id);
  assert v_row.adjustment_number = v_number, format('BUG (e): رقم التعديل تغيّر: %s <> %s', v_row.adjustment_number, v_number);
  select name_ar into v_live_name from public.adjustment_types where id = v_type_id;
  assert v_live_name = 'نوع ترقية 6.1 — بعد إعادة التسمية', format('BUG (e) setup: الاسم الحي الحالي للنوع غير متوقع: %s', v_live_name);
  assert v_row.adjustment_type_name_ar = 'نوع ترقية 6.1 — قبل إعادة التسمية', format('BUG (e): اللقطة التاريخية يجب أن تُظهر الاسم القديم رغم إعادة التسمية والترقية معًا، وُجد %s', v_row.adjustment_type_name_ar);
  raise notice 'PASS (e): fixture 5 — اللقطة التاريخية لاسم النوع نجت من إعادة التسمية (تحت المخطط القديم) ومن ترحيل المخطط نفسه (0144-latest) معًا — %', v_number;
end $$;

-- ---------------------------------------------------------------------------
-- (e2) Hotfix 6.1.1 item 2 — Fixture 6: REJECTED zero-charge adjustment,
-- created under the OLD contract (customer_charge=0 legal pre-0144, but
-- payment_method_id/collection_channel_id still NOT NULL then) and rejected
-- via the OLD reject RPC. THE critical proof for this hotfix: 0144's
-- rewritten backfill must normalize the operational payment fields for a
-- REJECTED row too (the original 0144 draft only handled pending/approved,
-- which would otherwise make 0144 itself fail applying its own new
-- zero-charge CHECK against exactly this row shape). A rejected row never
-- carries a financial snapshot, so nothing here should be recomputed.
-- ---------------------------------------------------------------------------
do $$
declare
  v_id uuid := (select value::uuid from public.p6u61_scratch where label = 'adj_rejfree_id');
  v_number text := (select value from public.p6u61_scratch where label = 'adj_rejfree_number');
  v_row record;
begin
  select * into v_row from public.get_sales_order_adjustment(v_id);
  assert v_row.adjustment_number = v_number, format('BUG (e2): رقم التعديل تغيّر: %s <> %s', v_row.adjustment_number, v_number);
  assert v_row.status = 'rejected', format('BUG (e2): الحالة يجب أن تبقى rejected بعد الترقية، وُجد %s', v_row.status);
  assert v_row.effective_status = 'rejected', format('BUG (e2): effective_status المتوقعة rejected، وُجد %s', v_row.effective_status);
  assert v_row.customer_charge = '0.00', format('BUG (e2): customer_charge يجب أن يبقى 0.00، وُجد %s', v_row.customer_charge);
  assert v_row.payment_method_id is null, 'BUG (e2) — إصلاح Hotfix 6.1.1 البند 1 لم يعمل: طريقة الدفع يجب أن تُصبح NULL لسجل مرفوض بقيمة تحصيل صفرية بعد الترقية';
  assert v_row.collection_channel_id is null, 'BUG (e2) — إصلاح Hotfix 6.1.1 البند 1 لم يعمل: قناة التحصيل يجب أن تُصبح NULL';
  assert v_row.payment_reference is null, 'BUG (e2): مرجع الدفع يجب أن يكون NULL';
  assert v_row.participates_in_settlement = false, 'BUG (e2): participates_in_settlement يجب أن تُصبح false';
  raise notice 'PASS (e2): fixture 6 (مرفوض، تحصيل صفري بالشكل القديم) — إصلاح Hotfix 6.1.1 البند 1 عمل بنجاح: حقول الدفع أُعيد ضبطها إلى NULL/false دون أي مساس بالحالة rejected أو سبب الرفض — %', v_number;
end $$;

-- Extra rigor for (e2): a direct service_role read confirms rejection
-- metadata (reason/by/at) and identity are entirely untouched by 0144.
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
do $$
declare
  v_id uuid := (select value::uuid from public.p6u61_scratch where label = 'adj_rejfree_id');
  v_row public.sales_order_adjustments;
begin
  select * into v_row from public.sales_order_adjustments where id = v_id;
  assert v_row.rejection_reason = 'P6U61 رفض — سبب اختباري لترقية 6.1.1', format('BUG (e2 raw): سبب الرفض تغيّر بعد الترقية: %s', v_row.rejection_reason);
  assert v_row.rejected_by is not null, 'BUG (e2 raw): rejected_by يجب أن يبقى موجودًا';
  assert v_row.rejected_at is not null, 'BUG (e2 raw): rejected_at يجب أن يبقى موجودًا';
  assert v_row.payment_fee_amount is null, 'BUG (e2 raw): سجل مرفوض لا يجب أن يحمل أي لقطة مالية إطلاقًا (لا قبل ولا بعد الترقية)';
  raise notice 'PASS (e2 raw): بيانات الرفض التاريخية (السبب/المُنفِّذ/التاريخ) سليمة تمامًا بعد الترقية، ولا لقطة مالية اختُلِقت لسجل مرفوض';
end $$;
set role authenticated;
reset request.jwt.claims;
set local request.jwt.claims = '{"sub":"a6300000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- (f) Historical IDs/order_number preserved exactly — sanity cross-check
-- against the shared Sales Order all 6 fixtures were attached to.
-- ---------------------------------------------------------------------------
do $$
declare
  v_order_id uuid := (select value::uuid from public.p6u61_scratch where label = 'order_id');
  v_order_number text := (select value from public.p6u61_scratch where label = 'order_number');
  v_row record;
  v_count integer;
begin
  select * into v_row from public.get_sales_order_adjustment((select value::uuid from public.p6u61_scratch where label = 'adj_paid_id'));
  assert v_row.sales_order_id = v_order_id, 'BUG (f): sales_order_id تغيّر بعد الترقية';
  assert v_row.order_number = v_order_number, format('BUG (f): رقم عملية البيع تغيّر: %s <> %s', v_row.order_number, v_order_number);

  select count(*) into v_count from public.list_sales_order_adjustments(v_order_id);
  assert v_count = 6, format('BUG (f): يجب أن تظهر 6 تعديلات لعملية البيع المشتركة بعد الترقية (لا فقدان بيانات ولا تكرار)، وُجد %s', v_count);
  raise notice 'PASS (f): المعرّفات/الأرقام التاريخية سليمة تمامًا بعد الترقية — 6 تعديلات كما هي متوقعة على عملية البيع %', v_order_number;
end $$;

-- ---------------------------------------------------------------------------
-- (g) No new permission keys from Patch 6.1 (unlike Phase 6 Core's own
-- 0133) — a simple non-duplication sanity check.
-- ---------------------------------------------------------------------------
do $$
declare
  v_count integer;
begin
  select count(*) into v_count from public.permissions where category = 'adjustments';
  assert v_count = 7, format('BUG (g): عدد صلاحيات adjustments غير متوقع بعد الترقية (لا يجب أن تُضيف Patch 6.1 أي صلاحية جديدة ولا تُكرر القديمة) — المتوقع 7 (3 من seed.sql: view/create/approve + 4 من 0133: manage_cost/reverse/process_closed_day/manage_types)، وُجد %s', v_count);
  raise notice 'PASS (g): لا صلاحيات جديدة ولا مكررة أُضيفت بواسطة Patch 6.1 (7 صلاحيات adjustments كما هي من seed.sql + Phase 6 Core 0133 فقط)';
end $$;

do $$
begin
  raise notice '=== ALL PATCH 6.1 UPGRADE-FIXTURES ASSERTIONS PASSED (0144-latest applied onto REAL pre-existing Phase-6-Core data created under the OLD RPC/schema contracts) ===';
end $$;

rollback;

-- ---------------------------------------------------------------------------
-- (h) Final unconditional cleanup — committed immediately (outside the
-- rolled-back assertion transaction above), so this test file leaves no
-- residue behind regardless of how it is re-run.
-- ---------------------------------------------------------------------------
drop table if exists public.p6u61_scratch;
