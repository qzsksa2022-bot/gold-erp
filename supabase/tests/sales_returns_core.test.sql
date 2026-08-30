-- ============================================================================
-- Integration test: Phase 4 — Returns Integrity Patch 4.1 (migrations
-- 0082-0098)
-- ============================================================================
-- Supersedes the pre-Patch-4.1 version of this file. Covers everything the
-- original Phase 4 Returns Core file covered (full/partial return
-- derivation, cumulative payment-fee-reversal capping with final-allocation
-- rounding absorption, the actual-cash-refund ledger, closed-day gating,
-- snapshot-only calculation, profit-field hiding, audit_logs return.%
-- profit-protection policy) PLUS the mandatory Patch 4.1 scenarios (Section
-- 18), each tagged inline with its letter:
--
--   A — pending-membership vs effective-claim: multiple PENDING returns can
--       coexist on the same sales_order_item_id (Section 5).
--   B — only one of several pending returns on the same item can ever
--       become the effective (approved) claim; approving a second is
--       rejected by the real unique-index-backed constraint via a friendly
--       pre-check message (Section 5).
--   C — history preservation: an item still shows on a REJECTED return
--       (Section 6), never a phantom item_count=0.
--   D — history preservation: an item still shows on a REVERSED return
--       (Section 6), and the item becomes returnable again.
--   E — refund amounts with more than 2 decimal places are REJECTED, never
--       silently rounded (Section 10).
--   F — customer_never_received + not_collected allows approved_refund_
--       amount=0 while sales_revenue_reversal_amount still reverses fully
--       (Section 2).
--   G — customer_never_received + not_collected + a nonzero refund amount
--       is hard-rejected by a database CHECK constraint (Section 2).
--   H — return_date must be >= the Sale's date (Section 7).
--   I — a stale Sale snapshot (Sale edited after the return was created) is
--       rejected at approval with a hard, explicit message, and
--       refresh_pending_sales_return_from_sale() is the only way to clear
--       it (Section 4).
--   J — refund_fee_policy='full_reversal' reverses ZERO fee on a partial
--       (non-full-coverage) return and absorbs the full remaining balance
--       only at the return that completes full coverage (Section 8).
--   K — finalize_sales_return_refund() requires a variance reason when the
--       actual refunded total differs from approved_refund_amount, and
--       supports approved_refund_amount=0 reaching a final
--       ('finalized_matched') state with zero refund events ever created
--       (Section 11).
--   L — store-scope for historical corrections (reject/reverse/refund) is
--       VISIBLE, not OPERABLE — a later-disabled store does not block them
--       (Section 13).
--   M — list_sales_returns() supports filtering by original store, order
--       number, and scenario (Section 14).
--   N — returned-item condition is tracked and visible, historical-only —
--       no Inventory table is ever touched by any Returns RPC (Section 3).
--   O — the full Section 12 financial-effect field set (including
--       adjusted_order_net_sales_profit) is computed and exposed via
--       get_sales_return().
--   P — audit_logs carries the new return.refund_finalized action, subject
--       to the same return.% profit-protection policy as every other
--       Returns action (Section 17 + 0091's policy, extended).
--
-- Patch 4.2 (migrations 0099-0105) scenarios, each tagged inline:
--   Q — requires_sale_refresh is an independent, stricter guard than
--       source_sale_row_version; approve_sales_return() rejects until an
--       explicit refresh_pending_sales_return_from_sale() call (Section 1).
--   R — refund reconciliation state machine (record path): finalize ->
--       reject direct record -> reopen (reason required) -> record
--       succeeds -> finalize again creates a SECOND historical event,
--       first one never erased (Section 3/4).
--   S — the same state machine for the refund-event-reversal path.
--   U — business-date chronology: reversal/refund dates must not precede
--       approval or return_date; a refund-reversal must not precede its
--       own original refund date; future-date rejection remains (Section 6).
--   V — preview_sales_return() parity with create/approve's own validation
--       tree and suggestion logic, including never silently overriding an
--       explicitly-supplied approved_refund_amount (Section 5).
--
-- sales_orders/sales_order_items/sales_returns/sales_return_items/
-- sales_return_refund_events all have ZERO direct SELECT RLS policies for
-- `authenticated` (0059/0082) — every lookup this file needs is either
-- read through an RPC (get_sales_order/get_returnable_sales_order/
-- get_sales_return/list_sales_returns), or done after `reset role;`
-- (superuser, bypasses RLS), exactly mirroring sales_integrity_patch_3_1.
-- test.sql's own established convention.
--
-- Safe to run against a real (including production-like staging) Supabase
-- database: everything happens inside a transaction that is ALWAYS rolled
-- back at the end, so no test data is left behind.
--
-- Requires migrations 0001-0098 + supabase/seed.sql to already be applied.
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/sales_returns_core.test.sql
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0. Setup — actors, stores, master data. Prefix 'd9...' / 'S4...' is not
-- used by any other test file (checked: s3/S3, d4/d6/d7/d8), so this file
-- can never collide even if chained into one transaction with the others.
--
--   01 = Returns Manager — full Sales + Returns permission set, plus every
--        master-data manage permission needed to build fixtures.
--   02 = Sales/Returns Employee — sales.create/view + returns.view/create
--        only (no approve/reverse/record_refund/process_closed_day).
--   03 = Profit-blind viewer — sales.view + returns.view, NOT
--        sales.view_profit — proves profit fields stay hidden everywhere.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('d9000000-0000-4000-8000-000000000001', 'test-s4-manager@example.invalid'),
  ('d9000000-0000-4000-8000-000000000002', 'test-s4-employee@example.invalid'),
  ('d9000000-0000-4000-8000-000000000003', 'test-s4-profitblind@example.invalid');

update public.profiles set full_name = 'Test Returns Manager', status = 'active', store_access_scope = 'all'
  where id = 'd9000000-0000-4000-8000-000000000001';
update public.profiles set full_name = 'Test Sales/Returns Employee', status = 'active', store_access_scope = 'all'
  where id = 'd9000000-0000-4000-8000-000000000002';
update public.profiles set full_name = 'Test Profit-Blind Viewer', status = 'active', store_access_scope = 'all'
  where id = 'd9000000-0000-4000-8000-000000000003';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'd9000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in (
    'stores.view', 'stores.create', 'stores.edit', 'stores.disable',
    'karats.view', 'karats.manage', 'categories.view', 'categories.manage',
    'collection_channels.view', 'collection_channels.manage',
    'payment_methods.view', 'payment_methods.manage',
    'gold_prices.view', 'gold_prices.edit',
    'manufacturing_fees.view', 'manufacturing_fees.manage',
    'sales.create', 'sales.edit', 'sales.view', 'sales.view_profit', 'sales.close_day',
    'returns.view', 'returns.create', 'returns.approve', 'returns.reverse',
    'returns.record_refund', 'returns.process_closed_day', 'audit_logs.view'
  );

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'd9000000-0000-4000-8000-000000000002', id, 'grant' from public.permissions
  where key in ('sales.create', 'sales.view', 'returns.view', 'returns.create', 'stores.view');

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'd9000000-0000-4000-8000-000000000003', id, 'grant' from public.permissions
  where key in ('sales.view', 'returns.view', 'stores.view', 'audit_logs.view');

set role authenticated;
set local request.jwt.claims = '{"sub":"d9000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_store_a uuid;
  v_store_b uuid;
  v_karat_id uuid;
  v_category_id uuid;
  v_channel_id uuid;
  v_payment_method_id uuid;
  v_payment_method_full uuid;
begin
  -- Store B is the "processed at a different branch than purchased" store —
  -- deliberately distinct from Store A (the Sale's own store).
  insert into public.stores (code, name_ar, status) values ('S4STA', 'متجر اختبار أ - مرتجعات', 'active') returning id into v_store_a;
  insert into public.stores (code, name_ar, status) values ('S4STB', 'متجر اختبار ب - مرتجعات', 'active') returning id into v_store_b;
  insert into public.karats (code, name_ar, sort_order, status) values ('S4K1', 'عيار اختبار 4', 994, 'active') returning id into v_karat_id;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('s4cat1', 'تصنيف اختبار 4', 994, 'active') returning id into v_category_id;
  insert into public.collection_channels (key, name_ar, sort_order, status) values ('s4_channel', 'قناة اختبار 4', 994, 'active') returning id into v_channel_id;
  -- 10% flat fee, refund_fee_policy='proportional_reversal' — the shared
  -- formula path used by most of this file.
  insert into public.payment_methods (key, name_ar, fee_model, refund_fee_policy, sort_order, status)
    values ('s4_pm', 'طريقة دفع اختبار 4', 'percentage', 'proportional_reversal', 994, 'active') returning id into v_payment_method_id;
  -- refund_fee_policy='full_reversal' — dedicated to scenario J (Section 8).
  insert into public.payment_methods (key, name_ar, fee_model, refund_fee_policy, sort_order, status)
    values ('s4_pm_full', 'طريقة دفع اختبار 4 (استرداد كامل)', 'percentage', 'full_reversal', 995, 'active') returning id into v_payment_method_full;

  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 300.0000, 'd9000000-0000-4000-8000-000000000001');

  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, public.business_today(), 's4 fixture');
  perform public.create_payment_method_fee_version(v_payment_method_id, 10, 0, public.business_today(), 's4 fixture');
  perform public.create_payment_method_fee_version(v_payment_method_full, 10, 0, public.business_today(), 's4 fixture full_reversal');
end $$;

-- ============================================================================
-- 1. Full single-item return — happy path, financial lock, order_state,
-- Section 1/12 business fields, Section 3 condition tracking
-- ============================================================================
do $$
declare
  v_store_a uuid; v_store_b uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid;
  v_order_id uuid; v_order_number text; v_item_id uuid;
  v_return_id uuid; v_return_number text; v_row_version bigint;
  v_preview jsonb;
  v_return jsonb;
  v_returnable jsonb;
  v_update_result record;
  v_items jsonb;
