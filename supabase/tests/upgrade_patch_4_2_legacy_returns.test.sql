-- ============================================================================
-- Integration test: Patch 4.2 legacy-upgrade proof (spec item 10 / Section
-- 12 "Missing Upgrade Tests")
-- ============================================================================
-- Run AFTER supabase/tests/fixtures/patch_4_2_legacy_upgrade_pre_fixture.sql
-- was applied against a DB at migration 0091 + seed.sql, and AFTER
-- migrations 0092-latest were then applied on top — see
-- scripts/run_upgrade_test_patch_4_2.sh, which drives the whole sequence in
-- the correct order across separate psql invocations.
--
-- Re-identifies the three fixture rows via sales_orders.customer_name (the
-- fixture tags each order 'P42-PENDING'/'P42-APPROVED'/'P42-REVERSED') since
-- this is a genuinely separate psql connection from the one that ran the
-- fixture — no session-local state (set_config, temp tables) survives
-- across that boundary.
--
-- Runs as superuser (no `set role authenticated`) throughout — reads real
-- table data directly to prove the actual persisted state after upgrade,
-- the same way scripts/run_upgrade_test.sh's own upgrade_from_0039.test.sql
-- does. Where an RPC's actual behavior (not just backfilled column values)
-- needs proving — approve_sales_return()'s rejection/success,
-- refresh_pending_sales_return_from_sale(), get_sales_return()'s
-- adjusted_order_net_sales_profit — a short `set role authenticated` +
-- `set local request.jwt.claims` block is used, scoped to that one
-- statement only (mirrors the established convention in
-- sales_returns_concurrency.test.sql for the exact same reason: role/claims
-- settings set with `set local` do not survive past the statement/
-- transaction that set them).
--
-- No wrapping BEGIN/COMMIT (autocommit) — this test only reads, plus the
-- one explicit refresh_pending_sales_return_from_sale() + approve_sales_
-- return() call needed to prove the P42-PENDING remediation path actually
-- works end-to-end; nothing here needs to be rolled back, and this mirrors
-- upgrade_from_0039.test.sql's own autocommit design.
--
-- Requires: migrations 0001-latest + supabase/seed.sql applied, AND the
-- Patch 4.2 legacy pre-fixture applied BEFORE 0092-latest were applied.
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/upgrade_patch_4_2_legacy_returns.test.sql
-- ============================================================================

-- ============================================================================
-- (A) P42-PENDING — requires_sale_refresh backfill + genuine staleness +
-- remediation path (Section 1)
-- ============================================================================
do $$
declare
  v_order_id uuid;
  v_return_id uuid;
  v_item_id uuid;
  v_requires_refresh boolean;
  v_snapshot_price numeric;
  v_current_price numeric;
begin
  select id into v_order_id from public.sales_orders where customer_name = 'P42-PENDING';
  select id into v_return_id from public.sales_returns where sales_order_id = v_order_id;
  select sri.sales_order_item_id, sri.sale_price_snapshot
    into v_item_id, v_snapshot_price
    from public.sales_return_items sri where sri.sales_return_id = v_return_id;
  select sale_price into v_current_price from public.sales_order_items where id = v_item_id;

  select requires_sale_refresh into v_requires_refresh from public.sales_returns where id = v_return_id;
  assert v_requires_refresh = true, format('A.1 0099 backfill يجب أن يعيّن requires_sale_refresh=true لمرتجع كان pending وقت الترقية، وجد %s', v_requires_refresh);
  raise notice 'OK: A.1 0099 backfill عيّن requires_sale_refresh=true لمرتجع P42-PENDING القديم';

  -- Proves genuine staleness, not merely a flag: the item's snapshot
  -- (1000.00, captured by the OLD create_sales_return()) still disagrees
  -- with the Sale's real current price (1200.00, set by the fixture's
  -- post-creation update_sales_order() edit).
  assert v_snapshot_price = 1000.00, format('A.2 لقطة سعر البند (قديمة، ما قبل التحديث) يجب أن تبقى 1000.00 بعد الترقية، وجد %s', v_snapshot_price);
  assert v_current_price = 1200.00, format('A.2 السعر الحالي الفعلي لبند عملية البيع يجب أن يكون 1200.00 (عُدِّل بعد إنشاء المرتجع)، وجد %s', v_current_price);
  raise notice 'OK: A.2 التباعد الفعلي بين لقطة البند (1000.00) والسعر الحالي (1200.00) مؤكَّد — ليس مجرد علم منفصل عن الواقع';
