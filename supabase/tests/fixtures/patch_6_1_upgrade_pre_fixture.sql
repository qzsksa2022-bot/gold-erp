-- ============================================================================
-- Patch 6.1 item 35 — PRE-upgrade fixture. Runs against a database that has
-- ONLY migrations 0001-0143 + the real supabase/seed.sql applied (i.e.
-- BEFORE any Patch 6.1 migration, 0144+, exists). Creates real data using
-- the OLD (pre-Patch-6.1) RPC contracts exactly as a real production
-- database running Phase 6 Core alone would have — including reproducing
-- the two genuine pre-Patch-6.1 bugs (items 9/10 and the missing reversal-
-- impact columns, item 20) so the upcoming 0144+ migrations' backfill logic
-- has something real to prove itself against.
--
-- Fixtures created (all COMMITTED, not rolled back — this script's whole
-- point is to leave real pre-patch data behind for 0144+ to migrate):
--   1. Pending adjustment WITH direct_cost already set (old create_sales_
--      order_adjustment() accepted direct_cost as an ordinary parameter,
--      with NO adjustments.manage_cost gating at all).
--   2. Approved PAID adjustment (visa, 2.5%/0 fixed) — ordinary case.
--   3. Approved ZERO-CHARGE adjustment using a NEW payment method carrying a
--      non-zero FIXED fee (2%/5.00) — reproduces the exact item-9 bug: a
--      free service (customer_charge=0) with a real, non-zero resolved fee
--      (5.00) baked into its approved snapshot. 0144's backfill must
--      deterministically zero this out and recompute net_adjustment_profit.
--   4. Approved-then-REVERSED adjustment, reversed via the OLD 0141 RPC —
--      the sales_order_adjustment_reversals row this creates predates the
--      five new signed impact columns (0150) entirely; 0150's own backfill
--      must populate them correctly from the existing snapshot columns.
--   5. Approved adjustment using a type that is RENAMED immediately
--      afterward (still under the OLD schema) — proves the historical
--      snapshot survives not just live RPC calls (already proven in
--      adjustments_core_phase6.test.sql's item 25) but the SCHEMA
--      MIGRATION itself.
--   6. Hotfix 6.1.1 item 2 — REJECTED zero-charge adjustment, created under
--      the OLD contract (customer_charge=0 was already legal pre-0144, but
--      payment_method_id/collection_channel_id were still NOT NULL then, so
--      a real legacy free-service row could easily carry a non-null
--      payment method/channel) and then rejected via the OLD reject RPC —
--      reproduces exactly the gap 0144's original draft missed (only
--      pending/approved zero-charge rows were normalized, never rejected
--      ones), which would otherwise make 0144 ITSELF fail applying its own
--      new zero-charge CHECK constraint against this exact row shape.
--
-- Results are recorded in a PERMANENT (non-temp) scratch table so they
-- survive into the separate psql invocation that applies 0144+ and the
-- separate psql invocation that runs the actual assertions.
-- ============================================================================

create table if not exists public.p6u61_scratch (label text primary key, value text);

insert into auth.users (id, email) values
  ('a6300000-0000-4000-8000-000000000001', 'test-p6u61-admin@example.invalid')
  on conflict do nothing;

update public.profiles set full_name = 'P6U61 Upgrade Fixture Admin', status = 'active', store_access_scope = 'all'
  where id = 'a6300000-0000-4000-8000-000000000001';

insert into public.user_roles (user_id, role_id)
  select 'a6300000-0000-4000-8000-000000000001', id from public.roles where key = 'super_admin'
  on conflict do nothing;

-- NOTE: this script is deliberately NOT wrapped in begin/rollback (its data
-- must be COMMITTED, not rolled back) and psql runs each top-level statement
-- in its own implicit transaction, so SET LOCAL (transaction-scoped) cannot
-- be used here — plain SET (session-scoped) is used instead, exactly like
-- `set role` below.
set role authenticated;
set request.jwt.claims = '{"sub":"a6300000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid;
  v_channel_id uuid; v_pm_cash uuid; v_pm_visa uuid; v_pm_fixed uuid;
  v_order_id uuid; v_order_number text; v_result record;
  v_type_a uuid; v_type_b uuid; v_type_c uuid; v_type_d uuid; v_type_e uuid;
  v_adj_pending uuid; v_adj_pending_number text;
  v_adj_paid uuid; v_adj_paid_number text; v_rv bigint; v_net text;
  v_adj_free uuid; v_adj_free_number text;
  v_adj_reversed uuid; v_adj_reversed_number text; v_reversal_id uuid;
  v_adj_renamed uuid; v_adj_renamed_number text;
  v_type_f uuid;
  v_adj_rejfree uuid; v_adj_rejfree_number text;