begin
  select id into v_store_a from public.stores where code = 'S4STA';
  select id into v_store_b from public.stores where code = 'S4STB';
  select id into v_karat_id from public.karats where code = 'S4K1';
  select id into v_category_id from public.product_categories where code = 's4cat1';
  select id into v_channel_id from public.collection_channels where key = 's4_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's4_pm';

  select id, order_number into v_order_id, v_order_number from public.create_sales_order(
    v_store_a, public.business_today(), v_payment_method_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 100.00))
  );

  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;
  v_items := jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id, 'condition', 'good_resellable', 'item_return_reason', 'عيب تصنيع'));

  -- Preview BEFORE creating — is_fee_reversal_estimate=true, sales_revenue_
  -- reversal_amount = 100.00, and since this is the order's only item,
  -- covers_all_remaining is true -> estimated fee reversal = full 10.00.
  -- Section 1: returned_original_sale_amount also computed at preview time.
  v_preview := public.preview_sales_return(
    v_order_id, v_items,
    p_collection_state := 'collected', p_approved_refund_amount := 100.00
  );
  assert v_preview ->> 'returned_original_sale_amount' = '100.00', format('1.0 قيمة البيع الأصلية المرتجعة (معاينة) يجب أن تكون 100.00، وجد %s', v_preview ->> 'returned_original_sale_amount');
  assert v_preview ->> 'sales_revenue_reversal_amount' = '100.00', format('1.1 مراجعة المرتجع: استرجاع الإيراد المتوقع يجب أن يكون 100.00، وجد %s', v_preview ->> 'sales_revenue_reversal_amount');
  assert v_preview ->> 'estimated_payment_fee_reversal_amount' = '10.00', format('1.1 استرداد العمولة المتوقع يجب أن يكون 10.00 (تغطية كاملة)، وجد %s', v_preview ->> 'estimated_payment_fee_reversal_amount');
  raise notice 'OK: 1.1 preview_sales_return() (توقيع jsonb الجديد) يحسب الحقول المالية الجديدة (Section 1/12) بشكل صحيح قبل الإنشاء';

  -- Processed at Store B — deliberately DIFFERENT from the Sale's own Store
  -- A, proving a return may be processed at a different branch.
  select id, return_number into v_return_id, v_return_number from public.create_sales_return(
    v_order_id, v_store_b, public.business_today(), 'defective_product', v_items,
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint,
    'collected', 100.00
  );
  assert v_return_number like 'RET-%', format('1.2 رقم المرتجع يجب أن يبدأ بـ RET-، وجد %s', v_return_number);
  raise notice 'OK: 1.2 create_sales_return() (توقيع jsonb + الحقول التجارية الجديدة) نجح، معالَج في متجر مختلف (S4STB) عن متجر البيع الأصلي (S4STA)';

  -- Patch 4.1 (Section 5) — returnable=TRUE remains while only a PENDING
  -- return (not yet an effective/approved claim) references this item; only
  -- an effective claim ever blocks it. order_state stays not_returned since
  -- no claim is effective yet.
  v_returnable := public.get_returnable_sales_order(v_order_id);
  assert (v_returnable -> 'items' -> 0 ->> 'returnable')::boolean = true, '1.3 البند يجب أن يبقى returnable=true أثناء وجود مرتجع PENDING فقط (لا مطالبة فعّالة بعد) — Section 5';
  assert v_returnable ->> 'order_state' = 'not_returned', format('1.3 order_state يجب أن يبقى not_returned قبل الاعتماد، وجد %s', v_returnable ->> 'order_state');
  raise notice 'OK: 1.3 get_returnable_sales_order() يسمح بالبند أثناء وجود مرتجع قيد المراجعة (لا مطالبة فعّالة بعد)، وorder_state يبقى not_returned قبل الاعتماد';

  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_id, v_row_version);

  v_return := public.get_sales_return(v_return_id);
  assert v_return ->> 'status' = 'approved', '1.4 حالة المرتجع بعد الاعتماد يجب أن تكون approved';
  assert v_return ->> 'sales_revenue_reversal_amount' = '100.00', format('1.4 استرجاع الإيراد يجب أن يكون 100.00، وجد %s', v_return ->> 'sales_revenue_reversal_amount');
  assert v_return ->> 'payment_fee_reversal_amount' = '10.00', format('1.4 استرداد العمولة (تغطية كاملة، إصدار نهائي) يجب أن يكون 10.00، وجد %s', v_return ->> 'payment_fee_reversal_amount');
  assert v_return ->> 'approved_refund_amount' = '100.00', '1.4 قيمة الاسترداد المعتمدة يجب أن تساوي استرجاع الإيراد';
  assert v_return ->> 'actual_refunded_total' = '0.00', '1.4 لا يوجد أي استرداد نقدي فعلي مسجَّل بعد';
  -- Scenario O — the full Section 12 field set, including
  -- adjusted_order_net_sales_profit, is present for a profit-visible actor.
  assert v_return ? 'adjusted_order_net_sales_profit', 'O.1 adjusted_order_net_sales_profit يجب أن يكون حاضرًا لمستخدم يملك sales.view_profit';
  assert v_return ? 'recovered_original_cost_amount', 'O.2 recovered_original_cost_amount يجب أن يكون حاضرًا لمستخدم يملك sales.view_profit';
  raise notice 'OK: 1.4/O.1/O.2 approve_sales_return() يحسب الأرقام المالية النهائية بما فيها مجموعة حقول Section 12 الكاملة';

  -- Scenario N — item condition is tracked and returned, historical-only
  -- (no Inventory table exists yet in this codebase — Inventory phase has
  -- not started per the user's explicit instruction — so there is nothing
  -- for this RPC to touch there; this assertion instead proves the
  -- condition value round-trips through create -> approve -> read).
  v_items := v_return -> 'items';
  assert v_items -> 0 ->> 'condition' = 'good_resellable', format('N.1 حالة القطعة المرتجعة يجب أن تُحفظ وتُعرض (good_resellable)، وجد %s', v_items -> 0 ->> 'condition');
  assert v_items -> 0 ->> 'item_return_reason' = 'عيب تصنيع', 'N.2 سبب إرجاع البند يجب أن يُحفظ ويُعرض';
  raise notice 'OK: N.1/N.2 تتبع حالة القطعة المرتجعة (Section 3) — تاريخي فقط، دون أي حركة مخزون (لم تبدأ مرحلة Inventory)';

  v_returnable := public.get_returnable_sales_order(v_order_id);
  assert v_returnable ->> 'order_state' = 'full', format('1.5 order_state يجب أن يصبح full بعد اعتماد مرتجع يغطي كل البنود، وجد %s', v_returnable ->> 'order_state');
  raise notice 'OK: 1.5 order_state = full، مشتق مباشرة من is_effective، غير مخزَّن';

  -- Financial lock: metadata-only edit still succeeds...
  select * into v_update_result from public.update_sales_order(
    v_order_id, v_payment_method_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('id', v_item_id, 'category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 100.00)),
    'اسم عميل معدَّل', null, null, null,
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint
  );
  assert v_update_result.id = v_order_id, '1.6 التعديل الوصفي فقط (اسم العميل) يجب أن ينجح رغم وجود مرتجع معتمد';
  raise notice 'OK: 1.6 update_sales_order() يسمح بتعديل البيانات الوصفية رغم القفل المالي';

  -- ...but a financial edit (sale_price change) is rejected outright.
  begin
    perform public.update_sales_order(
      v_order_id, v_payment_method_id, v_channel_id,
      jsonb_build_array(jsonb_build_object('id', v_item_id, 'category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 999.00)),
      null, null, null, null,
      (public.get_sales_order(v_order_id) ->> 'row_version')::bigint
    );
    raise exception 'BUG: 1.7 قُبل تعديل مالي على عملية بيع عليها مرتجع معتمد';
  exception when others then
    if sqlerrm like 'BUG:%' then raise; end if;
    assert sqlerrm like '%مرتجع معتمد%', format('1.7 رسالة الخطأ يجب أن تذكر وجود مرتجع معتمد، وجدت: %s', sqlerrm);
    raise notice 'OK: 1.7 update_sales_order() يرفض أي تعديل مالي طالما يوجد مرتجع فعّال (is_effective=true) عليه (%)', sqlerrm;
  end;
end $$;

-- ============================================================================
-- 2. Scenario A/B — pending-membership vs effective-claim (Section 5):
-- multiple PENDING returns coexist on one item, but only one ever becomes
-- the effective (approved) claim; approving the second is rejected.
-- ============================================================================
do $$
declare
  v_store_a uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid;
  v_order_id uuid; v_item_id uuid;
  v_return_1 uuid; v_return_2 uuid; v_row_version bigint;
  v_returnable jsonb;
  v_bug boolean := false;
begin
  select id into v_store_a from public.stores where code = 'S4STA';
  select id into v_karat_id from public.karats where code = 'S4K1';
  select id into v_category_id from public.product_categories where code = 's4cat1';
  select id into v_channel_id from public.collection_channels where key = 's4_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's4_pm';

  select id into v_order_id from public.create_sales_order(
    v_store_a, public.business_today(), v_payment_method_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 150.00))
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  -- Scenario A — a SECOND pending return on the SAME item is accepted; the
  -- old sales_return_items_order_item_active_uq (pre-Patch-4.1) would have
  -- rejected this outright. Only PENDING membership, not the exclusive
  -- financial claim.
  select id into v_return_1 from public.create_sales_return(
    v_order_id, v_store_a, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id, 'condition', 'damaged')),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 150.00
  );
  select id into v_return_2 from public.create_sales_return(
    v_order_id, v_store_a, public.business_today(), 'customer_changed_mind',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id, 'condition', 'good_resellable')),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 150.00
  );
  raise notice 'OK: A.1 مرتجع ثانٍ قيد المراجعة على نفس البند قُبل — التزامن العضوي (pending membership) لا يمنع أكثر من مرتجع معلَّق واحد';

  v_returnable := public.get_returnable_sales_order(v_order_id);
  assert (v_returnable -> 'items' -> 0 ->> 'returnable')::boolean = true, 'A.2 البند يجب أن يبقى returnable=true بوجود مرتجعات معلَّقة فقط (لا مطالبة فعّالة بعد)';
  raise notice 'OK: A.2 returnable=true أثناء وجود مرتجعات PENDING متعددة، طالما لا توجد مطالبة فعّالة (is_effective) بعد';

  -- Scenario B — approve the FIRST return; it becomes the sole effective
  -- claim (real unique-index-backed constraint: sales_return_items_
  -- effective_claim_uq). Approving the SECOND is rejected by the friendly
  -- pre-check.
  select (public.get_sales_return(v_return_1) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_1, v_row_version);

  select (public.get_sales_return(v_return_2) ->> 'row_version')::bigint into v_row_version;
  begin
    perform public.approve_sales_return(v_return_2, v_row_version);
    v_bug := true;
  exception when others then
    assert sqlerrm like '%هذه القطعة مرتجعة بالفعل%', format('B.1 رسالة رفض الاعتماد الثاني يجب أن تذكر أن القطعة مرتجعة بالفعل، وجدت: %s', sqlerrm);
    raise notice 'OK: B.1 اعتماد المرتجع الثاني على نفس البند بعد اعتماد الأول رُفض بفحص أولي واضح (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: B.1 قُبل اعتماد مرتجع ثانٍ فعّال على بند له مطالبة فعّالة موجودة بالفعل'; end if;

  v_returnable := public.get_returnable_sales_order(v_order_id);
  assert (v_returnable -> 'items' -> 0 ->> 'returnable')::boolean = false, 'B.2 البند يجب أن يصبح غير قابل للإرجاع بمجرد وجود مطالبة فعّالة (is_effective=true) واحدة عليه';
  raise notice 'OK: B.2 مطالبة فعّالة واحدة فقط ممكنة لكل بند، مدعومة بفهرس فريد جزئي حقيقي (sales_return_items_effective_claim_uq)';
end $$;

