-- ============================================================================
-- Integration test: Phase 6 Final Audit & Invariant Hotfix 6.1.2 (0163-0166)
-- ============================================================================
-- Single-transaction, rolled-back-at-the-end regression test, mirroring
-- adjustments_core_phase6.test.sql's own convention exactly.
--
-- Prefix 'a6300000-...' is not used by any other test file's fixtures.
--
-- Covers, item-by-item:
--   §1 (item 2, BLOCKER) — sales_order_adjustments_calculation_version_
--     consistent (0163) rejects an approved row with calculation_version
--     other than 1, and rejects a non-approved row with a non-null
--     calculation_version. 4 cases: pending+1 (reject), approved+2 (reject),
--     approved+1 (valid), rejected+non-null (reject).
--   §2 (item 3, BLOCKER) — adjustment_types_enforce_updated_columns() (0164)
--     genuinely cannot be forged: (i) a trusted/direct write with no valid
--     user-auth actor present cannot move updated_by away from its previous
--     legitimate value, even when it explicitly supplies a different one;
--     (ii) a sanctioned RPC call under a real authenticated actor still
--     records the true actor. No test-only profile workaround of any kind
--     is used — the fixed trigger logic is exercised exactly as a real
--     service_role/direct-SQL write would hit it.
--   §3 (item 6, SQL-level proof) — the real, corrected reversal Payment Fee
--     sign: original_payment_fee_amount and reversal_payment_fee_impact are
--     both asserted explicitly and independently of Net/Direct Cost.
--   §4 (item 7) — the full adjustment.approve audit snapshot (0165) is
--     proven end-to-end (type/payment method/channel/fee snapshots, gross/
--     net/calculation_version/row_version), then Master Data is renamed and
--     the OLD audit entry is proven to retain its OLD (pre-rename) values —
--     the audit record itself is never mutated retroactively.
--
-- Requires migrations 0001-latest + supabase/seed.sql already applied.
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/adjustments_hotfix_6_1_2.test.sql
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0. Setup — one full-permission Primary actor, one narrower RPC actor (for
-- the updated_by sanctioned-RPC-still-records-real-actor proof), plus store/
-- karat/category/gold-price/mfg-fee/payment-method/collection-channel/sales-
-- order fixtures.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('a6300000-0000-4000-8000-000000000001', 'test-h612-primary@example.invalid'),
  ('a6300000-0000-4000-8000-000000000002', 'test-h612-typemanager@example.invalid');

update public.profiles set full_name = 'Test H6.1.2 Primary Actor', status = 'active', store_access_scope = 'all'
  where id = 'a6300000-0000-4000-8000-000000000001';
update public.profiles set full_name = 'Test H6.1.2 Type-Manager Actor', status = 'active', store_access_scope = 'all'
  where id = 'a6300000-0000-4000-8000-000000000002';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a6300000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in (
    'stores.view', 'stores.create',
    'karats.view', 'karats.manage', 'categories.view', 'categories.manage',
    'gold_prices.view', 'gold_prices.edit', 'manufacturing_fees.view', 'manufacturing_fees.manage',
    'payment_methods.view', 'payment_methods.manage', 'collection_channels.view', 'collection_channels.manage',
    'sales.create', 'sales.edit', 'sales.view', 'sales.view_profit',
    'adjustments.view', 'adjustments.create', 'adjustments.approve', 'adjustments.reverse',
    'adjustments.manage_cost', 'adjustments.manage_types', 'audit_logs.view'
  );

