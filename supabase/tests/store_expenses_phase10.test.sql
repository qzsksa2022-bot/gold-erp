-- ============================================================================
-- Integration test: Phase 10 — Store Expenses Core (0233-0236)
-- ============================================================================
-- Single-transaction, rolled-back-at-the-end regression test, mirroring
-- inventory_core_phase9.test.sql's convention exactly.
--
-- Prefix 'aa000000-...' is not used by any other test file's fixtures.
--
--   01 = full actor (expenses.view + create + reverse + manage_categories),
--        store_access_scope='all'
--   02 = expenses.view ONLY
--   03 = expenses.create ONLY (no view, no reverse)
--   04 = expenses.reverse ONLY (no view, no create)
--   05 = view+create+reverse, but store_access_scope='single' -> Store B only
--   06 = full expenses actor PLUS expenses.process_closed_day
--
-- Requires migrations 0001-latest + supabase/seed.sql already applied.
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/store_expenses_phase10.test.sql
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0. Setup — actors, two stores, categories.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('aa000000-0000-4000-8000-000000000001', 'test-p10-full@example.invalid'),
  ('aa000000-0000-4000-8000-000000000002', 'test-p10-viewonly@example.invalid'),
  ('aa000000-0000-4000-8000-000000000003', 'test-p10-createonly@example.invalid'),
  ('aa000000-0000-4000-8000-000000000004', 'test-p10-reverseonly@example.invalid'),
  ('aa000000-0000-4000-8000-000000000005', 'test-p10-storebonly@example.invalid'),
  ('aa000000-0000-4000-8000-000000000006', 'test-p10-closedday@example.invalid');

update public.profiles set full_name = 'Test P10 Full', status = 'active', store_access_scope = 'all' where id = 'aa000000-0000-4000-8000-000000000001';
update public.profiles set full_name = 'Test P10 View Only', status = 'active', store_access_scope = 'all' where id = 'aa000000-0000-4000-8000-000000000002';
update public.profiles set full_name = 'Test P10 Create Only', status = 'active', store_access_scope = 'all' where id = 'aa000000-0000-4000-8000-000000000003';
update public.profiles set full_name = 'Test P10 Reverse Only', status = 'active', store_access_scope = 'all' where id = 'aa000000-0000-4000-8000-000000000004';
update public.profiles set full_name = 'Test P10 Store-B Only', status = 'active', store_access_scope = 'all' where id = 'aa000000-0000-4000-8000-000000000005';
update public.profiles set full_name = 'Test P10 Closed Day', status = 'active', store_access_scope = 'all' where id = 'aa000000-0000-4000-8000-000000000006';

-- `stores.create` is required by 0010's stores_insert RLS policy (the fixture
-- creates its own stores as `authenticated`); `audit_logs.view` by 0010/0187's
-- audit_logs_select policy (section 8 asserts the audit trail); `sales.close_day`
-- by close_sales_day() (section 7).
-- The dashboard.* / *.view_profit / *.view_financials keys are needed by
-- section 10: get_dashboard_summary() gates the whole net_operating_return
-- section behind them, and without it the backward-compatibility assertion
-- would compare NULL to NULL and prove nothing.
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'aa000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in ('stores.view', 'stores.create', 'audit_logs.view', 'sales.close_day',
                'dashboard.view', 'dashboard.view_financials',
                'sales.view', 'sales.view_profit', 'returns.view', 'shipments.view',
                'adjustments.view', 'settlements.view', 'settlements.view_financials',
                'expenses.view', 'expenses.create', 'expenses.reverse', 'expenses.manage_categories');

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'aa000000-0000-4000-8000-000000000002', id, 'grant' from public.permissions where key in ('expenses.view');

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'aa000000-0000-4000-8000-000000000003', id, 'grant' from public.permissions where key in ('expenses.create');