begin
  insert into public.stores (code, name_ar, status) values ('P6U61ST', 'فرع ترقية 6.1', 'active') returning id into v_store_id;
  insert into public.karats (code, name_ar, sort_order, status) values ('P6U61K', 'عيار ترقية 6.1', 993, 'active') returning id into v_karat_id;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('p6u61cat', 'تصنيف ترقية 6.1', 993, 'active') returning id into v_category_id;
  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 280.0000, 'a6300000-0000-4000-8000-000000000001');
  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, public.business_today(), 'p6u61 fixture');

  select id into v_channel_id from public.collection_channels where key = 'direct_store';
  select id into v_pm_cash from public.payment_methods where key = 'cash';
  select id into v_pm_visa from public.payment_methods where key = 'visa';

  -- A NEW payment method carrying a non-zero FIXED fee — none of the seeded
  -- methods do (all seeded fee versions are 0-fixed), so this is required
  -- to genuinely reproduce the item-9 bug (a non-zero fee on a free
  -- service) rather than trivially computing 0 x anything = 0.
  insert into public.payment_methods (key, name_ar, name_en, fee_model, refund_fee_policy, sort_order, status)
    values ('p6u61_fixedfee', 'دفع ثابت — ترقية 6.1', 'P6U61 Fixed Fee', 'percentage_plus_fixed', 'manual', 950, 'active')
    returning id into v_pm_fixed;
  perform public.create_payment_method_fee_version(v_pm_fixed, 2.0, 5.00, public.business_today(), 'p6u61 fixture — non-zero fixed fee');

  select * into v_result from create_sales_order(
    v_store_id, public.business_today(), v_pm_cash, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 4.0, 'sale_price', 1600.00)),
    'عميل ترقية 6.1'
  );
  v_order_id := v_result.id;
  v_order_number := v_result.order_number;
  insert into p6u61_scratch values ('order_id', v_order_id::text);
  insert into p6u61_scratch values ('order_number', v_order_number);

  select create_adjustment_type('p6u61_t_pending', 'نوع ترقية 6.1 — قيد الانتظار') into v_type_a;
  select create_adjustment_type('p6u61_t_paid', 'نوع ترقية 6.1 — مدفوع') into v_type_b;
  select create_adjustment_type('p6u61_t_free', 'نوع ترقية 6.1 — مجاني') into v_type_c;
  select create_adjustment_type('p6u61_t_reversed', 'نوع ترقية 6.1 — معكوس') into v_type_d;
  select create_adjustment_type('p6u61_t_renamed', 'نوع ترقية 6.1 — قبل إعادة التسمية') into v_type_e;
  select create_adjustment_type('p6u61_t_rejfree', 'نوع ترقية 6.1 — مرفوض مجاني') into v_type_f;

  -- 1) Pending adjustment WITH direct_cost already set (old, ungated RPC).
  select id, adjustment_number into v_adj_pending, v_adj_pending_number
  from create_sales_order_adjustment(
    v_order_id, v_type_a, v_store_id, public.business_today(), v_pm_cash, v_channel_id, true, 75.00, 22.50, 'P6U61 pending with cost', null
  );
  insert into p6u61_scratch values ('adj_pending_id', v_adj_pending::text);
  insert into p6u61_scratch values ('adj_pending_number', v_adj_pending_number);

  -- 2) Approved PAID adjustment (visa, 2.5%/0-fixed): charge=100/cost=30 ->
  -- fee=2.50/gross=70.00/net=67.50 — the SAME worked example used
  -- throughout the rest of this project's Adjustments test suites.
  select id, adjustment_number into v_adj_paid, v_adj_paid_number
  from create_sales_order_adjustment(
    v_order_id, v_type_b, v_store_id, public.business_today(), v_pm_visa, v_channel_id, true, 100.00, 30.00, 'P6U61 approved paid', null
  );
  select row_version into v_rv from get_sales_order_adjustment(v_adj_paid);
  select net_adjustment_profit, row_version into v_net, v_rv from approve_sales_order_adjustment(v_adj_paid, v_rv, null);
  assert v_net = '67.50', format('BUG fixture 2: expected net=67.50, got %s', v_net);
  insert into p6u61_scratch values ('adj_paid_id', v_adj_paid::text);
  insert into p6u61_scratch values ('adj_paid_number', v_adj_paid_number);

  -- 3) Approved ZERO-CHARGE adjustment using the fixed-fee payment method —
  -- reproduces the item-9 bug: fee = round(0 * 2/100 + 5.00, 2) = 5.00,
  -- gross = 0 - 10 = -10.00, net = -10.00 - 5.00 = -15.00 (WRONG, pre-patch
  -- value — 0144's backfill must correct this to fee=0.00/net=-10.00).
  select id, adjustment_number into v_adj_free, v_adj_free_number
  from create_sales_order_adjustment(
    v_order_id, v_type_c, v_store_id, public.business_today(), v_pm_fixed, v_channel_id, false, 0.00, 10.00, 'P6U61 approved free (pre-patch bug)', null
  );
  select row_version into v_rv from get_sales_order_adjustment(v_adj_free);
  select net_adjustment_profit, row_version into v_net, v_rv from approve_sales_order_adjustment(v_adj_free, v_rv, null);
  assert v_net = '-15.00', format('BUG fixture 3 setup: expected the PRE-PATCH buggy net=-15.00 (fee=5.00 on a free service), got %s — the reproduction itself failed, not the migration', v_net);
  insert into p6u61_scratch values ('adj_free_id', v_adj_free::text);
  insert into p6u61_scratch values ('adj_free_number', v_adj_free_number);

  -- 4) Approved-then-REVERSED adjustment (charge=50/cost=20, cash/0-fee):
  -- fee=0.00, gross=30.00, net=30.00. Reversed via the OLD 0141 RPC, whose
  -- INSERT predates the five signed impact columns entirely (0150's own job
  -- to backfill).
  select id, adjustment_number into v_adj_reversed, v_adj_reversed_number
  from create_sales_order_adjustment(
    v_order_id, v_type_d, v_store_id, public.business_today(), v_pm_cash, v_channel_id, true, 50.00, 20.00, 'P6U61 approved then reversed', null
  );
  select row_version into v_rv from get_sales_order_adjustment(v_adj_reversed);
  select net_adjustment_profit, row_version into v_net, v_rv from approve_sales_order_adjustment(v_adj_reversed, v_rv, null);
  assert v_net = '30.00', format('BUG fixture 4 setup: expected net=30.00 before reversal, got %s', v_net);
  select reversal_id into v_reversal_id from reverse_sales_order_adjustment(v_adj_reversed, v_rv, public.business_today(), 'P6U61 عكس قبل الترقية', null);
  insert into p6u61_scratch values ('adj_reversed_id', v_adj_reversed::text);
  insert into p6u61_scratch values ('adj_reversed_number', v_adj_reversed_number);
  insert into p6u61_scratch values ('reversal_id', v_reversal_id::text);

  -- 5) Approved adjustment using a type that is renamed AFTERWARD, entirely
  -- under the OLD schema — proves the historical snapshot survives the
  -- SCHEMA MIGRATION itself, not merely live RPC calls after the fact.
  select id, adjustment_number into v_adj_renamed, v_adj_renamed_number
  from create_sales_order_adjustment(
    v_order_id, v_type_e, v_store_id, public.business_today(), v_pm_cash, v_channel_id, true, 40.00, 5.00, 'P6U61 approved, type renamed after', null
  );
  select row_version into v_rv from get_sales_order_adjustment(v_adj_renamed);
  perform approve_sales_order_adjustment(v_adj_renamed, v_rv, null);
  perform update_adjustment_type(v_type_e, 'نوع ترقية 6.1 — بعد إعادة التسمية', null, null, 1);
  insert into p6u61_scratch values ('adj_renamed_id', v_adj_renamed::text);
  insert into p6u61_scratch values ('adj_renamed_number', v_adj_renamed_number);
  insert into p6u61_scratch values ('type_renamed_id', v_type_e::text);

  -- 6) REJECTED zero-charge adjustment — created under the OLD contract
  -- (customer_charge=0 legal pre-0144, but payment_method_id/
  -- collection_channel_id still NOT NULL then) then rejected via the OLD
  -- reject_sales_order_adjustment() RPC. A rejected row never carries a
  -- financial snapshot (only approval computes one), so nothing here should
  -- ever be recomputed by 0144 — only the operational payment fields need
  -- normalizing to NULL/false.
  select id, adjustment_number into v_adj_rejfree, v_adj_rejfree_number
  from create_sales_order_adjustment(
    v_order_id, v_type_f, v_store_id, public.business_today(), v_pm_cash, v_channel_id, false, 0.00, null, 'P6U61 rejected free (pre-patch legacy shape)', null
  );
  select row_version into v_rv from get_sales_order_adjustment(v_adj_rejfree);
  perform reject_sales_order_adjustment(v_adj_rejfree, v_rv, 'P6U61 رفض — سبب اختباري لترقية 6.1.1');
  insert into p6u61_scratch values ('adj_rejfree_id', v_adj_rejfree::text);
  insert into p6u61_scratch values ('adj_rejfree_number', v_adj_rejfree_number);

  raise notice 'P6U61 pre-upgrade fixtures created: pending=%, paid=%, free(buggy net=-15.00)=%, reversed=%, renamed-type=%, rejected-free(legacy shape)=%',
    v_adj_pending_number, v_adj_paid_number, v_adj_free_number, v_adj_reversed_number, v_adj_renamed_number, v_adj_rejfree_number;
end $$;

reset role;
reset request.jwt.claims;