end $$;

-- approve_sales_return() must reject outright while requires_sale_refresh is
-- true, with the exact Section 1 message (0101).
do $$
declare
  v_return_id uuid;
  v_row_version bigint;
  v_rejected boolean := false;
begin
  -- Resolve IDs via a direct (superuser) table read BEFORE switching role —
  -- sales_returns/sales_orders have ZERO direct SELECT RLS policy for
  -- `authenticated` (established convention, see file header), so this must
  -- happen before `set local role authenticated` below.
  select sr.id into v_return_id
    from public.sales_returns sr join public.sales_orders so on so.id = sr.sales_order_id
    where so.customer_name = 'P42-PENDING';

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"db000000-0000-4000-8000-000000000001","role":"authenticated"}';

  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;

  begin
    perform public.approve_sales_return(v_return_id, v_row_version);
  exception when others then
    if sqlerrm = 'يجب تحديث بيانات المرتجع من عملية البيع قبل اعتماده.' then
      v_rejected := true;
    else
      raise;
    end if;
  end;

  assert v_rejected, 'A.3 اعتماد مرتجع P42-PENDING يجب أن يُرفض برسالة Section 1 الصريحة طالما requires_sale_refresh=true';
  raise notice 'OK: A.3 approve_sales_return() رفض اعتماد مرتجع P42-PENDING القديم برسالة "يجب تحديث بيانات المرتجع..." الصريحة';
end $$;

-- refresh_pending_sales_return_from_sale() clears the flag, re-snapshots to
-- the REAL current price, and approval then succeeds.
do $$
declare
  v_return_id uuid;
  v_row_version bigint;
  v_requires_refresh boolean;
  v_snapshot_price numeric;
  v_revenue_reversal text;
  v_return_jsonb jsonb;
begin
  select sr.id into v_return_id
    from public.sales_returns sr join public.sales_orders so on so.id = sr.sales_order_id
    where so.customer_name = 'P42-PENDING';

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"db000000-0000-4000-8000-000000000001","role":"authenticated"}';

  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.refresh_pending_sales_return_from_sale(v_return_id, v_row_version);

  v_return_jsonb := public.get_sales_return(v_return_id);
  v_requires_refresh := (v_return_jsonb ->> 'requires_sale_refresh')::boolean;
  v_row_version := (v_return_jsonb ->> 'row_version')::bigint;
  assert v_requires_refresh = false, 'A.4 refresh_pending_sales_return_from_sale() يجب أن يمسح requires_sale_refresh';

  v_snapshot_price := (v_return_jsonb -> 'items' -> 0 ->> 'sale_price')::numeric;
  assert v_snapshot_price = 1200.00, format('A.4 بعد التحديث الصريح، لقطة السعر يجب أن تصبح 1200.00 (السعر الحالي الفعلي)، وجد %s', v_snapshot_price);
  raise notice 'OK: A.4 refresh_pending_sales_return_from_sale() مسح requires_sale_refresh وأعاد أخذ اللقطة على السعر الحالي (1200.00)';

  perform public.approve_sales_return(v_return_id, v_row_version);
  select (public.get_sales_return(v_return_id) ->> 'sales_revenue_reversal_amount') into v_revenue_reversal;
  assert v_revenue_reversal = '1200.00', format('A.5 بعد التحديث الصريح، الاعتماد يجب أن ينجح ويحسب استرجاع الإيراد على السعر الحقيقي 1200.00، وجد %s', v_revenue_reversal);
  raise notice 'OK: A.5 بعد refresh الصريح، اعتماد مرتجع P42-PENDING نجح واحتسب استرجاع الإيراد على السعر الحالي الصحيح (1200.00) لا القديم (1000.00)';