-- ============================================================================
-- 3. Cumulative payment-fee-reversal capping + final-allocation rounding
-- absorption — three items (333.33 / 333.33 / 333.34, subtotal 1000.00,
-- 10% fee = 100.00 exactly), approved ONE AT A TIME.
--
-- Hotfix 4.2.1 (Sections 7-9/14-B, migration 0109) — approve_sales_return()
-- now computes payment_fee_reversal_amount via compute_sales_return_fee_
-- reversal_v2(), on the CUMULATIVE approved_refund_amount basis across the
-- order's approved returns, not any single return's own item value (v1,
-- still used only to interpret pre-Hotfix-4.2.1 historical rows). This
-- fixture has no deduction/refund-difference on any of the three returns
-- (each return's approved_refund_amount equals its own item's sale_price),
-- so the CUMULATIVE basis after each approval is identical to the
-- cumulative revenue in either engine — but the per-step ALLOCATION differs
-- from the old v1 test's values, because v2 derives each step from the
-- cumulative TARGET fee (rounded once per step), not from an independent
-- per-return proportional share:
--   step 1 (basis=333.33):            target=round(100*333.33/1000,2)=33.33 -> delta=33.33
--   step 2 (basis=666.66, prev=33.33): target=round(100*666.66/1000,2)=66.67 -> delta=33.34
--   step 3 (basis=1000.00>=1000, prev=66.67): target=100.00 (full, no proportional residue) -> delta=33.33
-- Sum is still exactly 100.00 (the invariant this test exists to prove), it
-- is simply item B, not item C, that absorbs the extra cent this time —
-- this IS Hotfix 4.2.1's Section 14-B mandated regression scenario B.
-- ============================================================================
do $$
declare
  v_store_a uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid;
  v_order_id uuid;
  v_item_a uuid; v_item_b uuid; v_item_c uuid;
  v_return_a uuid; v_return_b uuid; v_return_c uuid;
  v_row_version bigint;
  v_order jsonb;
  v_return jsonb;
  v_returnable jsonb;
  v_cumulative numeric;
  v_elem jsonb;
begin
  select id into v_store_a from public.stores where code = 'S4STA';
  select id into v_karat_id from public.karats where code = 'S4K1';
  select id into v_category_id from public.product_categories where code = 's4cat1';
  select id into v_channel_id from public.collection_channels where key = 's4_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's4_pm';

  select id into v_order_id from public.create_sales_order(
    v_store_a, public.business_today(), v_payment_method_id, v_channel_id,
    jsonb_build_array(
      jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 333.33),
      jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 333.33),
      jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 333.34)
    )
  );

  v_order := public.get_sales_order(v_order_id);
  assert v_order ->> 'payment_fee_amount' = '100.00',
    format('3.0 عمولة الدفع لهذه العملية يجب أن تكون 100.00 بالضبط (شرط أساسي لهذا الاختبار)، وجدت %s', v_order ->> 'payment_fee_amount');

  for v_elem in select * from jsonb_array_elements(v_order -> 'items')
  loop
    if v_elem ->> 'sale_price' = '333.34' then
      v_item_c := (v_elem ->> 'id')::uuid;
    elsif v_item_a is null then
      v_item_a := (v_elem ->> 'id')::uuid;
    else
      v_item_b := (v_elem ->> 'id')::uuid;
    end if;
  end loop;

  select id into v_return_a from public.create_sales_return(
    v_order_id, v_store_a, public.business_today(), 'wrong_item_delivered',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_a)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 333.33
  );
  select (public.get_sales_return(v_return_a) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_a, v_row_version);
  v_return := public.get_sales_return(v_return_a);
  assert v_return ->> 'payment_fee_reversal_amount' = '33.33', format('3.1 استرداد عمولة البند A (تناسبي، غير نهائي) يجب أن يكون 33.33، وجد %s', v_return ->> 'payment_fee_reversal_amount');
  raise notice 'OK: 3.1 استرداد العمولة التناسبي للبند الأول = 33.33';

  v_returnable := public.get_returnable_sales_order(v_order_id);
  assert v_returnable ->> 'order_state' = 'partial', format('3.2 order_state يجب أن يكون partial بعد إرجاع بند واحد من ثلاثة، وجد %s', v_returnable ->> 'order_state');
  raise notice 'OK: 3.2 order_state = partial بعد اعتماد مرتجع البند الأول فقط';

  select id into v_return_b from public.create_sales_return(
    v_order_id, v_store_a, public.business_today(), 'wrong_item_delivered',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_b)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 333.33
  );
  select (public.get_sales_return(v_return_b) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_b, v_row_version);
  v_return := public.get_sales_return(v_return_b);
  -- Hotfix 4.2.1 (v2 engine): cumulative basis after B = 666.66, target
  -- cumulative fee = round(100*666.66/1000, 2) = 66.67, delta vs the 33.33
  -- already reversed by A = 33.34 (NOT the naive independent-proportional
  -- 33.33 the old v1-per-return formula gave B).
  assert v_return ->> 'payment_fee_reversal_amount' = '33.34', format('3.3 استرداد عمولة البند B (أساس تراكمي v2) يجب أن يكون 33.34، وجد %s', v_return ->> 'payment_fee_reversal_amount');
  raise notice 'OK: 3.3 استرداد العمولة التراكمي للبند الثاني = 33.34 (الهدف التراكمي 66.67 ناقص 33.33 المسترد سابقًا)';

  select id into v_return_c from public.create_sales_return(
    v_order_id, v_store_a, public.business_today(), 'wrong_item_delivered',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_c)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 333.34
  );
  select (public.get_sales_return(v_return_c) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_c, v_row_version);
  v_return := public.get_sales_return(v_return_c);
  -- THE key assertion: this is the allocation that completes the full cash
  -- basis (cumulative approved_refund_amount reaches the order subtotal,
  -- 1000.00), so v2 gives it the FULL remaining original fee (100.00 -
  -- 66.67 = 33.33) directly, rather than trusting one more proportional
  -- division to land there exactly.
  assert v_return ->> 'payment_fee_reversal_amount' = '33.33', format('3.4 استرداد عمولة البند الأخير (اكتمال الأساس التراكمي) يجب أن يكون 33.33، وجد %s', v_return ->> 'payment_fee_reversal_amount');
  raise notice 'OK: 3.4 الإصدار الأخير أغلق الأساس التراكمي عند 1000.00 فحصل على كامل العمولة المتبقية (33.33) دون قسمة تناسبية إضافية';

  select coalesce(sum(payment_fee_reversal_amount::numeric), 0) into v_cumulative
  from public.list_sales_returns(p_sales_order_id := v_order_id, p_status := 'approved', p_limit := 200);
  assert v_cumulative = 100.00, format('3.5 مجموع استرداد العمولة التراكمي عبر كل المرتجعات المعتمدة على هذه العملية يجب أن يساوي 100.00 بالضبط (عمولة العملية الأصلية)، وجد %s', v_cumulative);
  raise notice 'OK: 3.5 مجموع استرداد العمولة التراكمي (33.33+33.33+33.34) = 100.00 بالضبط — لا فارق تقريب متبقٍّ';

  v_returnable := public.get_returnable_sales_order(v_order_id);
  assert v_returnable ->> 'order_state' = 'full', format('3.6 order_state يجب أن يصبح full بعد تغطية كل البنود الثلاثة، وجد %s', v_returnable ->> 'order_state');
  raise notice 'OK: 3.6 order_state = full بعد اعتماد مرتجعات تغطي كل بنود العملية عبر مرتجعات منفصلة متعددة';
end $$;

-- ============================================================================
-- 4. Scenario C — reject preserves item history (Section 6): a rejected
-- return NEVER reads back as having zero items, and no financial column is
-- ever written.
-- ============================================================================
do $$
declare
  v_store_a uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid;
  v_order_id uuid; v_item_id uuid; v_return_id uuid; v_row_version bigint;
  v_return jsonb; v_returnable jsonb;
begin
  select id into v_store_a from public.stores where code = 'S4STA';
  select id into v_karat_id from public.karats where code = 'S4K1';
  select id into v_category_id from public.product_categories where code = 's4cat1';
  select id into v_channel_id from public.collection_channels where key = 's4_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's4_pm';

  select id into v_order_id from public.create_sales_order(
    v_store_a, public.business_today(), v_payment_method_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 50.00))
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_a, public.business_today(), 'other',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 50.00,
    p_scenario_notes := 'العميل أعاد رأيه بعد أسبوعين'
  );
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.reject_sales_return(v_return_id, v_row_version, 'لا يوجد عيب فعلي في المنتج بعد الفحص');

  v_return := public.get_sales_return(v_return_id);
  assert v_return ->> 'status' = 'rejected', '4.1 حالة المرتجع بعد الرفض يجب أن تكون rejected';
  assert v_return ->> 'sales_revenue_reversal_amount' is null, '4.1 لا يجب حساب أي رقم مالي لمرتجع مرفوض أبدًا';
  raise notice 'OK: 4.1 reject_sales_return() لا يكتب أي عمود مالي أبدًا';

  -- Scenario C — the item still shows on the rejected return's own detail,
  -- never a phantom item_count=0 (included_in_decision=true, set at the
  -- moment of rejection, is permanent and independent of later edits).
  assert jsonb_array_length(v_return -> 'items') = 1, format('C.1 المرتجع المرفوض يجب أن يُظهر بنده دائمًا (لا يصبح item_count=0 أبدًا)، وجد %s بند', jsonb_array_length(v_return -> 'items'));
  raise notice 'OK: C.1 رفض المرتجع يحفظ تاريخ البند (included_in_decision=true) — لا يظهر المرتجع المرفوض فارغًا أبدًا';

  v_returnable := public.get_returnable_sales_order(v_order_id);
  assert (v_returnable -> 'items' -> 0 ->> 'returnable')::boolean = true, '4.2 البند يجب أن يصبح قابلاً للإرجاع مجددًا فور رفض المرتجع';
  raise notice 'OK: 4.2 رفض المرتجع يحرر البند فورًا (لا مطالبة فعّالة أُنشئت أصلاً لمرتجع مرفوض)';

  -- Proves it can genuinely be claimed again (not just flagged returnable).
  perform public.create_sales_return(
    v_order_id, v_store_a, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 50.00
  );
  raise notice 'OK: 4.3 يمكن فعليًا فتح مرتجع جديد على نفس البند بعد رفض المرتجع الأول';
end $$;

-- ============================================================================
-- 5. Scenario D — reverse preserves item history (Section 6), releases the
-- effective claim, and lifts the Sale's financial lock
-- ============================================================================
do $$
declare
  v_order_id uuid; v_return_id uuid; v_row_version bigint;
  v_return jsonb; v_returnable jsonb; v_order jsonb;
  v_update_result record;
  v_item_id uuid; v_category_id uuid; v_karat_id uuid; v_channel_id uuid; v_payment_method_id uuid;