-- Deliberately adjustments.manage_types ONLY — used solely to prove a
-- sanctioned RPC call under a real authenticated actor still records the
-- true actor in updated_by (item 3's second required test case).
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a6300000-0000-4000-8000-000000000002', id, 'grant' from public.permissions
  where key in ('adjustments.manage_types');

set role authenticated;
set local request.jwt.claims = '{"sub":"a6300000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_store uuid;
  v_karat uuid;
  v_category uuid;
  v_pm uuid;
  v_channel uuid;
  v_result record;
begin
  insert into public.stores (code, name_ar, status) values ('H612-ST', 'فرع اختبار 6.1.2', 'active') returning id into v_store;
  perform set_config('h612.store', v_store::text, false);

  insert into public.karats (code, name_ar, sort_order, status) values ('H612K', 'عيار اختبار 6.1.2', 991, 'active') returning id into v_karat;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('h612cat', 'تصنيف اختبار 6.1.2', 991, 'active') returning id into v_category;
  perform set_config('h612.karat', v_karat::text, false);
  perform set_config('h612.category', v_category::text, false);

  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (current_date, v_karat, 300.0000, 'a6300000-0000-4000-8000-000000000001');
  perform public.create_manufacturing_fee_version(v_karat, 10.0000, current_date - 30, 'h6.1.2 fixture');

  -- Dedicated payment method / collection channel (not the seeded cash/
  -- visa/mada — this file renames them in §4, so a dedicated pair avoids
  -- ever touching shared seed data). percentage=10, fixed=2.50 -> on a
  -- customer_charge of 100.00: fee = round(100*10/100 + 2.50, 2) = 12.50,
  -- matching the spec's own worked example verbatim (item 6).
  insert into public.payment_methods (key, name_ar, fee_model, status)
    values ('h612_pm', 'طريقة دفع اختبار 6.1.2', 'percentage_plus_fixed', 'active') returning id into v_pm;
  insert into public.collection_channels (key, name_ar, status)
    values ('h612_ch', 'قناة تحصيل اختبار 6.1.2', 'active') returning id into v_channel;
  perform set_config('h612.pm', v_pm::text, false);
  perform set_config('h612.channel', v_channel::text, false);

  perform public.create_payment_method_fee_version(v_pm, 10.0000, 2.5000, current_date - 30, 'h6.1.2 fixture');

  select * into v_result from create_sales_order(
    v_store, current_date, v_pm, v_channel,
    jsonb_build_array(jsonb_build_object(
      'category_id', v_category, 'karat_id', v_karat, 'weight_grams', 5.0000, 'sale_price', 2000.00
    )),
    'عميل اختبار 6.1.2', '0500000099', null
  );
  perform set_config('h612.order_id', v_result.id::text, false);
end $$;

-- ---------------------------------------------------------------------------
-- §1 (item 2, BLOCKER) — calculation_version strict exact-value invariant
-- (0163). Uses a real approved row (created/approved through the sanctioned
-- RPCs, so its OTHER columns are all valid) and then, as the trusted table
-- owner, temporarily disables ONLY the terminal-mutation trigger (0154) —
-- exactly the same technique 0158's own backfill already uses — to isolate
-- and directly exercise the CHECK constraint itself against the 4 required
-- cases, without any other trigger's business rules interfering.
-- ---------------------------------------------------------------------------
do $$
declare
  v_type_id uuid;
  v_adj_id uuid;
  v_pending_id uuid;
  v_rejected_id uuid;
  v_result record;
  v_rejected boolean;
begin
  select create_adjustment_type('h612type', 'نوع اختبار 6.1.2', null, null, 1) into v_type_id;

  -- Fixture A: real APPROVED row.
  select * into v_result from create_sales_order_adjustment(
    current_setting('h612.order_id')::uuid, v_type_id, current_setting('h612.store')::uuid, current_date,
    current_setting('h612.pm')::uuid, current_setting('h612.channel')::uuid, false, 100.00, 20.00, null, null, null
  );
  v_adj_id := v_result.id;
  perform approve_sales_order_adjustment(v_adj_id, 1, null);

  if (select calculation_version from public.sales_order_adjustments where id = v_adj_id) <> 1 then
    raise exception 'FAIL setup: real approval did not land calculation_version=1';
  end if;
  raise notice 'PASS §1 case 3/4 (approved + calculation_version=1 -> VALID): real approval succeeded under the tightened 0163 constraint';

  -- Fixture B: a still-PENDING row (never approved) — used for case 1.
  select * into v_result from create_sales_order_adjustment(
    current_setting('h612.order_id')::uuid, v_type_id, current_setting('h612.store')::uuid, current_date,
    current_setting('h612.pm')::uuid, current_setting('h612.channel')::uuid, false, 50.00, 10.00, null, null, null
  );
  v_pending_id := v_result.id;

  -- Fixture C: a REJECTED row — used for case 4.
  select * into v_result from create_sales_order_adjustment(
    current_setting('h612.order_id')::uuid, v_type_id, current_setting('h612.store')::uuid, current_date,
    current_setting('h612.pm')::uuid, current_setting('h612.channel')::uuid, false, 30.00, 5.00, null, null, null
  );
  v_rejected_id := v_result.id;
  perform reject_sales_order_adjustment(v_rejected_id, 1, 'رفض لأغراض اختبار 6.1.2 §1');

  perform set_config('h612.adj_approved', v_adj_id::text, false);
  perform set_config('h612.adj_pending', v_pending_id::text, false);
  perform set_config('h612.adj_rejected', v_rejected_id::text, false);
end $$;

reset role;
reset request.jwt.claims;

alter table public.sales_order_adjustments disable trigger sales_order_adjustments_reject_terminal_mutation;

do $$
declare
  v_blocked boolean;
begin
  -- Case 1: pending + calculation_version = 1 -> REJECT.
  v_blocked := false;
  begin
    update public.sales_order_adjustments set calculation_version = 1 where id = current_setting('h612.adj_pending')::uuid;
  exception when check_violation then
    v_blocked := true;
  end;
  if not v_blocked then
    raise exception 'FAIL §1 case 1: pending row accepted calculation_version=1 -- constraint did not reject it';
  end if;
  raise notice 'PASS §1 case 1 (pending + calculation_version=1 -> REJECT)';

  -- Case 2: approved + calculation_version = 2 -> REJECT.
  v_blocked := false;
  begin
    update public.sales_order_adjustments set calculation_version = 2 where id = current_setting('h612.adj_approved')::uuid;
  exception when check_violation then
    v_blocked := true;
  end;
  if not v_blocked then
    raise exception 'FAIL §1 case 2: approved row accepted calculation_version=2 -- the exact-value invariant did not reject an invalid version';
  end if;
  if (select calculation_version from public.sales_order_adjustments where id = current_setting('h612.adj_approved')::uuid) <> 1 then
    raise exception 'FAIL §1 case 2: the rejected UPDATE nonetheless left calculation_version changed';
  end if;
  raise notice 'PASS §1 case 2 (approved + calculation_version=2 -> REJECT, the exact BLOCKER this migration closes)';

  -- Case 4: rejected + calculation_version non-null -> REJECT.
  v_blocked := false;
  begin
    update public.sales_order_adjustments set calculation_version = 1 where id = current_setting('h612.adj_rejected')::uuid;
  exception when check_violation then
    v_blocked := true;
  end;
  if not v_blocked then
    raise exception 'FAIL §1 case 4: rejected row accepted a non-null calculation_version';
  end if;
  raise notice 'PASS §1 case 4 (rejected + calculation_version non-null -> REJECT)';

  -- Explicit re-confirmation of case 3 at the raw-UPDATE level too (setting
  -- the SAME already-valid value must succeed, proving the constraint is
  -- exact-value, not merely "reject everything").
  update public.sales_order_adjustments set calculation_version = 1 where id = current_setting('h612.adj_approved')::uuid;
  raise notice 'PASS §1 case 3 re-confirmed at raw UPDATE level (approved + calculation_version=1 -> VALID)';
end $$;

alter table public.sales_order_adjustments enable trigger sales_order_adjustments_reject_terminal_mutation;

-- ---------------------------------------------------------------------------
-- §2 (item 3, BLOCKER) — adjustment_types.updated_by genuine anti-forgery
-- (0164). No test-only workaround: the trusted-write forgery attempt below
-- is a REAL direct UPDATE hitting the REAL corrected trigger, exactly as a
-- service_role/maintenance-context write would in production.
-- ---------------------------------------------------------------------------
set role authenticated;
set local request.jwt.claims = '{"sub":"a6300000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_type_id uuid;
begin
  select create_adjustment_type('h612forge', 'نوع اختبار تزوير 6.1.2', null, null, 1) into v_type_id;
  perform set_config('h612.forge_type', v_type_id::text, false);

  if (select updated_by from public.adjustment_types where id = v_type_id) <> 'a6300000-0000-4000-8000-000000000001' then
    raise exception 'FAIL setup: create_adjustment_type did not attribute updated_by to the creating actor';
  end if;
end $$;

-- (i) Trusted/direct-SQL write, NO valid user-auth actor present, attempts
-- to forge updated_by to a different (unrelated) UUID. Expected: updated_by
-- STAYS the original actor (a...001), never becomes the forged UUID.
reset role;
reset request.jwt.claims;

do $$
declare
  v_forged_target uuid := 'a6300000-0000-4000-8000-00000000feed';
  v_after uuid;
begin
  update public.adjustment_types
  set name_ar = 'نوع اختبار تزوير 6.1.2 (محاولة تزوير مباشرة)',
      updated_by = v_forged_target
  where id = current_setting('h612.forge_type')::uuid;

  select updated_by into v_after from public.adjustment_types where id = current_setting('h612.forge_type')::uuid;

  if v_after = v_forged_target then
    raise exception 'FAIL §2(i): a trusted/direct write with no valid actor FORGED updated_by to % -- anti-forgery hardening did not hold', v_forged_target;
  end if;
  if v_after <> 'a6300000-0000-4000-8000-000000000001' then
    raise exception 'FAIL §2(i): updated_by drifted to an unexpected value % (expected it to stay pinned to the original actor)', v_after;
  end if;
  raise notice 'PASS §2(i): trusted/direct write could NOT forge updated_by -- it stayed the original real actor, exactly as required';
end $$;

-- Bonus (not one of the two required cases, but a direct exercise of the
-- corrected trigger's OTHER disjunct): auth.uid() is NON-null but does not
-- identify any real profiles row (e.g. a stale/deleted-user token in a
-- service_role-adjacent context) -- must ALSO fail to forge, proving branch
-- (B) is "not a valid Actor Profile", not merely "auth.uid() is null".
do $$
declare
  v_nonexistent_actor uuid := 'a6300000-0000-4000-8000-0000000000fe';
  v_forged_target uuid := 'a6300000-0000-4000-8000-00000000face';
  v_after uuid;
begin
  if exists (select 1 from public.profiles where id = v_nonexistent_actor) then
    raise exception 'FAIL bonus setup: v_nonexistent_actor unexpectedly already exists as a real profile';
  end if;

  set local request.jwt.claims = '{"sub":"a6300000-0000-4000-8000-0000000000fe","role":"authenticated"}';

  update public.adjustment_types
  set name_ar = 'نوع اختبار تزوير 6.1.2 (auth.uid غير صالح)',
      updated_by = v_forged_target
  where id = current_setting('h612.forge_type')::uuid;

  select updated_by into v_after from public.adjustment_types where id = current_setting('h612.forge_type')::uuid;

  if v_after <> 'a6300000-0000-4000-8000-000000000001' then
    raise exception 'FAIL bonus: a non-existent-profile auth.uid() was still able to move updated_by away from the real original actor (got %)', v_after;
  end if;
  raise notice 'PASS bonus: auth.uid() not identifying a real profiles row is ALSO treated as no-valid-actor -- updated_by stayed pinned';
end $$;

reset request.jwt.claims;

-- (ii) Sanctioned RPC call from a real, distinct authenticated actor (002,
-- adjustments.manage_types only) -- updated_by MUST become that real actor.
set role authenticated;
set local request.jwt.claims = '{"sub":"a6300000-0000-4000-8000-000000000002","role":"authenticated"}';

do $$
declare
  v_after uuid;
begin
  perform update_adjustment_type(current_setting('h612.forge_type')::uuid, 'نوع اختبار تزوير 6.1.2 (RPC صحيح)', null, null, 1);

  select updated_by into v_after from public.adjustment_types where id = current_setting('h612.forge_type')::uuid;

  if v_after <> 'a6300000-0000-4000-8000-000000000002' then
    raise exception 'FAIL §2(ii): sanctioned update_adjustment_type() RPC did not record the real acting user (got %)', v_after;
  end if;
  raise notice 'PASS §2(ii): sanctioned RPC call under a real authenticated actor correctly recorded that actor in updated_by';
end $$;

reset request.jwt.claims;
set role authenticated;
set local request.jwt.claims = '{"sub":"a6300000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- §3 (item 6) — real, corrected reversal Payment Fee sign proof: BOTH the
-- original fee and the reversal impact are asserted explicitly (not merely
-- implied by Net/Direct Cost checks).
-- ---------------------------------------------------------------------------
do $$
declare
  v_type_id uuid;
  v_result record;
  v_adj_id uuid;
  v_row record;
begin
  select create_adjustment_type('h612feetype', 'نوع رسوم اختبار 6.1.2', null, null, 1) into v_type_id;

  select * into v_result from create_sales_order_adjustment(
    current_setting('h612.order_id')::uuid, v_type_id, current_setting('h612.store')::uuid, current_date,
    current_setting('h612.pm')::uuid, current_setting('h612.channel')::uuid, false, 100.00, 20.00, null, null, null
  );
  v_adj_id := v_result.id;
  perform approve_sales_order_adjustment(v_adj_id, 1, null);

  select * into v_row from get_sales_order_adjustment(v_adj_id);
  if v_row.original_payment_fee_amount <> '12.50' then
    raise exception 'FAIL §3 setup: expected original_payment_fee_amount=12.50, got %', v_row.original_payment_fee_amount;
  end if;

  perform reverse_sales_order_adjustment(v_adj_id, 2, current_date, 'عكس لأغراض اختبار 6.1.2 §3', null);

  select * into v_row from get_sales_order_adjustment(v_adj_id);

  if v_row.original_payment_fee_amount <> '12.50' then
    raise exception 'FAIL §3: original_payment_fee_amount must remain 12.50 after reversal (original facts never mutate), got %', v_row.original_payment_fee_amount;
  end if;
  if v_row.reversal_payment_fee_impact <> '12.50' then
    raise exception 'FAIL §3 (item 6 -- the exact bug being fixed): expected reversal_payment_fee_impact = +12.50 (POSITIVE, per the 0150 DB contract: payment_fee_reversal_amount = +payment_fee_amount_snapshot), got %', v_row.reversal_payment_fee_impact;
  end if;
  raise notice 'PASS §3: original_payment_fee_amount=12.50 AND reversal_payment_fee_impact=+12.50, asserted independently of Net/Direct Cost';

  perform set_config('h612.fee_adj_id', v_adj_id::text, false);
end $$;

-- ---------------------------------------------------------------------------
-- §4 (item 7) — full adjustment.approve audit snapshot, then rename Master
-- Data and prove the OLD audit entry's OLD values are untouched.
-- ---------------------------------------------------------------------------
do $$
declare
  v_type_id uuid;
  v_result record;
  v_adj_id uuid;
  v_audit record;
begin
  select create_adjustment_type('h612audtype', 'نوع تدقيق اختبار 6.1.2', null, null, 1) into v_type_id;
  perform set_config('h612.audit_type', v_type_id::text, false);

  select * into v_result from create_sales_order_adjustment(
    current_setting('h612.order_id')::uuid, v_type_id, current_setting('h612.store')::uuid, current_date,
    current_setting('h612.pm')::uuid, current_setting('h612.channel')::uuid, false, 100.00, 20.00, null, null, null
  );
  v_adj_id := v_result.id;
  perform set_config('h612.audit_adj', v_adj_id::text, false);
  perform approve_sales_order_adjustment(v_adj_id, 1, null);

  select * into v_audit from public.audit_logs
    where action = 'adjustment.approve' and entity_type = 'sales_order_adjustment' and entity_id = v_adj_id;

  if not found then
    raise exception 'FAIL §4: no adjustment.approve audit row found';
  end if;

  if v_audit.new_values ->> 'adjustment_type_id' <> v_type_id::text then
    raise exception 'FAIL §4: new_values.adjustment_type_id missing/wrong (got %)', v_audit.new_values ->> 'adjustment_type_id';
  end if;
  if v_audit.new_values ->> 'adjustment_type_code_snapshot' <> 'h612audtype' then
    raise exception 'FAIL §4: new_values.adjustment_type_code_snapshot missing/wrong (got %)', v_audit.new_values ->> 'adjustment_type_code_snapshot';
  end if;
  if v_audit.new_values ->> 'adjustment_type_name_ar_snapshot' <> 'نوع تدقيق اختبار 6.1.2' then
    raise exception 'FAIL §4: new_values.adjustment_type_name_ar_snapshot missing/wrong (got %)', v_audit.new_values ->> 'adjustment_type_name_ar_snapshot';
  end if;
  if v_audit.new_values ->> 'payment_method_id' <> current_setting('h612.pm') then
    raise exception 'FAIL §4: new_values.payment_method_id missing/wrong';
  end if;
  if v_audit.new_values ->> 'payment_method_name_snapshot' <> 'طريقة دفع اختبار 6.1.2' then
    raise exception 'FAIL §4: new_values.payment_method_name_snapshot missing/wrong (got %)', v_audit.new_values ->> 'payment_method_name_snapshot';
  end if;
  if v_audit.new_values ->> 'collection_channel_id' <> current_setting('h612.channel') then
    raise exception 'FAIL §4: new_values.collection_channel_id missing/wrong';
  end if;
  if v_audit.new_values ->> 'collection_channel_name_snapshot' <> 'قناة تحصيل اختبار 6.1.2' then
    raise exception 'FAIL §4: new_values.collection_channel_name_snapshot missing/wrong (got %)', v_audit.new_values ->> 'collection_channel_name_snapshot';
  end if;
  if v_audit.new_values ->> 'payment_fee_version_id' is null then
    raise exception 'FAIL §4: new_values.payment_fee_version_id missing';
  end if;
  if (v_audit.new_values ->> 'payment_fee_percentage_snapshot')::numeric <> 10.0000 then
    raise exception 'FAIL §4: new_values.payment_fee_percentage_snapshot missing/wrong (got %)', v_audit.new_values ->> 'payment_fee_percentage_snapshot';
  end if;
  if (v_audit.new_values ->> 'payment_fee_fixed_snapshot')::numeric <> 2.5000 then
    raise exception 'FAIL §4: new_values.payment_fee_fixed_snapshot missing/wrong (got %)', v_audit.new_values ->> 'payment_fee_fixed_snapshot';
  end if;
  if (v_audit.new_values ->> 'customer_charge')::numeric <> 100.00 then
    raise exception 'FAIL §4: new_values.customer_charge missing/wrong';
  end if;
  if (v_audit.new_values ->> 'direct_cost')::numeric <> 20.00 then
    raise exception 'FAIL §4: new_values.direct_cost missing/wrong';
  end if;
  if (v_audit.new_values ->> 'payment_fee_amount')::numeric <> 12.50 then
    raise exception 'FAIL §4: new_values.payment_fee_amount missing/wrong';
  end if;
  if (v_audit.new_values ->> 'gross_adjustment_profit')::numeric <> 80.00 then
    raise exception 'FAIL §4: new_values.gross_adjustment_profit missing/wrong';
  end if;
  if (v_audit.new_values ->> 'net_adjustment_profit')::numeric <> 67.50 then
    raise exception 'FAIL §4: new_values.net_adjustment_profit missing/wrong';
  end if;
  if (v_audit.new_values ->> 'calculation_version')::integer <> 1 then
    raise exception 'FAIL §4: new_values.calculation_version missing/wrong';
  end if;
  if v_audit.new_values ->> 'row_version' is null then
    raise exception 'FAIL §4: new_values.row_version missing';
  end if;
  if (v_audit.new_values ->> 'is_free_service')::boolean <> false then
    raise exception 'FAIL §4: new_values.is_free_service missing/wrong';
  end if;

  raise notice 'PASS §4 (part 1/2): adjustment.approve audit entry carries the full financial/master snapshot pinned at approval time';
end $$;

-- Rename the Adjustment Type, the Payment Method, and the Collection
-- Channel used above -- all AFTER the audit entry already exists.
do $$
begin
  perform update_adjustment_type(current_setting('h612.audit_type')::uuid, 'نوع تدقيق اختبار 6.1.2 (بعد إعادة التسمية)', null, null, 1);

  update public.payment_methods set name_ar = 'طريقة دفع اختبار 6.1.2 (بعد إعادة التسمية)'
    where id = current_setting('h612.pm')::uuid;

  update public.collection_channels set name_ar = 'قناة تحصيل اختبار 6.1.2 (بعد إعادة التسمية)'
    where id = current_setting('h612.channel')::uuid;
end $$;

do $$
declare
  v_audit record;
  v_live_type_name text;
  v_live_pm_name text;
  v_live_channel_name text;
begin
  select name_ar into v_live_type_name from public.adjustment_types where id = current_setting('h612.audit_type')::uuid;
  select name_ar into v_live_pm_name from public.payment_methods where id = current_setting('h612.pm')::uuid;
  select name_ar into v_live_channel_name from public.collection_channels where id = current_setting('h612.channel')::uuid;

  if v_live_type_name <> 'نوع تدقيق اختبار 6.1.2 (بعد إعادة التسمية)'
     or v_live_pm_name <> 'طريقة دفع اختبار 6.1.2 (بعد إعادة التسمية)'
     or v_live_channel_name <> 'قناة تحصيل اختبار 6.1.2 (بعد إعادة التسمية)' then
    raise exception 'FAIL §4 setup: the rename(s) did not actually take effect on the live Master Data rows';
  end if;

  select * into v_audit from public.audit_logs
    where action = 'adjustment.approve' and entity_type = 'sales_order_adjustment'
      and entity_id = current_setting('h612.audit_adj')::uuid;

  if v_audit.new_values ->> 'adjustment_type_name_ar_snapshot' <> 'نوع تدقيق اختبار 6.1.2' then
    raise exception 'FAIL §4 (item 7 core claim): the OLD audit entry''s adjustment_type_name_ar_snapshot changed after the rename -- got %, expected the ORIGINAL pre-rename value', v_audit.new_values ->> 'adjustment_type_name_ar_snapshot';
  end if;
  if v_audit.new_values ->> 'payment_method_name_snapshot' <> 'طريقة دفع اختبار 6.1.2' then
    raise exception 'FAIL §4 (item 7 core claim): the OLD audit entry''s payment_method_name_snapshot changed after the rename -- got %', v_audit.new_values ->> 'payment_method_name_snapshot';
  end if;
  if v_audit.new_values ->> 'collection_channel_name_snapshot' <> 'قناة تحصيل اختبار 6.1.2' then
    raise exception 'FAIL §4 (item 7 core claim): the OLD audit entry''s collection_channel_name_snapshot changed after the rename -- got %', v_audit.new_values ->> 'collection_channel_name_snapshot';
  end if;

  raise notice 'PASS §4 (part 2/2): after renaming type/payment method/channel, the OLD adjustment.approve audit entry still holds its OLD (pre-rename) snapshot values -- the audit record itself is never mutated retroactively';
end $$;

reset role;
reset request.jwt.claims;

rollback;