end $$;

-- ============================================================================
-- (B) P42-APPROVED — legacy financial backfill (Section 2)
-- ============================================================================
do $$
declare
  v_order_id uuid;
  v_return_id uuid;
  v_returned_original_sale_amount numeric;
  v_recovered_original_cost_amount numeric;
  v_sales_revenue_reversal_amount numeric;
  v_payment_fee_reversal_amount numeric;
  v_net_sales_profit_adjustment numeric;
  v_expected_adjustment numeric;
  v_order_net_sales_profit numeric;
begin
  select id, net_sales_profit into v_order_id, v_order_net_sales_profit from public.sales_orders where customer_name = 'P42-APPROVED';
  select id into v_return_id from public.sales_returns where sales_order_id = v_order_id;

  select returned_original_sale_amount, recovered_original_cost_amount,
         sales_revenue_reversal_amount, payment_fee_reversal_amount, net_sales_profit_adjustment
    into v_returned_original_sale_amount, v_recovered_original_cost_amount,
         v_sales_revenue_reversal_amount, v_payment_fee_reversal_amount, v_net_sales_profit_adjustment
    from public.sales_returns where id = v_return_id;

  assert v_returned_original_sale_amount is not null, 'B.1 returned_original_sale_amount لم يعد NULL بعد backfill 0099 لمرتجع P42-APPROVED القديم';
  assert v_recovered_original_cost_amount is not null, 'B.1 recovered_original_cost_amount لم يعد NULL بعد backfill 0099';
  assert v_net_sales_profit_adjustment is not null, 'B.1 net_sales_profit_adjustment لم يعد NULL بعد backfill 0099';
  raise notice 'OK: B.1 backfill 0099 ملأ الحقول المالية الثلاثة الجديدة لمرتجع P42-APPROVED القديم (لم تعد NULL)';

  -- Self-consistency check against 0099's own exact backfill formula, using
  -- the row's own already-backfilled fields (never hardcoded numbers) —
  -- net_sales_profit_adjustment = -sales_revenue_reversal_amount +
  -- recovered_original_cost_amount + payment_fee_reversal_amount.
  v_expected_adjustment := round(-coalesce(v_sales_revenue_reversal_amount, 0) + coalesce(v_recovered_original_cost_amount, 0) + coalesce(v_payment_fee_reversal_amount, 0), 2);
  assert v_net_sales_profit_adjustment = v_expected_adjustment, format('B.2 net_sales_profit_adjustment (%s) يجب أن يطابق الصيغة -sales_revenue_reversal_amount+recovered_original_cost_amount+payment_fee_reversal_amount (%s)', v_net_sales_profit_adjustment, v_expected_adjustment);
  raise notice 'OK: B.2 net_sales_profit_adjustment المُعاد بناؤه (backfill) يطابق صيغة 0099 تمامًا: %', v_net_sales_profit_adjustment;

  assert v_returned_original_sale_amount = 800.00, format('B.3 returned_original_sale_amount يجب أن يساوي سعر البيع الأصلي 800.00، وجد %s', v_returned_original_sale_amount);
  raise notice 'OK: B.3 returned_original_sale_amount = 800.00 (يطابق سعر البيع الأصلي لمرتجع P42-APPROVED)';
end $$;

-- get_sales_return()'s adjusted_order_net_sales_profit must correctly equal
-- the order's base net_sales_profit PLUS the (now-backfilled) adjustment.
do $$
declare
  v_return_id uuid;
  v_order_id uuid;
  v_order_net_sales_profit numeric;
  v_net_sales_profit_adjustment numeric;
  v_return jsonb;