begin
  -- Reuse the fully-returned single-item order from section 1 (the one
  -- return whose payment_fee_reversal_amount is exactly 10.00).
  select sales_order_id into v_order_id from public.list_sales_returns(p_status := 'approved', p_limit := 200)
  where payment_fee_reversal_amount = '10.00' limit 1;
  select id into v_return_id from public.list_sales_returns(p_sales_order_id := v_order_id, p_status := 'approved', p_limit := 1);

  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.reverse_sales_return(v_return_id, v_row_version, 'العميل أعاد المنتج مرة أخرى واسترد ثمنه نقدًا يدويًا خارج النظام عن طريق الخطأ');

  v_return := public.get_sales_return(v_return_id);
  assert v_return ->> 'status' = 'reversed', '5.1 حالة المرتجع بعد التراجع يجب أن تكون reversed';
  assert v_return ->> 'sales_revenue_reversal_amount' = '100.00', '5.1 الأرقام المالية المحسوبة عند الاعتماد يجب أن تبقى محفوظة بعد التراجع (لا تُمحى)';
  raise notice 'OK: 5.1 reverse_sales_return() يبقي الأرقام التاريخية محفوظة، ويغيّر فقط status/reversed_at/reversed_by/reversal_reason/is_effective';

  -- Scenario D — the item still shows on the reversed return's own detail.
  assert jsonb_array_length(v_return -> 'items') = 1, format('D.1 المرتجع المتراجَع عنه يجب أن يُظهر بنده دائمًا، وجد %s بند', jsonb_array_length(v_return -> 'items'));
  raise notice 'OK: D.1 التراجع يحفظ تاريخ البند (included_in_decision يبقى true من لحظة الاعتماد، لا يُعاد ضبطه)';

  v_returnable := public.get_returnable_sales_order(v_order_id);
  assert (v_returnable -> 'items' -> 0 ->> 'returnable')::boolean = true, '5.2 البند يجب أن يصبح قابلاً للإرجاع مجددًا بعد التراجع عن المرتجع المعتمد';
  assert v_returnable ->> 'order_state' = 'not_returned', format('5.2 order_state يجب أن يعود not_returned بعد التراجع عن المرتجع الوحيد المعتمد، وجد %s', v_returnable ->> 'order_state');
  raise notice 'OK: 5.2 order_state وreturnable يعودان لحالتهما الأصلية بعد التراجع (is_effective=false)';

  v_order := public.get_sales_order(v_order_id);
  v_item_id := (v_order -> 'items' -> 0 ->> 'id')::uuid;
  v_category_id := (v_order -> 'items' -> 0 ->> 'category_id')::uuid;
  v_karat_id := (v_order -> 'items' -> 0 ->> 'karat_id')::uuid;
  v_payment_method_id := (v_order ->> 'payment_method_id')::uuid;
  v_channel_id := (v_order ->> 'collection_channel_id')::uuid;

  -- Financial lock lifts — a real financial edit now succeeds again.
  select * into v_update_result from public.update_sales_order(
    v_order_id, v_payment_method_id, v_channel_id,
    jsonb_build_array(jsonb_build_object(
      'id', v_item_id, 'category_id', v_category_id, 'karat_id', v_karat_id,
      'weight_grams', 0.1000, 'sale_price', 120.00
    )),
    null, null, null, null,
    (v_order ->> 'row_version')::bigint
  );
  assert v_update_result.id = v_order_id, '5.3 التعديل المالي يجب أن ينجح بعد التراجع عن المرتجع المعتمد الوحيد (لا مرتجع فعّال متبقٍّ)';
  raise notice 'OK: 5.3 القفل المالي على عملية البيع يُرفَع تلقائيًا بمجرد عدم وجود أي مرتجع فعّال (is_effective) متبقٍّ عليها';
end $$;

-- ============================================================================
-- 6. Actual-cash-refund ledger — append-only, variance, soft-void reversal,
-- blocked outside 'approved'; Scenario E — money-scale rejection (Section
-- 10); Scenario K — finalize_sales_return_refund() (Section 11)
-- ============================================================================
do $$
declare
  v_store_a uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid;
  v_order_id uuid; v_item_id uuid; v_return_id uuid; v_row_version bigint;
  v_event1 record; v_event2 record;
  v_return jsonb;
  v_bug boolean := false;
begin
  select id into v_store_a from public.stores where code = 'S4STA';
  select id into v_karat_id from public.karats where code = 'S4K1';
  select id into v_category_id from public.product_categories where code = 's4cat1';
  select id into v_channel_id from public.collection_channels where key = 's4_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's4_pm';

  select id into v_order_id from public.create_sales_order(
    v_store_a, public.business_today(), v_payment_method_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 200.00))
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;
  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_a, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 200.00
  );

  -- 6.1 Blocked while still 'pending' (nothing approved to refund against).
  begin
    perform public.record_sales_return_refund(v_return_id, 200.00, v_payment_method_id);
    v_bug := true;
  exception when others then
    assert sqlerrm like '%معتمد%', format('6.1 رسالة الرفض يجب أن تذكر أن المرتجع غير معتمد، وجدت: %s', sqlerrm);
    raise notice 'OK: 6.1 تسجيل استرداد نقدي على مرتجع لم يُعتمد بعد رُفض (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: 6.1 قُبل تسجيل استرداد نقدي على مرتجع قيد المراجعة'; end if;

  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_id, v_row_version);

  -- Scenario E — a refund amount with more than 2 decimal places is
  -- REJECTED outright, never silently rounded by the numeric(14,2) column.
  begin
    perform public.record_sales_return_refund(v_return_id, 100.005, v_payment_method_id);
    v_bug := true;
  exception when others then
    assert sqlerrm like '%رقمين عشريين%' or sqlerrm like '%عشري%' or sqlerrm like '%decimal%', format('E.1 رسالة الرفض يجب أن تذكر تجاوز الحد الأقصى للمنازل العشرية، وجدت: %s', sqlerrm);
    raise notice 'OK: E.1 قيمة استرداد بأكثر من منزلتين عشريتين (100.005) رُفضت صراحةً (%) — لم تُقرَّب بصمت', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: E.1 قُبلت قيمة استرداد بأكثر من منزلتين عشريتين دون رفض'; end if;

  select * into v_event1 from public.record_sales_return_refund(v_return_id, 120.00, v_payment_method_id, p_notes := 'دفعة أولى نقدًا');
  select * into v_event2 from public.record_sales_return_refund(v_return_id, 80.00, v_payment_method_id, p_notes := 'دفعة ثانية نقدًا');

  v_return := public.get_sales_return(v_return_id);
  assert v_return ->> 'actual_refunded_total' = '200.00', format('6.2 مجموع الاسترداد الفعلي يجب أن يكون 200.00 بعد دفعتين (120+80)، وجد %s', v_return ->> 'actual_refunded_total');
  assert v_return ->> 'refund_variance' = '0.00', format('6.2 الفارق بين المستهدف والفعلي يجب أن يكون 0.00 عندما يتطابقان، وجد %s', v_return ->> 'refund_variance');
  assert v_return ->> 'refund_reconciliation_state' = 'pending', format('6.2 حالة التسوية قبل finalize يجب أن تكون pending، وجدت %s', v_return ->> 'refund_reconciliation_state');
  raise notice 'OK: 6.2 سجل الاسترداد الفعلي (append-only) يجمع كل الدفعات النشطة بشكل صحيح، والفارق = 0 عند التطابق، وحالة التسوية pending';

  perform public.reverse_sales_return_refund_event(v_event2.id, 'تسجيل مكرر بالخطأ');

  v_return := public.get_sales_return(v_return_id);
  assert v_return ->> 'actual_refunded_total' = '120.00', format('6.3 مجموع الاسترداد الفعلي يجب أن يعود إلى 120.00 بعد التراجع عن الدفعة الثانية، وجد %s', v_return ->> 'actual_refunded_total');
  assert v_return ->> 'refund_variance' = '80.00', format('6.3 الفارق يجب أن يظهر 80.00 المتبقية غير المسترجعة فعليًا، وجد %s', v_return ->> 'refund_variance');
  raise notice 'OK: 6.3 التراجع عن سجل استرداد (soft-void) يستثنيه من المجموع الفعلي دون حذفه، ويعيد إظهار الفارق';

  -- 6.4 A NEW event can still be recorded (return is still 'approved',
  -- only the one event was voided).
  perform public.record_sales_return_refund(v_return_id, 80.00, v_payment_method_id, p_notes := 'تصحيح الدفعة');
  v_return := public.get_sales_return(v_return_id);
  assert v_return ->> 'actual_refunded_total' = '200.00', '6.4 يمكن تسجيل دفعة استرداد جديدة بعد التراجع عن دفعة سابقة طالما المرتجع لا يزال معتمدًا';
  raise notice 'OK: 6.4 تسجيل استرداد جديد بعد تصحيح دفعة سابقة يعمل بشكل صحيح';

  -- Scenario K (part 1) — finalize with an exact match requires no variance
  -- reason and reaches 'finalized_matched'.
  perform public.finalize_sales_return_refund(v_return_id, (public.get_sales_return(v_return_id) ->> 'row_version')::bigint);
  v_return := public.get_sales_return(v_return_id);
  assert v_return ->> 'refund_reconciliation_state' = 'finalized_matched', format('K.1 حالة التسوية بعد finalize بدون فارق يجب أن تكون finalized_matched، وجدت %s', v_return ->> 'refund_reconciliation_state');
  assert v_return -> 'refund_finalized_at' is not null, 'K.1 refund_finalized_at يجب أن يُملأ عند التسوية';
  raise notice 'OK: K.1 finalize_sales_return_refund() يصل بحالة مطابقة تمامًا إلى finalized_matched دون سبب فارق';

  -- Finalizing again is rejected — reusable once per lifecycle event.
  begin
    perform public.finalize_sales_return_refund(v_return_id, (public.get_sales_return(v_return_id) ->> 'row_version')::bigint);
    v_bug := true;
  exception when others then
    raise notice 'OK: K.2 محاولة تسوية مرتجع مُسوًّى بالفعل رُفضت (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: K.2 قُبلت إعادة تسوية مرتجع مُسوًّى بالفعل'; end if;
end $$;

-- ============================================================================
-- 7. Scenario F/G — customer_never_received business-field correctness
-- (Section 2), and 'other' still requires non-empty notes
-- ============================================================================
do $$
declare
  v_store_a uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid;
  v_order_id uuid; v_item_id uuid; v_return_id uuid; v_row_version bigint;
  v_return jsonb;
  v_bug boolean := false;
