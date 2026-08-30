-- ============================================================================
-- Integration test: Hotfix 4.2.1 legacy-upgrade proof (Section 22:
-- "Upgrade from 0105 with: active refund events, reversed legacy refund
-- events, and approved returns using fee-engine v1").
-- ============================================================================
-- Run AFTER supabase/tests/fixtures/hotfix_4_2_1_legacy_upgrade_pre_fixture.
-- sql was applied against a DB at migration 0105 + seed.sql, and AFTER
-- migrations 0106-latest were then applied on top — see
-- scripts/run_upgrade_test_hotfix_4_2_1.sh, which drives the whole sequence
-- in the correct order across separate psql invocations.
--
-- Re-identifies the three fixture rows via sales_orders.customer_name (the
-- fixture tags each order 'HF421-ACTIVE'/'HF421-REVERSED'/'HF421-FEEV1')
-- since this is a genuinely separate psql connection from the one that ran
-- the fixture.
--
-- Runs as superuser (no `set role authenticated`) for direct table reads —
-- proving the actual persisted state after upgrade — and a short `set role
-- authenticated` + `set local request.jwt.claims` block, scoped to one
-- statement at a time, wherever an RPC's own behavior needs proving
-- (mirrors upgrade_patch_4_2_legacy_returns.test.sql's own convention).
--
-- No wrapping BEGIN/COMMIT (autocommit) — this test only reads.
--
-- Requires: migrations 0001-latest + supabase/seed.sql applied, AND the
-- Hotfix 4.2.1 legacy pre-fixture applied BEFORE 0106-latest were applied.
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/upgrade_hotfix_4_2_1_legacy_refunds.test.sql
-- ============================================================================

-- ============================================================================
-- (A) HF421-ACTIVE — an event that was never reversed gets NO row in the new
-- reversal ledger, and still counts toward actual_refunded_total (Section 4).
-- ============================================================================
do $$
declare
  v_order_id uuid;
  v_return_id uuid;
  v_event_id uuid;
  v_legacy_status text;
  v_reversal_rows integer;
  v_return jsonb;
begin
  select id into v_order_id from public.sales_orders where customer_name = 'HF421-ACTIVE';
  select id into v_return_id from public.sales_returns where sales_order_id = v_order_id;
  select id, status into v_event_id, v_legacy_status from public.sales_return_refund_events where sales_return_id = v_return_id;

  assert v_legacy_status = 'active', format('A.1 عمود status القديم (متجمّد) يجب أن يبقى active لحدث لم يُعكَس أبدًا، وجد %s', v_legacy_status);

  select count(*) into v_reversal_rows from public.sales_return_refund_event_reversals where refund_event_id = v_event_id;
  assert v_reversal_rows = 0, format('A.2 يجب ألا يوجد أي صف في سجل الإلغاء الجديد لحدث نشط لم يُعكَس، وجد %s', v_reversal_rows);
  raise notice 'OK: A.1/A.2 حدث استرداد HF421-ACTIVE النشط بقي دون أي صف في sales_return_refund_event_reversals بعد الترقية';

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"dc000000-0000-4000-8000-000000000001","role":"authenticated"}';

  v_return := public.get_sales_return(v_return_id);
  assert v_return ->> 'actual_refunded_total' = '400.00', format('A.3 actual_refunded_total (المشتق من الملحق الجديد) يجب أن يبقى 400.00، وجد %s', v_return ->> 'actual_refunded_total');
  assert (v_return -> 'refund_events' -> 0 ->> 'status') = 'active', 'A.4 get_sales_return() يجب أن يعرض حالة الحدث active (مشتقة من غياب صف إلغاء)';
  raise notice 'OK: A.3/A.4 get_sales_return() بعد الترقية يشتق actual_refunded_total=400.00 وحالة الحدث active من الملحق append-only الجديد، لا من العمود القديم';
end $$;

-- ============================================================================
-- (B) HF421-REVERSED — a legacy status='reversed' event gets EXACTLY ONE row
-- in the new reversal ledger, carrying over the same historical reversal
-- facts, and actual_refunded_total (which already excluded it before
-- upgrade) is IDENTICAL after upgrade (Sections 1/2).
-- ============================================================================
do $$
declare
  v_order_id uuid;
  v_return_id uuid;
  v_event_id uuid;
  v_legacy_status text;
  v_legacy_reversed_at timestamptz;
  v_legacy_reversed_by uuid;
  v_legacy_reversal_reason text;
  v_legacy_reversal_business_date date;
  v_reversal_rows integer;
  v_new_reversed_at timestamptz;
  v_new_reversed_by uuid;
  v_new_reversal_reason text;
  v_new_reversal_business_date date;
  v_return jsonb;
begin
  select id into v_order_id from public.sales_orders where customer_name = 'HF421-REVERSED';
  select id into v_return_id from public.sales_returns where sales_order_id = v_order_id;
  select id, status, reversed_at, reversed_by, reversal_reason, reversal_business_date
    into v_event_id, v_legacy_status, v_legacy_reversed_at, v_legacy_reversed_by, v_legacy_reversal_reason, v_legacy_reversal_business_date
    from public.sales_return_refund_events where sales_return_id = v_return_id;

  -- The original row itself must be COMPLETELY UNCHANGED by the upgrade —
  -- the legacy status/reversed_* columns are frozen compatibility columns,
  -- never touched again after 0106's one-time backfill reads them (it never
  -- writes to them).
  assert v_legacy_status = 'reversed', format('B.1 عمود status القديم (متجمّد) يجب أن يبقى reversed كما كان قبل الترقية، وجد %s', v_legacy_status);
  assert v_legacy_reversal_reason = 'hf421 legacy upgrade fixture — reversed pre-4.2.1', 'B.1 سبب الإلغاء القديم يجب أن يبقى كما كُتب قبل الترقية بالضبط';
  raise notice 'OK: B.1 الصف الأصلي لحدث HF421-REVERSED بقي دون أي تغيير بعد الترقية — الأعمدة القديمة متجمّدة تاريخيًا فقط';

  select count(*) into v_reversal_rows from public.sales_return_refund_event_reversals where refund_event_id = v_event_id;
  assert v_reversal_rows = 1, format('B.2 يجب أن يوجد صف واحد بالضبط في سجل الإلغاء الجديد لحدث كان reversed وقت الترقية، وجد %s', v_reversal_rows);

  select reversed_at, reversed_by, reversal_reason, reversal_business_date
    into v_new_reversed_at, v_new_reversed_by, v_new_reversal_reason, v_new_reversal_business_date
    from public.sales_return_refund_event_reversals where refund_event_id = v_event_id;

  assert v_new_reversed_at = v_legacy_reversed_at, format('B.3 reversed_at في السجل الجديد (%s) يجب أن يطابق القيمة القديمة تمامًا (%s)', v_new_reversed_at, v_legacy_reversed_at);
  assert v_new_reversed_by = v_legacy_reversed_by, 'B.3 reversed_by في السجل الجديد يجب أن يطابق القيمة القديمة تمامًا';
  assert v_new_reversal_reason = v_legacy_reversal_reason, 'B.3 reversal_reason في السجل الجديد يجب أن يطابق القيمة القديمة تمامًا';
  assert v_new_reversal_business_date = v_legacy_reversal_business_date, format('B.3 reversal_business_date في السجل الجديد (%s) يجب أن يطابق القيمة القديمة تمامًا (%s)', v_new_reversal_business_date, v_legacy_reversal_business_date);
  raise notice 'OK: B.2/B.3 backfill 0106 أنشأ صفًا واحدًا بالضبط في sales_return_refund_event_reversals، حاملاً نفس حقائق الإلغاء التاريخية (السبب/المنفِّذ/التاريخ/الوقت) دون أي اختلاق';

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"dc000000-0000-4000-8000-000000000001","role":"authenticated"}';

  v_return := public.get_sales_return(v_return_id);
  -- Already excluded the reversed event's amount BEFORE the upgrade (the
  -- pre-0106 status='active' filter already skipped it) — this proves the
  -- total is IDENTICAL before and after migration, not merely non-null.
  assert v_return ->> 'actual_refunded_total' = '0.00', format('B.4 actual_refunded_total (مشتق من الملحق الجديد) يجب أن يبقى 0.00 (كما كان قبل الترقية بالفلترة القديمة)، وجد %s', v_return ->> 'actual_refunded_total');
  assert (v_return -> 'refund_events' -> 0 ->> 'status') = 'reversed', 'B.5 get_sales_return() يجب أن يعرض حالة الحدث reversed (مشتقة من وجود صف إلغاء)، لا من العمود القديم';
  raise notice 'OK: B.4/B.5 actual_refunded_total يبقى 0.00 قبل وبعد الترقية بالضبط، وget_sales_return() يشتق status=reversed من الملحق append-only الجديد';