-- Actor 004 deliberately gets the FULL dashboard financial permission set but
-- NO expenses.view — it is the §79 privacy probe in section 10: it must still
-- see net_operating_return, and must NOT see any Phase 10 key.
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'aa000000-0000-4000-8000-000000000004', id, 'grant' from public.permissions
  where key in ('expenses.reverse',
                'dashboard.view', 'dashboard.view_financials',
                'sales.view', 'sales.view_profit', 'returns.view', 'shipments.view',
                'adjustments.view', 'settlements.view', 'settlements.view_financials');

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'aa000000-0000-4000-8000-000000000005', id, 'grant' from public.permissions
  where key in ('expenses.view', 'expenses.create', 'expenses.reverse');

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'aa000000-0000-4000-8000-000000000006', id, 'grant' from public.permissions
  where key in ('expenses.view', 'expenses.create', 'expenses.reverse', 'expenses.process_closed_day', 'sales.close_day');

set role authenticated;
set local request.jwt.claims = '{"sub":"aa000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_store_a uuid;
  v_store_b uuid;
begin
  insert into public.stores (code, name_ar, status) values ('P10-STA', 'فرع مصروفات أ', 'active') returning id into v_store_a;
  insert into public.stores (code, name_ar, status) values ('P10-STB', 'فرع مصروفات ب', 'active') returning id into v_store_b;
  perform set_config('p10.store_a', v_store_a::text, false);
  perform set_config('p10.store_b', v_store_b::text, false);
end;
$$;

-- Store-scoping actor 005 must NOT happen as `authenticated`: 0010's
-- profiles_update policy requires users.edit/users.disable, which this
-- deliberately expenses-only actor does not hold. An UPDATE blocked by RLS
-- does not raise — it silently matches zero rows, leaving actor 005 at scope
-- 'all' and making every cross-store assertion below pass vacuously. Done as
-- the session superuser instead (the exact silent no-op that had to be fixed
-- in inventory_core_phase9.test.sql).
reset role;
reset request.jwt.claims;

update public.profiles
   set store_access_scope = 'single', default_store_id = current_setting('p10.store_b')::uuid
 where id = 'aa000000-0000-4000-8000-000000000005';

do $$
declare
  v_scope text;
  v_default uuid;
begin
  select store_access_scope, default_store_id into v_scope, v_default
  from public.profiles where id = 'aa000000-0000-4000-8000-000000000005';
  if v_scope <> 'single' or v_default is distinct from current_setting('p10.store_b')::uuid then
    raise exception 'TEST FAILED: fixture did not store-scope actor 005 to Store B (scope=%, default_store_id=%)', v_scope, v_default;
  end if;
end;
$$;

set role authenticated;
set local request.jwt.claims = '{"sub":"aa000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- 1. create_expense_category() — permission boundary + validation.
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"aa000000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$
begin
  begin
    perform public.create_expense_category('P10-RENT', 'إيجار');
    raise exception 'TEST FAILED: view-only actor created an expense category';
  exception when others then
    if sqlerrm not like '%صلاحية%' then raise; end if;
  end;
end;
$$;

set local request.jwt.claims = '{"sub":"aa000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_id uuid;
  v_code text;
begin
  select id, code into v_id, v_code from public.create_expense_category('P10-RENT', 'إيجار الفرع', 'Store rent', 'إيجار شهري');
  if v_id is null or v_code <> 'P10-RENT' then
    raise exception 'TEST FAILED: create_expense_category did not return the expected row';
  end if;
  perform set_config('p10.cat_rent', v_id::text, false);

  select id into v_id from public.create_expense_category('P10-UTIL', 'كهرباء وماء');
  perform set_config('p10.cat_util', v_id::text, false);

  -- Case-insensitive duplicate rejected.
  begin
    perform public.create_expense_category('p10-rent', 'إيجار مكرر');
    raise exception 'TEST FAILED: a duplicate (case-insensitive) category code was accepted';
  exception when others then
    if sqlerrm not like '%مستخدم بالفعل%' then raise; end if;
  end;

  -- Blank name rejected.
  begin
    perform public.create_expense_category('P10-X', '   ');
    raise exception 'TEST FAILED: a blank category name was accepted';
  exception when others then
    if sqlerrm not like '%مطلوب%' then raise; end if;
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. record_store_expense() — permission, validation, store scope.
-- ---------------------------------------------------------------------------