begin
  select sr.id, sr.sales_order_id into v_return_id, v_order_id from public.sales_returns sr join public.sales_orders so on so.id = sr.sales_order_id where so.customer_name = 'P42-APPROVED';
  select so.net_sales_profit into v_order_net_sales_profit from public.sales_orders so where so.id = v_order_id;
  select sr.net_sales_profit_adjustment into v_net_sales_profit_adjustment from public.sales_returns sr where sr.id = v_return_id;

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"db000000-0000-4000-8000-000000000001","role":"authenticated"}';

  v_return := public.get_sales_return(v_return_id);
  assert (v_return ->> 'adjusted_order_net_sales_profit')::numeric = round(v_order_net_sales_profit + v_net_sales_profit_adjustment, 2),
    format('B.4 adjusted_order_net_sales_profit (%s) يجب أن يساوي net_sales_profit الأساسي + التعديل المُعاد بناؤه (%s)', v_return ->> 'adjusted_order_net_sales_profit', round(v_order_net_sales_profit + v_net_sales_profit_adjustment, 2));
  raise notice 'OK: B.4 get_sales_return() لمرتجع P42-APPROVED القديم يحسب adjusted_order_net_sales_profit بشكل صحيح باستخدام الحقل المُعاد بناؤه عبر backfill';
end $$;

-- ============================================================================
-- (C) P42-REVERSED — legacy financial backfill (Section 2), but EXCLUDED
-- from adjusted_order_net_sales_profit (only status='approved' returns
-- contribute)
-- ============================================================================
do $$
declare
  v_order_id uuid;
  v_return_id uuid;
  v_status text;
  v_returned_original_sale_amount numeric;
  v_recovered_original_cost_amount numeric;
begin
  select id into v_order_id from public.sales_orders where customer_name = 'P42-REVERSED';
  select id, status into v_return_id, v_status from public.sales_returns where sales_order_id = v_order_id;

  assert v_status = 'reversed', format('C.1 حالة مرتجع P42-REVERSED يجب أن تبقى reversed، وجد %s', v_status);

  select returned_original_sale_amount, recovered_original_cost_amount
    into v_returned_original_sale_amount, v_recovered_original_cost_amount
    from public.sales_returns where id = v_return_id;
  assert v_returned_original_sale_amount is not null, 'C.2 returned_original_sale_amount لم يعد NULL بعد backfill 0099 لمرتجع P42-REVERSED القديم أيضًا';
  assert v_recovered_original_cost_amount is not null, 'C.2 recovered_original_cost_amount لم يعد NULL بعد backfill 0099 لمرتجع P42-REVERSED القديم أيضًا';
  raise notice 'OK: C.2 backfill 0099 ملأ الحقول المالية أيضًا لمرتجع P42-REVERSED القديم (reversed لا يُستثنى من الـbackfill نفسه)';
end $$;

-- adjusted_order_net_sales_profit on THIS order must equal ONLY the base
-- net_sales_profit — the reversed return's adjustment must NOT be summed in.
do $$
declare
  v_order_id uuid;
  v_return_id uuid;
  v_order_net_sales_profit numeric;
  v_return jsonb;
begin
  select so.id, so.net_sales_profit into v_order_id, v_order_net_sales_profit from public.sales_orders so where so.customer_name = 'P42-REVERSED';
  select sr.id into v_return_id from public.sales_returns sr where sr.sales_order_id = v_order_id;

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"db000000-0000-4000-8000-000000000001","role":"authenticated"}';

  v_return := public.get_sales_return(v_return_id);
  assert (v_return ->> 'adjusted_order_net_sales_profit')::numeric = round(v_order_net_sales_profit, 2),
    format('C.3 adjusted_order_net_sales_profit (%s) يجب أن يساوي net_sales_profit الأساسي فقط (%s) — مرتجع reversed مُستثنى دائمًا من المجموع رغم أن حقوله المالية أُعيد بناؤها', v_return ->> 'adjusted_order_net_sales_profit', round(v_order_net_sales_profit, 2));
  raise notice 'OK: C.3 adjusted_order_net_sales_profit على طلب P42-REVERSED يساوي net_sales_profit الأساسي فقط — مرتجع reversed مُستثنى من المجموع رغم أن حقوله المالية أُعيد بناؤها صحيحة عبر backfill';
end $$;

\echo ''
\echo 'ALL upgrade_patch_4_2_legacy_returns.test.sql ASSERTIONS PASSED (Section 1 requires_sale_refresh remediation path A, Section 2 legacy financial backfill B/C)'