end $$;

-- ============================================================================
-- (C) HF421-FEEV1 — an approved return computed under the OLD v1
-- (item-value/covers-all-remaining) fee engine keeps its EXACT historical
-- payment_fee_reversal_amount after upgrade, tagged calculation_version=1,
-- never silently recomputed to the corrected v2 value (Section 13).
-- ============================================================================
do $$
declare
  v_order_id uuid;
  v_return_id uuid;
  v_fee_reversal numeric;
  v_calc_version integer;
begin
  select id into v_order_id from public.sales_orders where customer_name = 'HF421-FEEV1';
  select id, payment_fee_reversal_amount, payment_fee_reversal_calculation_version
    into v_return_id, v_fee_reversal, v_calc_version
    from public.sales_returns where sales_order_id = v_order_id;

  -- v1's covers_all_remaining branch (single-item order, fully returned)
  -- reversed the FULL original fee (100.00) despite only 400.00 of the
  -- 1000.00 order ever being approved for cash refund (a 100.00 deduction)
  -- — this IS the historical bug Hotfix 4.2.1 fixes for every NEW approval
  -- going forward (Section 7); the CORRECT v2 answer would have been 40.00
  -- (100 * 400/1000), but this pre-existing row must NEVER be silently
  -- corrected to that value by the upgrade.
  assert v_fee_reversal = 100.00, format('C.1 payment_fee_reversal_amount التاريخي (محسوب بمحرك v1 القديم) يجب أن يبقى 100.00 دون أي إعادة احتساب صامتة، وجد %s', v_fee_reversal);
  assert v_calc_version = 1, format('C.2 backfill 0106 يجب أن يعيّن payment_fee_reversal_calculation_version=1 لهذا المرتجع المعتمَد قبل الترقية، وجد %s', v_calc_version);
  raise notice 'OK: C.1/C.2 مرتجع HF421-FEEV1 المعتمَد بمحرك العمولة v1 القديم (100.00، وهي القيمة الخاطئة تاريخيًا) بقي دون أي إعادة احتساب صامتة بعد الترقية، ومُعلَّم بـ calculation_version=1 (Section 13)';
end $$;

\echo ''
\echo 'ALL upgrade_hotfix_4_2_1_legacy_refunds.test.sql ASSERTIONS PASSED (Sections 1/2/4/13 legacy refund-ledger/fee-engine upgrade safety)'