begin
  select id into v_store_a from public.stores where code = 'S4STA';
  select id into v_karat_id from public.karats where code = 'S4K1';
  select id into v_category_id from public.product_categories where code = 's4cat1';
  select id into v_channel_id from public.collection_channels where key = 's4_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's4_pm';

  select id into v_order_id from public.create_sales_order(
    v_store_a, public.business_today(), v_payment_method_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 75.00))
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  -- Scenario G — customer_never_received + not_collected + a NONZERO
  -- refund amount is hard-rejected by the CHECK constraint (migration
  -- 0092): this exact combination forces approved_refund_amount to be
  -- exactly 0 (the customer never paid anything collectible), no exception.
  begin
    perform public.create_sales_return(
      v_order_id, v_store_a, public.business_today(), 'customer_never_received',
      jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
      (public.get_sales_order(v_order_id) ->> 'row_version')::bigint,
      'not_collected', 40.00
    );
    v_bug := true;
  exception when others then
    assert sqlerrm like '%صفرًا%' or sqlerrm like '%صفر%', format('G.1 رسالة الرفض يجب أن تذكر ضرورة أن يكون الاسترداد صفرًا، وجدت: %s', sqlerrm);
    raise notice 'OK: G.1 عميل لم يستلم البضاعة + لم يتم التحصيل + استرداد غير صفري (40.00) رُفض بقيد قاعدة بيانات صريح (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: G.1 قُبل استرداد غير صفري لسيناريو customer_never_received/not_collected'; end if;

  -- Scenario F — approved_refund_amount=0 is accepted, while
  -- sales_revenue_reversal_amount still reverses the full original amount
  -- (75.00) once approved (Section 2's actual fix).
  -- approved_refund_amount=0 still differs from the speculative revenue
  -- reversal (75.00), so a refund_difference_reason is required here too —
  -- this is the general Section 1 variance rule, independent of Section 2.
  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_a, public.business_today(), 'customer_never_received',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint,
    'not_collected', 0.00,
    p_refund_difference_reason := 'لم يتم تحصيل المبلغ من العميل أصلاً — العميل لم يستلم البضاعة'
  );
  v_return := public.get_sales_return(v_return_id);
  assert v_return ->> 'scenario' = 'customer_never_received', '7.1 customer_never_received يجب أن يُخزَّن كسيناريو أول-درجة (enum)، لا كملاحظة';
  raise notice 'OK: 7.1 customer_never_received مخزَّن كقيمة enum أول-درجة في scenario';

  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_id, v_row_version);
  v_return := public.get_sales_return(v_return_id);
  assert v_return ->> 'approved_refund_amount' = '0.00', format('F.1 approved_refund_amount يجب أن يكون 0.00 (لم يُحصَّل المبلغ من العميل أصلاً)، وجد %s', v_return ->> 'approved_refund_amount');
  assert v_return ->> 'sales_revenue_reversal_amount' = '75.00', format('F.2 استرجاع الإيراد يجب أن يبقى 75.00 كاملاً بغض النظر عن approved_refund_amount=0، وجد %s', v_return ->> 'sales_revenue_reversal_amount');
  raise notice 'OK: F.1/F.2 approved_refund_amount=0 مقبول بشكل صحيح بينما استرجاع الإيراد/الربح يعكس بالكامل (Section 2)';

  -- Scenario K (part 2) — the zero-refund return can be finalized straight
  -- to 'finalized_matched' with ZERO refund events ever created.
  perform public.finalize_sales_return_refund(v_return_id, (public.get_sales_return(v_return_id) ->> 'row_version')::bigint);
  v_return := public.get_sales_return(v_return_id);
  assert v_return ->> 'refund_reconciliation_state' = 'finalized_matched', format('K.3 مرتجع باسترداد معتمد صفري يجب أن يصل finalized_matched دون أي سجل استرداد فعلي، وجدت %s', v_return ->> 'refund_reconciliation_state');
  assert jsonb_array_length(v_return -> 'refund_events') = 0, 'K.3 لا يوجد أي سجل استرداد فعلي (refund event) لهذا المرتجع، ومع ذلك وصل لحالة تسوية نهائية';
  raise notice 'OK: K.3 مرتجع approved_refund_amount=0 يصل لحالة تسوية نهائية دون أي سجل استرداد وهمي';

  -- 'other' still requires non-empty notes.
  begin
    perform public.create_sales_return(
      v_order_id, v_store_a, public.business_today(), 'other',
      jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
      (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 75.00
    );
    v_bug := true;
  exception when others then
    assert sqlerrm like '%ملاحظات%', format('7.2 رسالة الرفض يجب أن تذكر ضرورة إدخال ملاحظات، وجدت: %s', sqlerrm);
    raise notice 'OK: 7.2 سيناريو "other" بدون scenario_notes رُفض (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: 7.2 قُبل سيناريو other بدون ملاحظات'; end if;
end $$;

-- ============================================================================
-- 8. Closed-day gating — reuses Sales' own daily_closings/lock helpers
-- ============================================================================
do $$
declare
  v_store_a uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid;
  v_order_id uuid; v_item_id uuid;
  v_bug boolean := false;
begin
  select id into v_store_a from public.stores where code = 'S4STA';
  select id into v_karat_id from public.karats where code = 'S4K1';
  select id into v_category_id from public.product_categories where code = 's4cat1';
  select id into v_channel_id from public.collection_channels where key = 's4_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's4_pm';

  select id into v_order_id from public.create_sales_order(
    v_store_a, public.business_today(), v_payment_method_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 60.00))
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  perform public.close_sales_day(v_store_a, public.business_today(), 's4 test close');

  begin
    perform public.create_sales_return(
      v_order_id, v_store_a, public.business_today(), 'defective_product',
      jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
      (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 60.00
    );
    v_bug := true;
  exception when others then
    assert sqlerrm like '%مقفل%', format('8.1 رسالة الرفض يجب أن تذكر أن اليوم مقفل، وجدت: %s', sqlerrm);
    raise notice 'OK: 8.1 معالجة مرتجع في يوم مقفل بدون صلاحية/سبب رُفضت (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: 8.1 قُبلت معالجة مرتجع في يوم مقفل بدون صلاحية returns.process_closed_day'; end if;

  -- Actor 01 holds returns.process_closed_day + supplies a reason -> succeeds.
  perform public.create_sales_return(
    v_order_id, v_store_a, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 60.00,
    p_closed_day_reason := 'موافقة المدير على معالجة مرتجع في يوم مقفل لتصحيح خطأ فوري'
  );
  raise notice 'OK: 8.2 معالجة مرتجع في يوم مقفل نجحت مع صلاحية returns.process_closed_day وسبب صريح';
end $$;

-- ============================================================================
-- 9. Snapshot-only calculation (pending edits still allowed); Scenario H —
-- return_date >= sale_date (Section 7); Scenario I — stale Sale snapshot
-- rejected at approval + refresh_pending_sales_return_from_sale() (Section 4)
-- ============================================================================
do $$
declare
  v_store_a uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid;
  v_order_id uuid; v_item_id uuid; v_return_id uuid; v_row_version bigint;
  v_order jsonb; v_return jsonb;
  v_bug boolean := false;
begin
  -- Store B (never closed in this test run — section 8 closed Store A's
  -- day) so this section's Sale creation is unaffected by that.
  select id into v_store_a from public.stores where code = 'S4STB';
  select id into v_karat_id from public.karats where code = 'S4K1';
  select id into v_category_id from public.product_categories where code = 's4cat1';
  select id into v_channel_id from public.collection_channels where key = 's4_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's4_pm';

  select id into v_order_id from public.create_sales_order(
    v_store_a, public.business_today(), v_payment_method_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 90.00))
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  -- Scenario H — return_date before sale_date is rejected outright.
  begin
    perform public.create_sales_return(
      v_order_id, v_store_a, public.business_today() - 1, 'defective_product',
      jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
      (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 90.00
    );
    v_bug := true;
  exception when others then
    assert sqlerrm like '%تاريخ%', format('H.1 رسالة الرفض يجب أن تذكر مشكلة التاريخ، وجدت: %s', sqlerrm);
    raise notice 'OK: H.1 تاريخ مرتجع قبل تاريخ عملية البيع رُفض (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: H.1 قُبل تاريخ مرتجع قبل تاريخ عملية البيع'; end if;

  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_a, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 90.00
  );

  -- Sale is still editable (return is only 'pending') — financially edit
  -- the VERY item the pending return already snapshotted, making the
  -- return's snapshot stale.
  v_order := public.get_sales_order(v_order_id);
  perform public.update_sales_order(
    v_order_id, (v_order ->> 'payment_method_id')::uuid, v_channel_id,
    jsonb_build_array(jsonb_build_object('id', v_item_id, 'category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 500.00)),
    null, null, null, null,
    (v_order ->> 'row_version')::bigint
  );
  v_order := public.get_sales_order(v_order_id);
  assert v_order -> 'items' -> 0 ->> 'sale_price' = '500.00', '9.0 السعر الفعلي للبند يجب أن يصبح 500.00 بعد التعديل (شرط أساسي)';

  -- Scenario I — approval is rejected because source_sale_row_version no
  -- longer matches the Sale's current row_version.
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  begin
    perform public.approve_sales_return(v_return_id, v_row_version);
    v_bug := true;
  exception when others then
    assert sqlerrm like '%تم تعديل عملية البيع بعد إنشاء طلب المرتجع%', format('I.1 رسالة رفض الاعتماد يجب أن تذكر تعديل عملية البيع، وجدت: %s', sqlerrm);
    raise notice 'OK: I.1 اعتماد مرتجع لقطته الأصلية أصبحت قديمة (Sale عُدِّل بعد الإنشاء) رُفض بوضوح (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: I.1 قُبل اعتماد مرتجع رغم أن Sale الأصلية عُدِّلت بعد إنشاء المرتجع'; end if;

  -- refresh_pending_sales_return_from_sale() is the ONLY way to clear it.
  perform public.refresh_pending_sales_return_from_sale(v_return_id, v_row_version);
  -- The refresh only updates Sale-derived snapshots, never the business
  -- inputs (approved_refund_amount) — must be updated separately, proving
  -- these are deliberately independent concerns.
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.update_pending_sales_return(
    v_return_id, 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    'collected', 500.00, v_row_version
  );

  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_id, v_row_version);
  v_return := public.get_sales_return(v_return_id);
  assert v_return ->> 'status' = 'approved', 'I.2 الاعتماد يجب أن ينجح بعد التحديث الصريح من refresh_pending_sales_return_from_sale()';
  assert v_return ->> 'sales_revenue_reversal_amount' = '500.00', format('I.2 بعد التحديث الصريح يجب أن يعكس المرتجع السعر الجديد (500.00)، وجد %s', v_return ->> 'sales_revenue_reversal_amount');
  raise notice 'OK: I.2 refresh_pending_sales_return_from_sale() هو الطريقة الوحيدة الصريحة لتحديث لقطة المرتجع — لا إعادة التقاط ضمنية أبدًا';
end $$;

-- ============================================================================
-- 10. Profit-field hiding + audit_logs return.% protection (0091), extended
-- to Scenario P — the new return.refund_finalized action
-- ============================================================================
do $$
declare
  v_return_id uuid;
  v_return_manager jsonb;
begin
  select id into v_return_id from public.list_sales_returns(p_status := 'approved', p_limit := 1);

  v_return_manager := public.get_sales_return(v_return_id);
  assert v_return_manager ? 'gross_profit_reversal_amount', '10.1 مدير المرتجعات (يحمل sales.view_profit) يجب أن يرى gross_profit_reversal_amount';
end $$;

set local request.jwt.claims = '{"sub":"d9000000-0000-4000-8000-000000000003","role":"authenticated"}';
do $$
declare
  v_return_id uuid;
  v_return_blind jsonb;
begin
  select id into v_return_id from public.list_sales_returns(p_status := 'approved', p_limit := 1);
  v_return_blind := public.get_sales_return(v_return_id);
  assert not (v_return_blind ? 'gross_profit_reversal_amount'), '10.2 مستخدم بدون sales.view_profit يجب ألا يرى gross_profit_reversal_amount إطلاقًا (مفتاح غائب تمامًا)';
  assert not (v_return_blind ? 'net_profit_reversal_amount'), '10.2 ولا net_profit_reversal_amount';
  assert not (v_return_blind ? 'payment_fee_reversal_amount'), '10.2 ولا payment_fee_reversal_amount';
  assert not (v_return_blind ? 'adjusted_order_net_sales_profit'), '10.2 ولا adjusted_order_net_sales_profit';
  raise notice 'OK: 10.1/10.2 get_sales_return() يُخفي كل الحقول الحساسة ماليًا تمامًا (مفاتيح غائبة، لا قيم null) بدون sales.view_profit';

  -- audit_logs: return.approve carries the profit payload — must require
  -- audit_logs.view AND sales.view_profit, exactly like sale.% (0072/0091).
  perform 1 from public.audit_logs where action = 'return.approve' and entity_id = v_return_id;
  if found then
    raise exception 'BUG: 10.3 مستخدم يحمل audit_logs.view بدون sales.view_profit استطاع قراءة سجل تدقيق return.approve المالي';
  end if;
  raise notice 'OK: 10.3 سياسة audit_logs الممتدة (0091) تمنع قراءة سجلات return.%% المالية بدون sales.view_profit، رغم امتلاك audit_logs.view';

  -- Scenario P — the same policy covers the new return.refund_finalized
  -- action introduced by Patch 4.1.
  perform 1 from public.audit_logs where action = 'return.refund_finalized';
  if found then
    raise exception 'BUG: P.1 مستخدم يحمل audit_logs.view بدون sales.view_profit استطاع قراءة سجل تدقيق return.refund_finalized المالي';
  end if;
  raise notice 'OK: P.1 سياسة audit_logs تمنع قراءة سجلات return.refund_finalized بدون sales.view_profit أيضًا';
end $$;

set local request.jwt.claims = '{"sub":"d9000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_return_id uuid;
begin
  select id into v_return_id from public.list_sales_returns(p_status := 'approved', p_limit := 1);
  perform 1 from public.audit_logs where action = 'return.approve' and entity_id = v_return_id;
  if not found then
    raise exception 'BUG: 10.4 مستخدم يحمل audit_logs.view وsales.view_profit معًا لم يستطع قراءة سجل return.approve';
  end if;
  raise notice 'OK: 10.4 مستخدم يحمل الصلاحيتين معًا يقرأ سجل return.approve بنجاح';

  perform 1 from public.audit_logs where action = 'return.refund_finalized';
  if not found then
    raise exception 'BUG: P.2 مستخدم يحمل الصلاحيتين معًا لم يستطع قراءة سجل return.refund_finalized';
  end if;
  raise notice 'OK: P.2 مستخدم يحمل sales.view_profit + audit_logs.view يقرأ سجلات return.refund_finalized بنجاح — نفس السياسة الموحَّدة (Section 17)';
end $$;

-- ============================================================================
-- 11. Scenario J — refund_fee_policy='full_reversal' reverses ZERO fee on a
-- partial (non-completing) return, and absorbs the full remaining balance
-- only at the return that completes full coverage (Section 8 fix)
-- ============================================================================
do $$
declare
  v_store_b uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_full uuid;
  v_order_id uuid;
  v_item_a uuid; v_item_b uuid;
  v_return_a uuid; v_return_b uuid;
  v_row_version bigint;
  v_order jsonb; v_return jsonb;
begin
  -- Store B — Store A's business_today() was closed in section 8.
  select id into v_store_b from public.stores where code = 'S4STB';
  select id into v_karat_id from public.karats where code = 'S4K1';
  select id into v_category_id from public.product_categories where code = 's4cat1';
  select id into v_channel_id from public.collection_channels where key = 's4_channel';
  select id into v_payment_method_full from public.payment_methods where key = 's4_pm_full';

  select id into v_order_id from public.create_sales_order(
    v_store_b, public.business_today(), v_payment_method_full, v_channel_id,
    jsonb_build_array(
      jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 500.00),
      jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 500.00)
    )
  );
  v_order := public.get_sales_order(v_order_id);
  assert v_order ->> 'payment_fee_amount' = '100.00', format('J.0 عمولة الدفع لهذه العملية يجب أن تكون 100.00 (شرط أساسي)، وجدت %s', v_order ->> 'payment_fee_amount');
  v_item_a := (v_order -> 'items' -> 0 ->> 'id')::uuid;
  v_item_b := (v_order -> 'items' -> 1 ->> 'id')::uuid;

  -- First (PARTIAL, non-completing) return under full_reversal — reverses
  -- ZERO fee. The pre-Patch-4.1 bug would have wrongly reversed the full
  -- 100.00 here already.
  select id into v_return_a from public.create_sales_return(
    v_order_id, v_store_b, public.business_today(), 'wrong_item_delivered',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_a)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 500.00
  );
  select (public.get_sales_return(v_return_a) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_a, v_row_version);
  v_return := public.get_sales_return(v_return_a);
  assert v_return ->> 'payment_fee_reversal_amount' = '0.00', format('J.1 full_reversal على مرتجع جزئي (غير مكتمل التغطية) يجب أن يسترد عمولة صفرية، وجد %s', v_return ->> 'payment_fee_reversal_amount');
  raise notice 'OK: J.1 سياسة full_reversal لا تسترد أي عمولة على مرتجع جزئي — تنتظر اكتمال التغطية (Section 8)';

  -- Second (COMPLETING) return under full_reversal — absorbs the ENTIRE
  -- remaining fee (100.00), not a proportional share.
  select id into v_return_b from public.create_sales_return(
    v_order_id, v_store_b, public.business_today(), 'wrong_item_delivered',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_b)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 500.00
  );
  select (public.get_sales_return(v_return_b) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_b, v_row_version);
  v_return := public.get_sales_return(v_return_b);
  assert v_return ->> 'payment_fee_reversal_amount' = '100.00', format('J.2 full_reversal على المرتجع المكتمِل للتغطية يجب أن يسترد العمولة كاملة (100.00)، وجد %s', v_return ->> 'payment_fee_reversal_amount');
  raise notice 'OK: J.2 سياسة full_reversal تسترد العمولة كاملة فقط عند اكتمال التغطية الكاملة';