-- view-only actor cannot record.
set local request.jwt.claims = '{"sub":"aa000000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$
begin
  begin
    perform public.record_store_expense(current_setting('p10.store_a')::uuid, current_setting('p10.cat_rent')::uuid, 500);
    raise exception 'TEST FAILED: view-only actor recorded an expense';
  exception when others then
    if sqlerrm not like '%صلاحية%' then raise; end if;
  end;
end;
$$;

-- create-only actor CAN record (and needs no view permission to do so).
set local request.jwt.claims = '{"sub":"aa000000-0000-4000-8000-000000000003","role":"authenticated"}';
do $$
declare
  v_amount text;
  v_number text;
  v_id uuid;
begin
  select id, expense_number, amount into v_id, v_number, v_amount
  from public.record_store_expense(current_setting('p10.store_a')::uuid, current_setting('p10.cat_rent')::uuid, 1500, current_date - 3, 'إيجار سبتمبر');

  -- Money is returned as TEXT at the column's own numeric(14,2) scale.
  if v_amount <> '1500.00' then
    raise exception 'TEST FAILED: expected amount=1500.00 (text, 2dp), got %', v_amount;
  end if;
  if v_number !~ '^EXP-[0-9]{10}$' then
    raise exception 'TEST FAILED: expense number format is wrong: %', v_number;
  end if;
  perform set_config('p10.exp_1', v_id::text, false);
end;
$$;

set local request.jwt.claims = '{"sub":"aa000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
begin
  -- Zero / negative amount rejected.
  begin
    perform public.record_store_expense(current_setting('p10.store_a')::uuid, current_setting('p10.cat_rent')::uuid, 0);
    raise exception 'TEST FAILED: a zero expense amount was accepted';
  exception when others then
    if sqlerrm not like '%موجب%' then raise; end if;
  end;

  begin
    perform public.record_store_expense(current_setting('p10.store_a')::uuid, current_setting('p10.cat_rent')::uuid, -10);
    raise exception 'TEST FAILED: a negative expense amount was accepted';
  exception when others then
    if sqlerrm not like '%موجب%' then raise; end if;
  end;

  -- More than 2 decimal places rejected (§21 money-scale contract).
  begin
    perform public.record_store_expense(current_setting('p10.store_a')::uuid, current_setting('p10.cat_rent')::uuid, 10.123);
    raise exception 'TEST FAILED: an amount with 3 decimal places was accepted';
  exception when others then
    if sqlerrm not like '%عشريين%' then raise; end if;
  end;

  -- Future business date rejected.
  begin
    perform public.record_store_expense(current_setting('p10.store_a')::uuid, current_setting('p10.cat_rent')::uuid, 10, public.business_today() + 1);
    raise exception 'TEST FAILED: a future-dated expense was accepted';
  exception when others then
    if sqlerrm not like '%مستقبلي%' then raise; end if;
  end;
end;
$$;

-- Store-B-only actor cannot record at Store A (not in their operable set).
set local request.jwt.claims = '{"sub":"aa000000-0000-4000-8000-000000000005","role":"authenticated"}';
do $$
begin
  begin
    perform public.record_store_expense(current_setting('p10.store_a')::uuid, current_setting('p10.cat_rent')::uuid, 100);
    raise exception 'TEST FAILED: Store-B-only actor recorded an expense at Store A';
  exception when others then
    if sqlerrm not like '%الفرع%' then raise; end if;
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Category lifecycle — a disabled category cannot be used.
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"aa000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
begin
  perform public.disable_expense_category(current_setting('p10.cat_util')::uuid);

  begin
    perform public.record_store_expense(current_setting('p10.store_a')::uuid, current_setting('p10.cat_util')::uuid, 50);
    raise exception 'TEST FAILED: an expense was recorded against a DISABLED category';
  exception when others then
    if sqlerrm not like '%غير نشط%' then raise; end if;
  end;

  perform public.enable_expense_category(current_setting('p10.cat_util')::uuid);
  perform public.record_store_expense(current_setting('p10.store_a')::uuid, current_setting('p10.cat_util')::uuid, 50, current_date - 2, 'فاتورة كهرباء');
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. update_expense_category() — optimistic concurrency.
-- ---------------------------------------------------------------------------
reset role;
reset request.jwt.claims;
select set_config('p10.cat_rent_version', (select row_version::text from public.expense_categories where id = current_setting('p10.cat_rent')::uuid), false);
set role authenticated;
set local request.jwt.claims = '{"sub":"aa000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_version bigint := current_setting('p10.cat_rent_version')::bigint;
begin
  if v_version is null then
    raise exception 'TEST FAILED: fixture did not capture cat_rent row_version';
  end if;

  -- Stale version rejected.
  begin
    perform public.update_expense_category(current_setting('p10.cat_rent')::uuid, v_version - 1, 'إيجار محدث');
    raise exception 'TEST FAILED: a stale row_version was accepted by update_expense_category';
  exception when others then
    if sqlerrm not like '%مستخدم آخر%' then raise; end if;
  end;

  -- NULL version rejected outright — `row_version <> NULL` is NULL, which
  -- would silently bypass the whole check.
  begin
    perform public.update_expense_category(current_setting('p10.cat_rent')::uuid, null, 'إيجار محدث');
    raise exception 'TEST FAILED: a NULL expected row_version bypassed the optimistic-concurrency check';
  exception when others then
    if sqlerrm not like '%رقم إصدار%' then raise; end if;
  end;

  perform public.update_expense_category(current_setting('p10.cat_rent')::uuid, v_version, 'إيجار الفرع (محدث)');
end;
$$;

reset role;
reset request.jwt.claims;
do $$
declare
  v_expected bigint := current_setting('p10.cat_rent_version')::bigint + 1;
  v_actual bigint;
  v_name text;
begin
  select row_version, name_ar into v_actual, v_name from public.expense_categories where id = current_setting('p10.cat_rent')::uuid;
  if v_actual is distinct from v_expected then
    raise exception 'TEST FAILED: row_version did not increment (expected %, got %)', v_expected, v_actual;
  end if;
  if v_name <> 'إيجار الفرع (محدث)' then
    raise exception 'TEST FAILED: category name was not updated, got %', v_name;
  end if;
end;
$$;
set role authenticated;

-- ---------------------------------------------------------------------------
-- 5. reverse_store_expense() — the ONLY correction path.
-- ---------------------------------------------------------------------------

-- create-only actor cannot reverse.
set local request.jwt.claims = '{"sub":"aa000000-0000-4000-8000-000000000003","role":"authenticated"}';
do $$
begin
  begin
    perform public.reverse_store_expense(current_setting('p10.exp_1')::uuid, 'محاولة غير مصرح بها');
    raise exception 'TEST FAILED: create-only actor reversed an expense';
  exception when others then
    if sqlerrm not like '%صلاحية%' then raise; end if;
  end;
end;
$$;

set local request.jwt.claims = '{"sub":"aa000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_amount text;
  v_id uuid;
begin
  -- Mandatory reason.
  begin
    perform public.reverse_store_expense(current_setting('p10.exp_1')::uuid, '   ');
    raise exception 'TEST FAILED: a reversal with a blank reason was accepted';
  exception when others then
    if sqlerrm not like '%سبب%' then raise; end if;
  end;

  -- A reversal dated BEFORE the original is rejected (§85 sanity).
  begin
    perform public.reverse_store_expense(current_setting('p10.exp_1')::uuid, 'تاريخ غير صالح', current_date - 10);
    raise exception 'TEST FAILED: a reversal dated before the original expense was accepted';
  exception when others then
    if sqlerrm not like '%يسبق%' then raise; end if;
  end;

  select id, amount into v_id, v_amount
  from public.reverse_store_expense(current_setting('p10.exp_1')::uuid, 'دفعة مكررة بالخطأ', current_date - 1);

  -- The reversal is a NEGATIVE entry, carrying its OWN business date.
  if v_amount <> '-1500.00' then
    raise exception 'TEST FAILED: expected reversal amount=-1500.00, got %', v_amount;
  end if;
  perform set_config('p10.rev_1', v_id::text, false);

  -- Double reversal rejected.
  begin
    perform public.reverse_store_expense(current_setting('p10.exp_1')::uuid, 'محاولة عكس ثانية');
    raise exception 'TEST FAILED: an expense was reversed TWICE';
  exception when others then
    if sqlerrm not like '%مسبقًا%' then raise; end if;
  end;

  -- A reversal cannot itself be reversed.
  begin
    perform public.reverse_store_expense(current_setting('p10.rev_1')::uuid, 'عكس العكس');
    raise exception 'TEST FAILED: a reversal entry was itself reversed';
  exception when others then
    if sqlerrm not like '%حركة عكس%' then raise; end if;
  end;