end $$;

-- ============================================================================
-- 12. Scenario L — VISIBLE store scope for historical corrections (Section
-- 13): a return processed at a store that is later DISABLED can still be
-- rejected/reversed/refunded/finalized.
-- ============================================================================
do $$
declare
  v_store_c uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid;
  v_order_id uuid; v_item_id uuid; v_return_id uuid; v_row_version bigint;
  v_return jsonb;
begin
  select id into v_karat_id from public.karats where code = 'S4K1';
  select id into v_category_id from public.product_categories where code = 's4cat1';
  select id into v_channel_id from public.collection_channels where key = 's4_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's4_pm';

  insert into public.stores (code, name_ar, status) values ('S4STC', 'متجر اختبار ج - سيُعطَّل', 'active') returning id into v_store_c;

  select id into v_order_id from public.create_sales_order(
    v_store_c, public.business_today(), v_payment_method_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 80.00))
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;
  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_c, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 80.00
  );
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_id, v_row_version);

  -- Disable the store — Store C is no longer OPERABLE, only VISIBLE
  -- (historically granted). reset role needed since stores.status update
  -- has its own RLS but actor 01 holds stores.create/edit already granted.
  update public.stores set status = 'disabled' where id = v_store_c;

  -- reverse_sales_return() must still succeed — VISIBLE scope (Section 13),
  -- not OPERABLE.
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.reverse_sales_return(v_return_id, v_row_version, 'تصحيح تاريخي بعد تعطيل المتجر');
  v_return := public.get_sales_return(v_return_id);
  assert v_return ->> 'status' = 'reversed', format('L.1 التراجع عن مرتجع في متجر مُعطَّل يجب أن ينجح (نطاق VISIBLE)، الحالة الحالية %s', v_return ->> 'status');
  raise notice 'OK: L.1 reverse_sales_return() ينجح على مرتجع في متجر مُعطَّل لاحقًا — نطاق VISIBLE وليس OPERABLE (Section 13)';
end $$;

-- ============================================================================
-- 13. Scenario M — list_sales_returns() new filters (Section 14): original
-- store, order number, scenario.
-- ============================================================================
do $$
declare
  v_order_number text;
  v_original_store_id uuid;
  v_count_by_order int;
  v_count_by_store int;
  v_count_by_scenario int;
begin
  select r.order_number, r.original_store_id into v_order_number, v_original_store_id
  from public.list_sales_returns(p_status := 'approved', p_limit := 1) r;

  select count(*) into v_count_by_order from public.list_sales_returns(p_order_number := v_order_number, p_limit := 200);
  assert v_count_by_order >= 1, format('M.1 الفلترة برقم عملية البيع (%s) يجب أن تُعيد نتيجة واحدة على الأقل', v_order_number);
  raise notice 'OK: M.1 list_sales_returns(p_order_number) يُصفّي بشكل صحيح';

  select count(*) into v_count_by_store from public.list_sales_returns(p_original_store_id := v_original_store_id, p_limit := 200);
  assert v_count_by_store >= 1, 'M.2 الفلترة بمتجر البيع الأصلي يجب أن تُعيد نتيجة واحدة على الأقل';
  raise notice 'OK: M.2 list_sales_returns(p_original_store_id) يُصفّي بشكل صحيح';

  select count(*) into v_count_by_scenario from public.list_sales_returns(p_scenario := 'defective_product', p_limit := 200);
  assert v_count_by_scenario >= 1, 'M.3 الفلترة بالسيناريو (defective_product) يجب أن تُعيد نتيجة واحدة على الأقل';
  raise notice 'OK: M.3 list_sales_returns(p_scenario) يُصفّي بشكل صحيح';
end $$;

-- ============================================================================
-- 14. Scenario Q — Patch 4.2 Section 1: requires_sale_refresh is an
-- INDEPENDENT, stricter guard than source_sale_row_version. Simulates the
-- exact legacy-upgrade shape 0099's backfill produces (a Pending return
-- flagged true, even though row_version happens to match) by flipping the
-- column directly as superuser — the real end-to-end upgrade path itself
-- (building a DB to 0091, editing the Sale, THEN applying 0092+) is proven
-- separately by the dedicated Patch 4.2 upgrade harness, run outside this
-- transaction-rolled-back file (see DELIVERY_REPORT.md's Patch 4.2
-- appendix).
-- ============================================================================
do $$
declare
  v_store_b uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid;
  v_order_id uuid; v_item_id uuid;
  v_return_id uuid;
  v_return jsonb;
begin
  select id into v_store_b from public.stores where code = 'S4STB';
  select id into v_karat_id from public.karats where code = 'S4K1';
  select id into v_category_id from public.product_categories where code = 's4cat1';
  select id into v_channel_id from public.collection_channels where key = 's4_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's4_pm';

  select id into v_order_id from public.create_sales_order(
    v_store_b, public.business_today(), v_payment_method_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.2000, 'sale_price', 200.00)),
    'S4-Q-LEGACY'
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_b, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id, 'condition', 'unknown', 'item_notes', 'ملاحظة اختبار Q')),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 200.00
  );

  v_return := public.get_sales_return(v_return_id);
  assert (v_return ->> 'requires_sale_refresh')::boolean = false, 'Q.0 مرتجع منشأ حديثًا يجب أن يبدأ بـ requires_sale_refresh=false — الالتقاط واللقطة يحدثان معًا في نفس العملية (Section 1)';
  assert v_return -> 'items' -> 0 ->> 'item_notes' = 'ملاحظة اختبار Q', 'Q.0b ملاحظات البند (item_notes) يجب أن تُحفظ وتُعرض (Section 3/8)';

  perform set_config('s4.q_return_id', v_return_id::text, false);
end $$;

-- Simulate exactly what 0099's backfill did to a genuine legacy Pending
-- return -- flip the flag directly, bypassing every RPC (exactly what the
-- backfill UPDATE statement itself does). `reset role` since sales_returns
-- has zero direct grants for `authenticated`.
reset role;
update public.sales_returns set requires_sale_refresh = true where id = current_setting('s4.q_return_id')::uuid;
set role authenticated;

do $$
declare
  v_return_id uuid := current_setting('s4.q_return_id')::uuid;
  v_return jsonb;
  v_row_version bigint;
begin
  v_return := public.get_sales_return(v_return_id);
  assert (v_return ->> 'requires_sale_refresh')::boolean = true, 'Q.1 requires_sale_refresh يجب أن يُعرض بصدق عبر get_sales_return() (غير محمي بصلاحية الربح)';

  v_row_version := (v_return ->> 'row_version')::bigint;
  begin
    perform public.approve_sales_return(v_return_id, v_row_version);
    raise exception 'BUG: Q.2 اعتماد مرتجع بعلم requires_sale_refresh=true قُبل رغم عدم وجود تحديث صريح';
  exception when others then
    if sqlerrm like 'BUG:%' then raise; end if;
    assert sqlerrm like '%يجب تحديث بيانات المرتجع من عملية البيع قبل اعتماده%', format('Q.2 رسالة الرفض غير متوقعة: %s', sqlerrm);
    raise notice 'OK: Q.2 اعتماد مرتجع بعلم requires_sale_refresh=true (محاكاة لقطة مرتجع قديم قبل الترقية، Section 1) رُفض بوضوح رغم تطابق source_sale_row_version — حارس مستقل وأقوى (%)', sqlerrm;
  end;

  perform public.refresh_pending_sales_return_from_sale(v_return_id, v_row_version);
  v_return := public.get_sales_return(v_return_id);
  assert (v_return ->> 'requires_sale_refresh')::boolean = false, 'Q.3 refresh_pending_sales_return_from_sale() يجب أن يكون الطريق الوحيد لتصفير requires_sale_refresh';
  raise notice 'OK: Q.3 refresh_pending_sales_return_from_sale() صفّر requires_sale_refresh — الطريق الصريح الوحيد (Section 1/4)';

  v_row_version := (v_return ->> 'row_version')::bigint;
  perform public.approve_sales_return(v_return_id, v_row_version);
  v_return := public.get_sales_return(v_return_id);
  assert v_return ->> 'status' = 'approved', 'Q.4 الاعتماد يجب أن ينجح الآن بعد التحديث الصريح';
  raise notice 'OK: Q.4 الاعتماد نجح بعد التحديث الصريح — لا حاجة لتخمين تطابق اللقطات القديمة أبدًا (Section 1)';
end $$;

-- ============================================================================
-- 15. Scenario R — Patch 4.2 Section 3/4: finalize -> reject direct record
-- -> reopen (reason required) -> record succeeds -> finalize again creates
-- a SECOND historical finalization event. Append-only history never erases
-- the first entry.
-- ============================================================================
do $$
declare
  v_store_b uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid;
  v_order_id uuid; v_item_id uuid;
  v_return_id uuid; v_row_version bigint;
  v_return jsonb;
  v_history jsonb;
  v_bug boolean := false;
begin
  select id into v_store_b from public.stores where code = 'S4STB';
  select id into v_karat_id from public.karats where code = 'S4K1';
  select id into v_category_id from public.product_categories where code = 's4cat1';
  select id into v_channel_id from public.collection_channels where key = 's4_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's4_pm';

  select id into v_order_id from public.create_sales_order(
    v_store_b, public.business_today(), v_payment_method_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.3000, 'sale_price', 300.00))
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_b, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 300.00
  );
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_id, v_row_version);

  perform public.record_sales_return_refund(v_return_id, 300.00, v_payment_method_id);

  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.finalize_sales_return_refund(v_return_id, v_row_version);

  v_return := public.get_sales_return(v_return_id);
  assert v_return ->> 'refund_reconciliation_state' = 'finalized_matched', 'R.1 يجب أن تكون التسوية finalized_matched بعد أول إغلاق';
  v_history := v_return -> 'reconciliation_history';
  assert jsonb_array_length(v_history) = 1, format('R.1b سجل التسوية يجب أن يحوي حدثًا واحدًا فقط حتى الآن، وجد %s', jsonb_array_length(v_history));
  assert v_history -> 0 ->> 'event_type' = 'finalized', 'R.1c الحدث الأول يجب أن يكون finalized';
  raise notice 'OK: R.1 finalize_sales_return_refund() أنشأ أول حدث تسوية تاريخي (finalized) — سجل مطابق تمامًا';

  begin
    perform public.record_sales_return_refund(v_return_id, 10.00, v_payment_method_id);
    v_bug := true;
  exception when others then
    assert sqlerrm like '%يجب إعادة فتح التسوية أولًا%', format('R.2 رسالة رفض تسجيل استرداد جديد بعد الإغلاق غير متوقعة: %s', sqlerrm);
    raise notice 'OK: R.2 تسجيل استرداد جديد مباشرة بعد الإغلاق رُفض بوضوح (%) — التسوية المُغلقة لا يمكن تجاوزها ضمنيًا (Section 3)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: R.2 قُبل تسجيل استرداد جديد بعد إغلاق التسوية دون إعادة فتح صريحة'; end if;

  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.reopen_sales_return_refund_reconciliation(v_return_id, v_row_version, 'تصحيح: استرداد إضافي مطلوب بعد المطابقة الأولى');

  v_return := public.get_sales_return(v_return_id);
  assert v_return ->> 'refund_finalized_at' is null, 'R.3 إعادة الفتح يجب أن تصفّر refund_finalized_at الحالي';
  assert v_return ->> 'refund_reconciliation_state' = 'pending', format('R.3b حالة التسوية يجب أن تعود pending بعد إعادة الفتح، وجد %s', v_return ->> 'refund_reconciliation_state');
  v_history := v_return -> 'reconciliation_history';
  assert jsonb_array_length(v_history) = 2, format('R.3c سجل التسوية يجب أن يحوي حدثين الآن (finalized ثم reopened) دون حذف الأول، وجد %s', jsonb_array_length(v_history));
  assert v_history -> 1 ->> 'event_type' = 'reopened', 'R.3d الحدث الثاني يجب أن يكون reopened';
  raise notice 'OK: R.3 reopen_sales_return_refund_reconciliation() أضافت حدث reopened جديدًا دون حذف حدث finalized السابق (Section 4)';

  perform public.record_sales_return_refund(v_return_id, 10.00, v_payment_method_id);
  raise notice 'OK: R.4 تسجيل استرداد جديد نجح بعد إعادة الفتح الصريحة';

  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.finalize_sales_return_refund(v_return_id, v_row_version, 'فرق بسبب الاسترداد الإضافي بعد إعادة الفتح');

  v_return := public.get_sales_return(v_return_id);
  assert v_return ->> 'refund_reconciliation_state' = 'finalized_with_variance', format('R.5 يجب أن تكون التسوية finalized_with_variance بعد الإغلاق الثاني (310 فعليًا مقابل 300 مستهدف)، وجد %s', v_return ->> 'refund_reconciliation_state');
  v_history := v_return -> 'reconciliation_history';
  assert jsonb_array_length(v_history) = 3, format('R.5b سجل التسوية يجب أن يحوي 3 أحداث الآن (finalized, reopened, finalized) — الإغلاق الثاني حدث تاريخي جديد منفصل، وجد %s', jsonb_array_length(v_history));
  assert v_history -> 2 ->> 'event_type' = 'finalized', 'R.5c الحدث الثالث يجب أن يكون finalized (الإغلاق الثاني)';
  assert v_history -> 2 ->> 'actual_refunded_total' = '310.00', format('R.5d الحدث الثالث يجب أن يسجل 310.00 كمجموع مسترد فعليًا، وجد %s', v_history -> 2 ->> 'actual_refunded_total');
  raise notice 'OK: R.5 الإغلاق الثاني نجح وأنشأ حدث تاريخي منفصل ثالث — دورة finalize -> reopen -> finalize كاملة موثّقة بالكامل دون فقدان أي تاريخ (Section 3/4)';
end $$;

-- ============================================================================
-- 16. Scenario S — Patch 4.2 Section 3/4: the SAME finalize -> reject
-- direct reversal -> reopen -> reversal succeeds -> finalize again cycle,
-- this time for reverse_sales_return_refund_event() instead of record.
-- ============================================================================
do $$
declare
  v_store_b uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid;
  v_order_id uuid; v_item_id uuid;
  v_return_id uuid; v_row_version bigint; v_event_id uuid;
  v_return jsonb;
  v_history jsonb;
  v_bug boolean := false;
begin
  select id into v_store_b from public.stores where code = 'S4STB';
  select id into v_karat_id from public.karats where code = 'S4K1';
  select id into v_category_id from public.product_categories where code = 's4cat1';
  select id into v_channel_id from public.collection_channels where key = 's4_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's4_pm';

  select id into v_order_id from public.create_sales_order(
    v_store_b, public.business_today(), v_payment_method_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.4000, 'sale_price', 400.00))
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_b, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 400.00
  );
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_id, v_row_version);

  select id into v_event_id from public.record_sales_return_refund(v_return_id, 400.00, v_payment_method_id);

  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.finalize_sales_return_refund(v_return_id, v_row_version);
  raise notice 'OK: S.1 finalize_sales_return_refund() أغلق التسوية (مطابقة) قبل محاولة التراجع';

  begin
    perform public.reverse_sales_return_refund_event(v_event_id, 'محاولة تراجع مباشرة بعد الإغلاق');
    v_bug := true;
  exception when others then
    assert sqlerrm like '%يجب إعادة فتح التسوية أولًا%', format('S.2 رسالة رفض التراجع بعد الإغلاق غير متوقعة: %s', sqlerrm);
    raise notice 'OK: S.2 التراجع عن سجل استرداد نشط مباشرة بعد الإغلاق رُفض بوضوح (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: S.2 قُبل التراجع عن سجل استرداد بعد إغلاق التسوية دون إعادة فتح صريحة'; end if;

  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.reopen_sales_return_refund_reconciliation(v_return_id, v_row_version, 'تصحيح: عكس دفعة مسجَّلة بالخطأ');
  raise notice 'OK: S.3 إعادة الفتح نجحت';

  perform public.reverse_sales_return_refund_event(v_event_id, 'دفعة مسجَّلة بالخطأ');
  raise notice 'OK: S.4 التراجع عن سجل الاسترداد نجح بعد إعادة الفتح الصريحة';

  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.finalize_sales_return_refund(v_return_id, v_row_version, 'فرق بسبب التراجع عن الدفعة الوحيدة بعد إعادة الفتح');

  v_return := public.get_sales_return(v_return_id);
  assert v_return ->> 'actual_refunded_total' = '0.00', format('S.5 المجموع الفعلي يجب أن يكون 0.00 بعد التراجع عن الدفعة الوحيدة، وجد %s', v_return ->> 'actual_refunded_total');
  v_history := v_return -> 'reconciliation_history';
  assert jsonb_array_length(v_history) = 3, format('S.5b سجل التسوية يجب أن يحوي 3 أحداث (finalized, reopened, finalized)، وجد %s', jsonb_array_length(v_history));
  assert v_history -> 2 ->> 'actual_refunded_total' = '0.00', 'S.5c الحدث الثالث يجب أن يسجل 0.00 كمجموع مسترد فعليًا';
  raise notice 'OK: S.5 دورة finalize -> reject reverse -> reopen -> reverse -> finalize كاملة لمسار التراجع عن سجل استرداد — نفس آلية الحالة تمامًا لكلا المسارين (Section 3/4)';