end;
$$;

-- The reversal must DERIVE its amount, store and category from the original
-- row — the RPC takes no amount/store/category parameter at all, and this
-- asserts that structurally rather than trusting the signature.
reset role;
reset request.jwt.claims;
do $$
declare
  v_orig public.store_expenses%rowtype;
  v_rev public.store_expenses%rowtype;
begin
  select * into v_orig from public.store_expenses where id = current_setting('p10.exp_1')::uuid;
  select * into v_rev from public.store_expenses where id = current_setting('p10.rev_1')::uuid;

  if v_rev.amount <> -v_orig.amount then
    raise exception 'TEST FAILED: reversal amount (%) is not the exact negation of the original (%)', v_rev.amount, v_orig.amount;
  end if;
  if v_rev.store_id <> v_orig.store_id then
    raise exception 'TEST FAILED: reversal store_id was not derived from the original';
  end if;
  if v_rev.expense_category_id <> v_orig.expense_category_id then
    raise exception 'TEST FAILED: reversal expense_category_id was not derived from the original';
  end if;
  if v_rev.category_code_snapshot is distinct from v_orig.category_code_snapshot
     or v_rev.category_name_ar_snapshot is distinct from v_orig.category_name_ar_snapshot then
    raise exception 'TEST FAILED: reversal category snapshots were not carried over from the original';
  end if;
  if v_rev.reverses_expense_id <> v_orig.id then
    raise exception 'TEST FAILED: reversal is not linked back to the original expense';
  end if;
  if v_rev.business_date = v_orig.business_date then
    raise exception 'TEST FAILED: this fixture intends the reversal to carry its OWN (different) business date, so §85 is actually exercised';
  end if;
end;
$$;
set role authenticated;

-- ---------------------------------------------------------------------------
-- 6. Append-only — UPDATE/DELETE are impossible at table level.
-- ---------------------------------------------------------------------------
reset role;
reset request.jwt.claims;
do $$
begin
  -- Attempted as the SUPERUSER, which bypasses RLS entirely: the append-only
  -- guarantee must hold at table level, not merely by policy.
  begin
    update public.store_expenses set amount = 1 where id = current_setting('p10.exp_1')::uuid;
    raise exception 'TEST FAILED: a posted expense row was UPDATED';
  exception when others then
    if sqlerrm not like '%إضافي فقط%' then raise; end if;
  end;

  begin
    delete from public.store_expenses where id = current_setting('p10.exp_1')::uuid;
    raise exception 'TEST FAILED: a posted expense row was DELETED';
  exception when others then
    if sqlerrm not like '%إضافي فقط%' then raise; end if;
  end;
end;
$$;
set role authenticated;

-- ---------------------------------------------------------------------------
-- 7. Daily close (§12).
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"aa000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
begin
  perform public.close_sales_day(current_setting('p10.store_a')::uuid, current_date - 5, 'إغلاق اختبار Phase 10');
end;
$$;

-- Actor 001 has no expenses.process_closed_day -> rejected.
do $$
begin
  begin
    perform public.record_store_expense(current_setting('p10.store_a')::uuid, current_setting('p10.cat_rent')::uuid, 25, current_date - 5, 'مصروف في يوم مقفل');
    raise exception 'TEST FAILED: an expense was recorded into a CLOSED day without expenses.process_closed_day';
  exception when others then
    if sqlerrm not like '%يوم مقفل%' then raise; end if;
  end;
end;
$$;

-- Actor 006 holds the permission but must still supply a reason.
set local request.jwt.claims = '{"sub":"aa000000-0000-4000-8000-000000000006","role":"authenticated"}';
do $$
declare
  v_id uuid;
begin
  begin
    perform public.record_store_expense(current_setting('p10.store_a')::uuid, current_setting('p10.cat_rent')::uuid, 25, current_date - 5, 'مصروف في يوم مقفل');
    raise exception 'TEST FAILED: a closed-day expense was accepted without a reason';
  exception when others then
    if sqlerrm not like '%سبب%' then raise; end if;
  end;

  select id into v_id from public.record_store_expense(
    current_setting('p10.store_a')::uuid, current_setting('p10.cat_rent')::uuid, 25, current_date - 5,
    'مصروف في يوم مقفل', 'تسوية متأخرة معتمدة'
  );
  if v_id is null then
    raise exception 'TEST FAILED: a permitted closed-day expense with a reason was not recorded';
  end if;
  perform set_config('p10.exp_closed', v_id::text, false);
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Reads — store scope, filters, and the signed-ledger total.
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"aa000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v jsonb;
begin
  v := public.list_store_expenses(current_date - 30, current_date);

  -- 1500 (expense) + 50 (utilities) + 25 (closed-day) - 1500 (reversal) = 75.
  if v -> 'summary' ->> 'operating_expenses_total' <> '75.00' then
    raise exception 'TEST FAILED: expected net operating_expenses_total=75.00, got %', v -> 'summary' ->> 'operating_expenses_total';
  end if;
  if v -> 'summary' ->> 'gross_expenses_total' <> '1575.00' then
    raise exception 'TEST FAILED: expected gross_expenses_total=1575.00, got %', v -> 'summary' ->> 'gross_expenses_total';
  end if;
  if v -> 'summary' ->> 'reversals_total' <> '-1500.00' then
    raise exception 'TEST FAILED: expected reversals_total=-1500.00, got %', v -> 'summary' ->> 'reversals_total';
  end if;

  -- An explicit store filter outside the actor's scope is REJECTED (§8).
  begin
    perform public.list_store_expenses(current_date - 30, current_date, array['ffffffff-ffff-4fff-8fff-ffffffffffff'::uuid]);
    raise exception 'TEST FAILED: an out-of-scope explicit store filter was accepted';
  exception when others then
    if sqlerrm not like '%نطاق صلاحيتك%' then raise; end if;
  end;
end;
$$;

-- Store-B-only actor sees NOTHING from Store A.
set local request.jwt.claims = '{"sub":"aa000000-0000-4000-8000-000000000005","role":"authenticated"}';
do $$
declare
  v jsonb;
begin
  v := public.list_store_expenses(current_date - 30, current_date);
  if (v ->> 'total_count')::int <> 0 then
    raise exception 'TEST FAILED: Store-B-only actor saw % Store-A expense rows', v ->> 'total_count';
  end if;
end;
$$;

-- An actor without expenses.view cannot read at all.
set local request.jwt.claims = '{"sub":"aa000000-0000-4000-8000-000000000003","role":"authenticated"}';
do $$
begin
  begin
    perform public.list_store_expenses(current_date - 30, current_date);
    raise exception 'TEST FAILED: an actor without expenses.view read the expense ledger';
  exception when others then
    if sqlerrm not like '%صلاحية%' then raise; end if;
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Audit trail — one row per mutation.
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"aa000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_entries int;
  v_audit int;
begin
  select count(*) into v_entries from public.store_expenses;

  select count(*) into v_audit from public.audit_logs
  where action in ('expense.record', 'expense.reverse') and entity_type = 'store_expense';

  if v_entries = 0 then
    raise exception 'TEST FAILED: no expense entries were committed at all';
  end if;
  if v_audit <> v_entries then
    raise exception 'TEST FAILED: expected exactly one audit row per ledger entry (% entries), got % audit rows', v_entries, v_audit;
  end if;

  if not exists (select 1 from public.audit_logs where action = 'expense_category.create' and entity_type = 'expense_category') then
    raise exception 'TEST FAILED: category creation was not audited';
  end if;
  if not exists (select 1 from public.audit_logs where action = 'expense_category.disable') then
    raise exception 'TEST FAILED: category disable was not audited';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. Reporting — the legacy field is untouched; the new fields are correct.
-- ---------------------------------------------------------------------------
do $$
declare
  v_legacy jsonb;
  v_new jsonb;
  v_nor_legacy text;
  v_nor_new text;
  v_contribution text;
  v_expenses text;
  v_after text;