end $$;

-- ============================================================================
-- 17. Scenario U — Patch 4.2 Section 6: business-date chronology beyond the
-- pre-existing future-date rejection — reversal/refund dates must not
-- precede approval or return_date; a refund-reversal must not precede its
-- own original refund date; the future-date upper bound remains intact.
-- ============================================================================
do $$
declare
  v_store_b uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid;
  v_order_id uuid; v_item_id uuid;
  v_return_id uuid; v_row_version bigint; v_event_id uuid;
  v_yesterday date := public.business_today() - 1;
  v_tomorrow date := public.business_today() + 1;
  v_bug boolean := false;
begin
  select id into v_store_b from public.stores where code = 'S4STB';
  select id into v_karat_id from public.karats where code = 'S4K1';
  select id into v_category_id from public.product_categories where code = 's4cat1';
  select id into v_channel_id from public.collection_channels where key = 's4_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's4_pm';

  select id into v_order_id from public.create_sales_order(
    v_store_b, public.business_today(), v_payment_method_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.5000, 'sale_price', 500.00))
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_b, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 500.00
  );
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_id, v_row_version);

  -- U.1 -- refund_business_date before approval/return_date (both = today) rejected.
  begin
    perform public.record_sales_return_refund(v_return_id, 500.00, v_payment_method_id, v_yesterday);
    v_bug := true;
  exception when others then
    assert sqlerrm like '%قبل تاريخ اعتماد المرتجع%', format('U.1 رسالة الرفض غير متوقعة: %s', sqlerrm);
    raise notice 'OK: U.1 تسجيل استرداد بتاريخ (أمس) قبل تاريخ اعتماد المرتجع رُفض بوضوح (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: U.1 قُبل استرداد بتاريخ سابق لاعتماد المرتجع'; end if;

  -- U.1b -- future refund_business_date still rejected (pre-existing upper bound).
  begin
    perform public.record_sales_return_refund(v_return_id, 500.00, v_payment_method_id, v_tomorrow);
    v_bug := true;
  exception when others then
    assert sqlerrm like '%مستقبل%', format('U.1b رسالة الرفض غير متوقعة: %s', sqlerrm);
    raise notice 'OK: U.1b تسجيل استرداد بتاريخ مستقبلي ما زال مرفوضًا (الحد الأعلى محفوظ) (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: U.1b قُبل استرداد بتاريخ مستقبلي'; end if;

  select id into v_event_id from public.record_sales_return_refund(v_return_id, 500.00, v_payment_method_id);

  -- U.2 -- reversal_business_date before the ORIGINAL event's own date rejected.
  begin
    perform public.reverse_sales_return_refund_event(v_event_id, 'محاولة تراجع بتاريخ سابق', v_yesterday);
    v_bug := true;
  exception when others then
    assert sqlerrm like '%قبل تاريخ الاسترداد الأصلي نفسه%', format('U.2 رسالة الرفض غير متوقعة: %s', sqlerrm);
    raise notice 'OK: U.2 التراجع عن سجل استرداد بتاريخ (أمس) قبل تاريخ الاسترداد الأصلي نفسه رُفض بوضوح (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: U.2 قُبل تراجع بتاريخ سابق لتاريخ الاسترداد الأصلي'; end if;

  -- U.3 -- reverse_sales_return()'s own reversal_business_date must not
  -- precede approval or return_date either (Section 6). The active refund
  -- event from U.1/U.2 is deliberately left untouched -- reversing an
  -- approved return that still has an active cash refund is exactly the
  -- real scenario Section 4's reopen workflow exists for.
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  begin
    perform public.reverse_sales_return(v_return_id, v_row_version, 'محاولة تراجع عن الاعتماد بتاريخ سابق', v_yesterday);
    v_bug := true;
  exception when others then
    assert sqlerrm like '%قبل تاريخ اعتماد المرتجع%', format('U.3 رسالة الرفض غير متوقعة: %s', sqlerrm);
    raise notice 'OK: U.3 التراجع عن اعتماد المرتجع بتاريخ (أمس) قبل تاريخ الاعتماد نفسه رُفض بوضوح (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: U.3 قُبل تراجع عن الاعتماد بتاريخ سابق لتاريخ الاعتماد'; end if;

  perform public.reverse_sales_return(v_return_id, v_row_version, 'إنهاء اختبار U طبيعيًا');
  raise notice 'OK: U.4 التراجع عن الاعتماد بتاريخ اليوم (>= تاريخ الاعتماد وتاريخ المرتجع) نجح بشكل طبيعي';
end $$;

-- ============================================================================
-- 18. Scenario V — Patch 4.2 Section 5: preview_sales_return() parity with
-- create/approve's own validation tree and suggestion logic.
-- ============================================================================
do $$
declare
  v_store_b uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_payment_method_id uuid;
  v_order_id uuid; v_item_id uuid;
  v_items jsonb;
  v_preview jsonb;
  v_bug boolean := false;
begin
  select id into v_store_b from public.stores where code = 'S4STB';
  select id into v_karat_id from public.karats where code = 'S4K1';
  select id into v_category_id from public.product_categories where code = 's4cat1';
  select id into v_channel_id from public.collection_channels where key = 's4_channel';
  select id into v_payment_method_id from public.payment_methods where key = 's4_pm';

  select id into v_order_id from public.create_sales_order(
    v_store_b, public.business_today(), v_payment_method_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.6000, 'sale_price', 600.00))
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;
  v_items := jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id, 'condition', 'unknown'));

  -- V.1 -- progressive/incomplete entry: items only, nothing else supplied,
  -- must still succeed with a useful estimate (never demands scenario/
  -- collection_state up front, unlike create_sales_return()).
  v_preview := public.preview_sales_return(v_order_id, v_items);
  assert v_preview ->> 'sales_revenue_reversal_amount' = '600.00', format('V.1 استرجاع الإيراد التقديري يجب أن يكون 600.00 حتى بدون scenario/collection_state، وجد %s', v_preview ->> 'sales_revenue_reversal_amount');
  assert v_preview ->> 'approved_refund_amount' is null, 'V.1b approved_refund_amount يجب أن يكون null في الاستجابة عند عدم تزويده';
  raise notice 'OK: V.1 preview_sales_return() نجح بإدخال جزئي (بنود فقط) — لا يفرض scenario/collection_state مسبقًا';

  -- V.2 -- customer_never_received + not_collected suggests 0, matching the
  -- exact DB CHECK constraint and approve_sales_return()'s own rule.
  v_preview := public.preview_sales_return(
    v_order_id, v_items,
    p_scenario := 'customer_never_received', p_collection_state := 'not_collected'
  );
  assert (v_preview ->> 'suggested_approved_refund_amount')::numeric = 0, format('V.2 الاسترداد المقترَح يجب أن يكون صفرًا لسيناريو customer_never_received+not_collected، وجد %s', v_preview ->> 'suggested_approved_refund_amount');
  raise notice 'OK: V.2 preview_sales_return() يقترح استردادًا صفريًا لسيناريو customer_never_received+not_collected (Section 2/5) — نفس منطق approve_sales_return() تمامًا';

  -- V.3 -- same validation tree as create: an approved_refund_amount that
  -- differs from the revenue reversal WITHOUT a reason raises the exact
  -- same rejection create_sales_return() would.
  begin
    perform public.preview_sales_return(v_order_id, v_items, p_approved_refund_amount := 500.00);
    v_bug := true;
  exception when others then
    assert sqlerrm like '%يجب إدخال سبب الفرق%', format('V.3 رسالة الرفض غير متوقعة: %s', sqlerrm);
    raise notice 'OK: V.3 preview_sales_return() يرفض approved_refund_amount مختلف عن صافي عكس الإيراد بلا سبب فرق — نفس شجرة تحقق create_sales_return() تمامًا (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: V.3 preview_sales_return() قبِل approved_refund_amount مختلف بلا سبب فرق (خلاف create_sales_return())'; end if;

  -- V.4 -- an explicitly-supplied approved_refund_amount (with a reason) is
  -- echoed back AS-IS, alongside its real variance -- Preview never
  -- silently substitutes its own suggestion for genuine user input.
  v_preview := public.preview_sales_return(
    v_order_id, v_items,
    p_approved_refund_amount := 500.00, p_refund_difference_reason := 'خصم يدوي متفق عليه مع العميل'
  );
  assert v_preview ->> 'approved_refund_amount' = '500.00', format('V.4 يجب أن تُعاد القيمة المُدخلة يدويًا (500.00) كما هي دون استبدال، وجد %s', v_preview ->> 'approved_refund_amount');
  assert v_preview ->> 'refund_variance' = '-100.00', format('V.4b الفارق يجب أن يكون -100.00 (500.00 مُدخل - 600.00 عكس الإيراد الفعلي)، وجد %s', v_preview ->> 'refund_variance');
  assert v_preview ->> 'suggested_approved_refund_amount' = '600.00', 'V.4c الاقتراح المحايد (600.00) يبقى ظاهرًا بجانب القيمة المُدخلة — لا حذف ولا استبدال';
  raise notice 'OK: V.4 preview_sales_return() يُعيد قيمة الاسترداد المُدخلة يدويًا كما هي مع الفارق الحقيقي — لا استبدال صامت أبدًا (Section 5)';

  -- V.5 -- deduction-bound validation matches create's tree too.
  begin
    perform public.preview_sales_return(v_order_id, v_items, p_non_shipping_deduction_amount := 700.00, p_deduction_reason := 'استقطاع مبالغ فيه');
    v_bug := true;
  exception when others then
    assert sqlerrm like '%لا يمكن أن تتجاوز%', format('V.5 رسالة الرفض غير متوقعة: %s', sqlerrm);
    raise notice 'OK: V.5 preview_sales_return() يرفض استقطاعًا يتجاوز إجمالي مبلغ البيع الأصلي — نفس شجرة تحقق create_sales_return() (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG: V.5 preview_sales_return() قبِل استقطاعًا يتجاوز الإجمالي'; end if;
end $$;

reset role;
reset request.jwt.claims;

do $$ begin
  raise notice 'ALL sales_returns_core.test.sql ASSERTIONS PASSED (Patch 4.1 scenarios A-P, Patch 4.2 scenarios Q/R/S/U/V covered)';
end $$;

rollback;