begin
  v_legacy := public.get_dashboard_summary_with_comparison(current_date - 30, current_date, 'last30', null);
  v_new := public.get_dashboard_summary_with_expenses(current_date - 30, current_date, 'last30', null);

  v_nor_legacy := v_legacy -> 'net_operating_return' ->> 'net_operating_return';
  v_nor_new := v_new -> 'net_operating_return' ->> 'net_operating_return';

  -- BACKWARD COMPATIBILITY: the legacy key must be byte-identical between the
  -- old function and the new expense-aware one.
  if v_nor_legacy is distinct from v_nor_new then
    raise exception 'TEST FAILED (CRITICAL backward compatibility): net_operating_return changed between the legacy and expense-aware RPCs — legacy=%, new=%', v_nor_legacy, v_nor_new;
  end if;

  -- The legacy function must NOT have grown any of the new keys.
  if (v_legacy -> 'net_operating_return') ? 'net_operating_result_after_expenses' or v_legacy ? 'expenses' then
    raise exception 'TEST FAILED: the legacy RPC leaked Phase 10 keys';
  end if;

  v_contribution := v_new -> 'net_operating_return' ->> 'operating_contribution_before_expenses';
  v_expenses := v_new -> 'net_operating_return' ->> 'operating_expenses_total';
  v_after := v_new -> 'net_operating_return' ->> 'net_operating_result_after_expenses';

  if v_contribution is distinct from v_nor_legacy then
    raise exception 'TEST FAILED: operating_contribution_before_expenses (%) must equal the legacy net_operating_return (%)', v_contribution, v_nor_legacy;
  end if;
  if v_expenses <> '75.00' then
    raise exception 'TEST FAILED: expected operating_expenses_total=75.00 on the dashboard, got %', v_expenses;
  end if;
  if v_after::numeric <> v_contribution::numeric - 75.00 then
    raise exception 'TEST FAILED: net_operating_result_after_expenses (%) <> contribution (%) - expenses (75.00)', v_after, v_contribution;
  end if;
  if v_new -> 'expenses' ->> 'operating_expenses_total' <> '75.00' then
    raise exception 'TEST FAILED: expenses section total mismatch, got %', v_new -> 'expenses' ->> 'operating_expenses_total';
  end if;
end;
$$;

-- §79 true key-absence: an actor WITHOUT expenses.view gets none of the new
-- keys — not zeros.
set local request.jwt.claims = '{"sub":"aa000000-0000-4000-8000-000000000004","role":"authenticated"}';
do $$
declare
  v jsonb;
begin
  v := public.get_dashboard_summary_with_expenses(current_date - 30, current_date, 'last30', null);

  -- Guard against a VACUOUS pass: actor 004 deliberately holds the full
  -- dashboard financial permission set, so net_operating_return MUST be
  -- present. Without this, the two absence checks below would also "pass" on
  -- a response that simply had no net_operating_return section at all,
  -- proving nothing about expense redaction.
  if not (v ? 'net_operating_return') then
    raise exception 'TEST FAILED: the §79 probe is vacuous — actor 004 should still see net_operating_return, got keys: %',
      (select jsonb_agg(k) from jsonb_object_keys(v) k);
  end if;
  if (v -> 'net_operating_return' ->> 'net_operating_return') is null then
    raise exception 'TEST FAILED: the §79 probe is vacuous — net_operating_return carries no value for actor 004';
  end if;

  if v ? 'expenses' then
    raise exception 'TEST FAILED (CRITICAL privacy): an actor without expenses.view received an `expenses` section';
  end if;
  if (v -> 'net_operating_return') ? 'net_operating_result_after_expenses' then
    raise exception 'TEST FAILED (CRITICAL privacy): an actor without expenses.view received the after-expenses figure';
  end if;
  if (v -> 'net_operating_return') ? 'operating_expenses_total' then
    raise exception 'TEST FAILED (CRITICAL privacy): an actor without expenses.view received an expense total';
  end if;
end;
$$;

do $$
begin
  raise notice '=== ALL store_expenses_phase10.test.sql ASSERTIONS PASSED ===';
end $$;

rollback;
