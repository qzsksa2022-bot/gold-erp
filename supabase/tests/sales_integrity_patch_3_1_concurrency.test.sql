-- ============================================================================
-- Integration test: Phase 3 — Sales Integrity Patch 3.1, Part 2 — GENUINE
-- multi-session concurrency (spec item 13, tests H/I/J/K)
-- ============================================================================
-- This file is FUNDAMENTALLY DIFFERENT from every other test file in this
-- project and is NOT safe to run against a shared/staging database:
--
--   - It is NOT wrapped in begin/rollback. Every top-level statement here
--     auto-commits (this is required — the whole point is to prove real
--     cross-session locking/blocking behavior, which is meaningless inside
--     a single uncommitted transaction).
--   - It uses the `dblink` extension to open TWO genuinely separate,
--     independent Postgres connections/sessions (conn_a, conn_b) FROM one
--     controlling script, so it can prove actual blocking (one session
--     truly waits on another session's lock, observed via dblink_is_busy())
--     rather than merely asserting sequential call order.
--   - It creates its own fixtures (store/karat/category/channel/payment
--     method/gold price fixtures, prefix 'P31C') and explicitly DELETEs
--     every row it created at the very end (real cleanup, not ROLLBACK).
--     If this script is interrupted before reaching its cleanup section,
--     stale 'P31C*'-prefixed rows may be left behind — safe to re-run (all
--     fixture INSERTs use ON CONFLICT-free fresh codes per run via a random
--     suffix... actually see NOTE below) or manually clean up by filtering
--     on the P31C prefix.
--
-- Run ONLY against a throwaway/CI database, exactly like scripts/
-- run_postgrest_http_test.sh's target database. Requires migrations
-- 0001-0072 + supabase/seed.sql already applied, and the `dblink` extension
-- available (contrib module, ships with standard Postgres).
--
-- Connection string for the two dblink sessions: override via
--   psql -v dblink_conninfo="host=... port=... user=... password=..." \
--     -f supabase/tests/sales_integrity_patch_3_1_concurrency.test.sql
-- Defaults to "host=127.0.0.1 port=5432 user=postgres password=postgres"
-- (this project's established local convention — see scripts/
-- run_postgrest_http_test.sh) with dbname=current_database() appended
-- automatically, so the default works out of the box against a local
-- throwaway database created the same way that script's Part 3 fixtures are.
--
-- Covers:
--   H — Daily Close vs create/update race (spec item 5): close_sales_day()
--       genuinely blocks while a same-day create_sales_order()/
--       update_sales_order() transaction is still open, and vice versa.
--   I — Lost update (spec item 6): two sessions editing the SAME order
--       concurrently; the second genuinely blocks on the row lock, then
--       builds its edit (and its audit old_values) on the FIRST session's
--       committed state, never a stale pre-lock snapshot.
--   J — Torn financial snapshot (spec item 7): a concurrent gold-price
--       write genuinely blocks for the full duration of an in-flight
--       multi-item create_sales_order() for that same karat/date — proving
--       the whole order can only ever see one coherent price, never a mix.
--   K — Order number uniqueness under genuine parallel dispatch (spec item
--       5/25): several create_sales_order() calls fired concurrently across
--       both connections; every order_number is unique.
-- ============================================================================

create extension if not exists dblink;

\if :{?dblink_conninfo}
\else
\set dblink_conninfo 'host=127.0.0.1 port=5432 user=postgres password=postgres'
\endif

-- psql's :'var' interpolation is NOT performed inside dollar-quoted plpgsql
-- bodies (do $$ ... $$), so every do-block below that needs the conninfo
-- reads it back out of this session-local GUC instead of referencing
-- :'dblink_conninfo' directly. The select below is a plain top-level
-- statement (not dollar-quoted), so the psql-side substitution still
-- applies here.
select set_config('p31c.dblink_conninfo', :'dblink_conninfo', false);

-- ---------------------------------------------------------------------------
-- Small polling helpers, test-only, dropped at the end (mirrors the
-- synthetic-diagnostic-function pattern already established in
-- supabase/tests/postgrest_http_test_setup.sql for exactly this reason:
-- infrastructure that exists only to make an otherwise-unobservable
-- mechanism provable, never shipped as a real migration).
-- ---------------------------------------------------------------------------
create or replace function public._p31c_wait_busy(p_connname text, p_max_polls int default 30, p_interval numeric default 0.1)
returns boolean
language plpgsql
as $$
declare v_i int;
begin
  for v_i in 1..p_max_polls loop
    if dblink_is_busy(p_connname) = 1 then
      return true;
    end if;
    perform pg_sleep(p_interval);
  end loop;
  return dblink_is_busy(p_connname) = 1;
end;
$$;

comment on function public._p31c_wait_busy(text, int, numeric) is
  'TEST-ONLY (Patch 3.1 concurrency test infra, not a migration): polls dblink_is_busy() up to p_max_polls times, returning true as soon as the connection reports busy (proving a concurrent statement is genuinely blocked server-side). Used to prove a session really is waiting on another session''s lock, not just "ran after" it.';

create or replace function public._p31c_wait_ready(p_connname text, p_max_polls int default 100, p_interval numeric default 0.1)
returns boolean
language plpgsql
as $$
declare v_i int;
begin
  for v_i in 1..p_max_polls loop
    if dblink_is_busy(p_connname) = 0 then
      return true;
    end if;
    perform pg_sleep(p_interval);
  end loop;
  return dblink_is_busy(p_connname) = 0;
end;
$$;

comment on function public._p31c_wait_ready(text, int, numeric) is
  'TEST-ONLY: polls dblink_is_busy() until it reports NOT busy (result ready) or the poll budget is exhausted. Used after releasing a lock a connection was waiting on, to wait for it to actually complete before fetching its result with dblink_get_result().';

-- dblink_get_result() must be called repeatedly, once per PGresult in the
-- libpq async protocol, until it returns zero rows — a single call only
-- drains the FIRST result (the actual row/value); the connection is left in
-- an unusable "another command is already in progress" state until a
-- second, empty-returning call finalizes it (this matches the canonical
-- dblink documentation example, which always shows the trailing empty
-- fetch). The column definition on this trailing call is irrelevant since
-- it always returns zero rows once the real result was already consumed.
create or replace function public._p31c_drain_pending(p_connname text)
returns void
language plpgsql
as $$
begin
  perform 1 from dblink_get_result(p_connname) as t(x text);
end;
$$;

comment on function public._p31c_drain_pending(text) is
  'TEST-ONLY: consumes the trailing empty PGresult a dblink async call always leaves behind after its real result was fetched, so the connection can accept its next command (SET/COMMIT/next query) without erroring "another command is already in progress".';

-- ============================================================================
-- 0. Fixtures — own prefix 'P31C', committed immediately (no wrapping
-- transaction) so both dblink sessions can see them right away.
-- ============================================================================
insert into auth.users (id, email) values
  ('d6000000-0000-4000-8000-000000000001', 'test-p31c-manager@example.invalid'),
  ('d6000000-0000-4000-8000-000000000002', 'test-p31c-closer@example.invalid')
on conflict (id) do nothing;

update public.profiles set full_name = 'Test P31C Manager', status = 'active', store_access_scope = 'all'
  where id = 'd6000000-0000-4000-8000-000000000001';
update public.profiles set full_name = 'Test P31C Closer', status = 'active', store_access_scope = 'all'
  where id = 'd6000000-0000-4000-8000-000000000002';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'd6000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in (
    'stores.view', 'stores.create', 'karats.view', 'karats.manage', 'categories.view', 'categories.manage',
    'collection_channels.view', 'collection_channels.manage', 'payment_methods.view', 'payment_methods.manage',
    'gold_prices.view', 'gold_prices.edit', 'manufacturing_fees.view', 'manufacturing_fees.manage',
    'sales.create', 'sales.edit', 'sales.view', 'sales.view_profit', 'sales.edit_closed_day'
  )
on conflict do nothing;

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'd6000000-0000-4000-8000-000000000002', id, 'grant' from public.permissions
  where key in ('sales.view', 'sales.close_day')
on conflict do nothing;

do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
begin
  set role authenticated;
  perform set_config('request.jwt.claims', '{"sub":"d6000000-0000-4000-8000-000000000001","role":"authenticated"}', false);

  insert into public.stores (code, name_ar, status) values ('P31CST', 'متجر تزامن 3.1', 'active') returning id into v_store_id;
  -- Dedicated store for section H1 only, so H1 closing "business_today()"
  -- there does not collide with sections I/J/K, which create orders for
  -- business_today() at the main P31CST store. Gold price/fee versions are
  -- karat/payment-method scoped (not store-scoped), so H1 reuses the same
  -- karat/category/channel/payment-method fixtures below without needing
  -- its own price/fee data.
  insert into public.stores (code, name_ar, status) values ('P31CH1', 'متجر تزامن 3.1 (H1)', 'active');
  insert into public.karats (code, name_ar, sort_order, status) values ('P31CK1', 'عيار تزامن 3.1', 971, 'active') returning id into v_karat_id;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('p31ccat', 'تصنيف تزامن 3.1', 971, 'active') returning id into v_category_id;
  insert into public.collection_channels (key, name_ar, sort_order, status) values ('p31c_channel', 'قناة تزامن 3.1', 971, 'active') returning id into v_channel_id;
  insert into public.payment_methods (key, name_ar, fee_model, sort_order, status) values ('p31c_pm', 'طريقة دفع تزامن 3.1', 'percentage', 971, 'active') returning id into v_pm_id;

  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 300.0000, 'd6000000-0000-4000-8000-000000000001');
  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, public.business_today(), 'p31c fixture');
  perform public.create_payment_method_fee_version(v_pm_id, 2.5, 0, public.business_today(), 'p31c fixture');

  reset role;
end $$;

-- ============================================================================
-- H) Daily Close vs create_sales_order race (spec item 5)
-- H1: create_sales_order holds the shared lock (uncommitted) -> a
-- concurrent close_sales_day() for the SAME day genuinely blocks, and only
-- succeeds after the create commits — never interleaves.
-- ============================================================================
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_close_day date; v_busy boolean; v_ready boolean; v_row record;
  v_order_count_before int; v_closing_count_after int;
begin
  -- Dedicated store (P31CH1) so H1 closing "today" there does not collide
  -- with sections I/J/K, which create orders for business_today() at the
  -- main P31CST store.
  select id into v_store_id from public.stores where code = 'P31CH1';
  select id into v_karat_id from public.karats where code = 'P31CK1';
  select id into v_category_id from public.product_categories where code = 'p31ccat';
  select id into v_channel_id from public.collection_channels where key = 'p31c_channel';
  select id into v_pm_id from public.payment_methods where key = 'p31c_pm';
  v_close_day := public.business_today();

  perform dblink_connect('conn_a', current_setting('p31c.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p31c.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"d6000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A creates a Sale for this exact (store, day) and stays OPEN (no commit
  -- yet) — the shared daily-close lock for (store_id, v_close_day) is held
  -- for the rest of A's transaction.
  -- dblink_exec disallows any remote statement that returns rows (even a
  -- single-row SELECT of a function call), so the row-returning RPC call is
  -- wrapped in a remote DO block (via PERFORM) purely to satisfy that
  -- restriction — the return value is not needed here, only that the call
  -- runs and its transaction stays open.
  perform dblink_exec('conn_a', format(
    $sql$do $inner$ begin perform public.create_sales_order('%s'::uuid, '%s'::date, '%s'::uuid, '%s'::uuid, '[{"category_id":"%s","karat_id":"%s","weight_grams":1.0,"sale_price":400.00}]'::jsonb); end $inner$;$sql$,
    v_store_id, v_close_day, v_pm_id, v_channel_id, v_category_id, v_karat_id
  ));

  -- B attempts to close the SAME day, asynchronously (so this script does
  -- not itself block waiting for it).
  perform dblink_exec('conn_b', 'begin');
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"d6000000-0000-4000-8000-000000000002","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select public.close_sales_day('%s'::uuid, '%s'::date, 'H1 concurrency test')$sql$,
    v_store_id, v_close_day
  ));

  v_busy := public._p31c_wait_busy('conn_b');
  assert v_busy, 'FAIL H1: close_sales_day() (اتصال B) لم يُحجب رغم أن create_sales_order() (اتصال A) ما زال مفتوحًا بمعاملة لم تُلتزَم لنفس اليوم/المتجر — القفل المشترك/الحصري لم يعمل';

  -- Release A's shared lock.
  perform dblink_exec('conn_a', 'commit');

  v_ready := public._p31c_wait_ready('conn_b');
  assert v_ready, 'FAIL H1: close_sales_day() (اتصال B) لم يكتمل خلال المهلة بعد التزام A — قد يكون هناك تعليق (deadlock)';

  -- Drain B's result (it succeeded — day was open when A committed cleanly
  -- before B's exclusive lock was ever granted). close_sales_day() returns
  -- a bare uuid, so dblink_get_result needs a matching column definition.
  perform closing_id from dblink_get_result('conn_b', true) as t(closing_id uuid);
  perform public._p31c_drain_pending('conn_b');
  perform dblink_exec('conn_b', 'commit');

  select count(*) into v_closing_count_after from public.daily_closings
    where store_id = v_store_id and business_date = v_close_day;
  assert v_closing_count_after = 1, format('FAIL H1: يجب أن يكون اليوم مغلقًا الآن بعد نجاح B، وجد %s صف إغلاق', v_closing_count_after);

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  raise notice 'OK: H1 close_sales_day() انتظر فعليًا حتى التزام create_sales_order() المفتوحة لنفس اليوم/المتجر قبل أن يتابع — لا تداخل (race) في أي ترتيب تنفيذ';
end $$;

-- H2: reverse ordering — close_sales_day() holds the EXCLUSIVE lock
-- (uncommitted) -> a concurrent create_sales_order() for the SAME day
-- genuinely blocks, and correctly observes the day as CLOSED once it
-- proceeds (rejected without sales.edit_closed_day).
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_close_day date; v_busy boolean; v_ready boolean; v_result record; v_error text;
begin
  select id into v_store_id from public.stores where code = 'P31CST';
  select id into v_karat_id from public.karats where code = 'P31CK1';
  select id into v_category_id from public.product_categories where code = 'p31ccat';
  select id into v_channel_id from public.collection_channels where key = 'p31c_channel';
  select id into v_pm_id from public.payment_methods where key = 'p31c_pm';
  v_close_day := public.business_today() - 1; -- distinct day from H1, still never-future.

  perform dblink_connect('conn_a', current_setting('p31c.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p31c.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"d6000000-0000-4000-8000-000000000002","role":"authenticated"}'$sql$);
  perform dblink_exec('conn_a', format(
    $sql$do $inner$ begin perform public.close_sales_day('%s'::uuid, '%s'::date, 'H2 concurrency test'); end $inner$;$sql$,
    v_store_id, v_close_day
  ));
  -- A stays OPEN — holds the EXCLUSIVE daily-close lock for (store, day).

  perform dblink_exec('conn_b', 'begin');
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"d6000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select * from public.create_sales_order('%s'::uuid, '%s'::date, '%s'::uuid, '%s'::uuid, '[{"category_id":"%s","karat_id":"%s","weight_grams":1.0,"sale_price":400.00}]'::jsonb)$sql$,
    v_store_id, v_close_day, v_pm_id, v_channel_id, v_category_id, v_karat_id
  ));

  v_busy := public._p31c_wait_busy('conn_b');
  assert v_busy, 'FAIL H2: create_sales_order() (اتصال B) لم يُحجب رغم أن close_sales_day() (اتصال A) ما زال مفتوحًا بمعاملة لم تُلتزَم لنفس اليوم/المتجر';

  perform dblink_exec('conn_a', 'commit');

  v_ready := public._p31c_wait_ready('conn_b');
  assert v_ready, 'FAIL H2: create_sales_order() (اتصال B) لم يكتمل خلال المهلة بعد التزام A';

  -- B must now see the day as CLOSED and be rejected (no
  -- sales.edit_closed_day override was supplied) — never silently succeed
  -- on a day that was already closed by the time B actually proceeded.
  begin
    perform id from dblink_get_result('conn_b', true) as t(id uuid, order_number text);
    raise exception 'BUG H2: نجحت create_sales_order() (اتصال B) رغم أن اليوم أُغلق قبل أن تتابع فعليًا — تجاوز إغلاق اليوم';
  exception when others then
    v_error := sqlerrm;
    -- Even when the remote command itself errored, the async protocol still
    -- leaves a trailing empty PGresult to drain before the connection can
    -- accept its next command.
    perform public._p31c_drain_pending('conn_b');
    assert v_error like '%مقفل%', format('FAIL H2: كان يجب رفض العملية بسبب إقفال اليوم، لكن الخطأ الفعلي كان: %s', v_error);
    raise notice 'OK: H2 create_sales_order() انتظر فعليًا حتى التزام close_sales_day() المفتوحة، ثم رأى اليوم مقفلًا بشكل صحيح ورُفض (%)', v_error;
  end;

  perform dblink_exec('conn_b', 'rollback');
  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');
end $$;

-- ============================================================================
-- I) Lost update — Patch 3.2 item 2/11(A) corrected expectation: `for update`
-- alone only serializes concurrent writers, it does NOT stop a serialized-
-- but-STALE payload from silently winning. As of 0075, update_sales_order()
-- requires p_expected_version (optimistic concurrency via
-- sales_orders.row_version) — the mandatory scenario below proves the STALE
-- writer (B) now genuinely FAILS with a Conflict once it finally acquires
-- the row lock, rather than being allowed to overwrite A's already-committed
-- edit (the OLD, now-corrected assertion in this file used to expect B to
-- win — that was exactly the Lost Update bug item 2 exists to close, not a
-- passing behavior). B must reload and resubmit with the new version to
-- actually save its edit.
-- ============================================================================
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_order_id uuid; v_item_id uuid; v_stale_weight numeric; v_busy boolean; v_ready boolean;
  v_initial_version bigint; v_version_after_a bigint; v_version_after_b_retry bigint;
  v_final_customer_name text; v_final_weight numeric; v_error text;
  v_update_audit_count int;
begin
  select id into v_store_id from public.stores where code = 'P31CST';
  select id into v_karat_id from public.karats where code = 'P31CK1';
  select id into v_category_id from public.product_categories where code = 'p31ccat';
  select id into v_channel_id from public.collection_channels where key = 'p31c_channel';
  select id into v_pm_id from public.payment_methods where key = 'p31c_pm';

  set role authenticated;
  perform set_config('request.jwt.claims', '{"sub":"d6000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 400.00))
  );
  reset role;

  select id, weight_grams into v_item_id, v_stale_weight from public.sales_order_items where sales_order_id = v_order_id and status = 'active';
  select row_version into v_initial_version from public.sales_orders where id = v_order_id;

  -- Commit so the two genuinely separate dblink connections below (which
  -- are brand-new sessions) can actually see this order — without this,
  -- both A and B would fail with "not found" since the insert is still
  -- only visible inside this DO block's own uncommitted transaction.
  commit;

  perform dblink_connect('conn_a', current_setting('p31c.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p31c.dblink_conninfo') || ' dbname=' || current_database());

  -- A: opens the order for edit having loaded row_version=v_initial_version,
  -- changes weight 1.0 -> 5.0, stays OPEN.
  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"d6000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_exec('conn_a', format(
    $sql$do $inner$ begin perform public.update_sales_order('%s'::uuid, '%s'::uuid, '%s'::uuid, '[{"id":"%s","category_id":"%s","karat_id":"%s","weight_grams":5.0,"sale_price":400.00}]'::jsonb, 'A edit', null, null, null, %s); end $inner$;$sql$,
    v_order_id, v_pm_id, v_channel_id, v_item_id, v_category_id, v_karat_id, v_initial_version
  ));

  -- B: loaded the SAME order BEFORE A's edit — its payload uses the item's
  -- ORIGINAL weight (1.0) AND the SAME v_initial_version A also loaded — and
  -- submits AFTER A started but before A committed — must block on A's row
  -- lock exactly like before.
  perform dblink_exec('conn_b', 'begin');
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"d6000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select * from public.update_sales_order('%s'::uuid, '%s'::uuid, '%s'::uuid, '[{"id":"%s","category_id":"%s","karat_id":"%s","weight_grams":%s,"sale_price":400.00}]'::jsonb, 'B edit', null, null, null, %s)$sql$,
    v_order_id, v_pm_id, v_channel_id, v_item_id, v_category_id, v_karat_id, v_stale_weight, v_initial_version
  ));

  v_busy := public._p31c_wait_busy('conn_b');
  assert v_busy, 'FAIL I: update_sales_order() الثاني (اتصال B) لم يُحجب رغم أن الأول (اتصال A) ما زال مفتوحًا بمعاملة لم تُلتزَم على نفس العملية';

  -- A commits — the row lock releases, its row_version increments.
  perform dblink_exec('conn_a', 'commit');

  v_ready := public._p31c_wait_ready('conn_b');
  assert v_ready, 'FAIL I: update_sales_order() الثاني (اتصال B) لم يكتمل خلال المهلة بعد التزام A';

  -- The critical, corrected assertion (item 2/11(A)): B's stale
  -- p_expected_version (still v_initial_version, A's edit already advanced
  -- it) must now be REJECTED with a Conflict — B must NOT be allowed to
  -- silently overwrite A's already-committed edit just because it waited
  -- its turn on the row lock.
  begin
    perform id from dblink_get_result('conn_b', true) as t(id uuid, order_number text);
    raise exception 'BUG I: نجح تعديل B الثاني رغم أن نسخته (row_version) كانت قديمة (Lost Update لم يُمنع)';
  exception when others then
    v_error := sqlerrm;
    perform public._p31c_drain_pending('conn_b');
    assert v_error like '%مستخدم آخر%', format('FAIL I: كان يجب رفض تعديل B بسبب تعارض الإصدار، لكن الخطأ الفعلي كان: %s', v_error);
    raise notice 'OK: I(1) تعديل B الثاني (بإصدار قديم) انتظر فعليًا قفل الصف حتى التزام A، ثم رُفض بتعارض إصدار صريح بدل الكتابة فوق تعديل A المُلتزَم بصمت (%)', v_error;
  end;
  perform dblink_exec('conn_b', 'rollback');

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  -- A's edit must be the one that stands — never silently overwritten.
  select customer_name into v_final_customer_name from public.sales_orders where id = v_order_id;
  select weight_grams into v_final_weight from public.sales_order_items where id = v_item_id and status = 'active';
  assert v_final_customer_name = 'A edit', format('FAIL I: تعديل A المُلتزَم يجب أن يبقى قائمًا (لم يُستبدل بصمت)، متوقَّع ''A edit''، وجد %s', v_final_customer_name);
  assert v_final_weight = 5.0, format('FAIL I: الوزن النهائي يجب أن يعكس تعديل A (5.0) لا تعديل B المرفوض، وجد %s', v_final_weight);

  -- Exactly one sale.update audit row must exist so far (A's) — B's
  -- rejected attempt must NOT have written an audit row at all (the version
  -- conflict is raised before any write, including the audit call).
  select count(*) into v_update_audit_count from public.audit_logs where action = 'sale.update' and entity_type = 'sales_order' and entity_id = v_order_id;
  assert v_update_audit_count = 1, format('FAIL I: يجب وجود حدث sale.update واحد فقط (من A) — محاولة B المرفوضة يجب ألا تُنتج أي سجل تدقيق، وجد %s', v_update_audit_count);

  select row_version into v_version_after_a from public.sales_orders where id = v_order_id;
  assert v_version_after_a = v_initial_version + 1, format('FAIL I: row_version بعد نجاح A يجب أن يزيد بمقدار 1 بالضبط (من %s)، وجد %s', v_initial_version, v_version_after_a);

  -- I(2) — B now reloads (observing the new committed version), re-applies
  -- ITS edit on top of A's committed state, and resubmits with the correct
  -- expected_version — this time it must succeed, exactly per the spec's
  -- mandatory scenario ("B reloads, re-applies its edit, saves successfully").
  set role authenticated;
  perform set_config('request.jwt.claims', '{"sub":"d6000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  perform public.update_sales_order(
    v_order_id, v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('id', v_item_id, 'category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 5.0, 'sale_price', 400.00)),
    'B edit (reloaded and reapplied)', null, null, null, v_version_after_a
  );
  reset role;

  select customer_name into v_final_customer_name from public.sales_orders where id = v_order_id;
  select row_version into v_version_after_b_retry from public.sales_orders where id = v_order_id;
  assert v_final_customer_name = 'B edit (reloaded and reapplied)', 'FAIL I: بعد إعادة تحميل B وإعادة تقديم تعديله بالإصدار الصحيح، يجب أن ينجح فعليًا';
  assert v_version_after_b_retry = v_version_after_a + 1, format('FAIL I: row_version بعد نجاح إعادة محاولة B يجب أن يزيد بمقدار 1 إضافي (من %s)، وجد %s', v_version_after_a, v_version_after_b_retry);

  raise notice 'OK: I(2) بعد التعارض، أعاد B تحميل العملية (الإصدار %) وأعاد تطبيق تعديله ونجح — row_version أصبح %. لا فقدان صامت (Lost Update) في أي مرحلة', v_version_after_a, v_version_after_b_retry;
end $$;

-- ============================================================================
-- J) Torn financial snapshot (spec item 7): a concurrent gold-price write
-- for the same karat/date genuinely blocks for the FULL duration of an
-- in-flight multi-item create_sales_order() — proving the whole order can
-- only ever see one coherent price.
-- ============================================================================
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_busy boolean; v_ready boolean; v_order_id uuid; v_item_count int; v_price_used_count int;
begin
  select id into v_store_id from public.stores where code = 'P31CST';
  select id into v_channel_id from public.collection_channels where key = 'p31c_channel';
  select id into v_pm_id from public.payment_methods where key = 'p31c_pm';
  select id into v_category_id from public.product_categories where code = 'p31ccat';

  -- Dedicated karat for J so a prior scenario's price state can't interfere.
  set role authenticated;
  perform set_config('request.jwt.claims', '{"sub":"d6000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  insert into public.karats (code, name_ar, sort_order, status) values ('P31CK_J', 'عيار J تزامن 3.1', 972, 'active') returning id into v_karat_id;
  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 300.0000, 'd6000000-0000-4000-8000-000000000001');
  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, public.business_today(), 'p31c section J fixture');
  reset role;

  -- Commit so the dblink connections below (brand-new sessions) can see
  -- this karat's price/fee fixtures, same reasoning as section I.
  commit;

  perform dblink_connect('conn_a', current_setting('p31c.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p31c.dblink_conninfo') || ' dbname=' || current_database());

  -- A: creates a 2-item order for karat J, both items sharing the same
  -- (karat, date) gold price resolution — stays OPEN (uncommitted).
  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"d6000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_exec('conn_a', format(
    $sql$do $inner$ begin perform public.create_sales_order('%s'::uuid, '%s'::date, '%s'::uuid, '%s'::uuid,
      '[{"category_id":"%s","karat_id":"%s","weight_grams":1.0,"sale_price":400.00},{"category_id":"%s","karat_id":"%s","weight_grams":2.0,"sale_price":800.00}]'::jsonb); end $inner$;$sql$,
    v_store_id, public.business_today(), v_pm_id, v_channel_id, v_category_id, v_karat_id, v_category_id, v_karat_id
  ));

  -- B: attempts to correct the SAME karat's price for the SAME date while
  -- A's transaction is still open — must block on A's shared lock.
  perform dblink_exec('conn_b', 'begin');
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"d6000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select public.save_daily_gold_price('%s'::date, '%s'::uuid, 999.0000, 'J concurrency test')$sql$,
    public.business_today(), v_karat_id
  ));

  v_busy := public._p31c_wait_busy('conn_b');
  assert v_busy, 'FAIL J: save_daily_gold_price() (اتصال B) لم يُحجب رغم أن create_sales_order() (اتصال A) ما زال مفتوحًا بمعاملة لم تُلتزَم تستخدم نفس العيار/التاريخ — القفل المالي المشترك/الحصري لم يعمل';

  perform dblink_exec('conn_a', 'commit');

  v_ready := public._p31c_wait_ready('conn_b');
  assert v_ready, 'FAIL J: save_daily_gold_price() (اتصال B) لم يكتمل خلال المهلة بعد التزام A';
  perform price_id from dblink_get_result('conn_b', true) as t(price_id uuid);
  perform public._p31c_drain_pending('conn_b');
  perform dblink_exec('conn_b', 'commit');

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  select so.id into v_order_id from public.sales_orders so
    where so.store_id = v_store_id and so.sale_date = public.business_today()
    order by so.created_at desc limit 1;

  select count(*), count(*) filter (where gold_price_per_gram_snapshot = 300.0000)
    into v_item_count, v_price_used_count
    from public.sales_order_items where sales_order_id = v_order_id and status = 'active';

  assert v_item_count = 2, format('يجب أن تحتوي العملية على بندين، وجد %s', v_item_count);
  assert v_price_used_count = 2, format('FAIL J: كلا البندين يجب أن يستخدما نفس سعر الذهب القديم (300.0000) — لا مزيج قديم/جديد ضمن نفس العملية، وجد %s بند فقط بالسعر القديم من أصل %s', v_price_used_count, v_item_count);

  raise notice 'OK: J تصحيح سعر الذهب المتزامن (اتصال B) انتظر فعليًا حتى التزام create_sales_order() متعددة البنود (اتصال A) — كلا البندين استخدما سعرًا واحدًا متسقًا (القديم)، لا مزيج بند قديم + بند جديد ضمن نفس العملية';
end $$;

-- ============================================================================
-- J2) Patch 3.2 item 1/11(B) — closing the direct-write bypass: a DIRECT
-- UPDATE on public.daily_gold_prices (NOT via save_daily_gold_price()) must
-- ALSO block for the full duration of an in-flight multi-item
-- create_sales_order() for that same karat/date, and all of that order's
-- items must end up with fully-consistent (never-mixed) snapshots — proving
-- 0073's BEFORE STATEMENT trigger closes the bypass for every write path,
-- not just the RPC.
-- ============================================================================
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_busy boolean; v_ready boolean; v_order_id uuid; v_item_count int; v_price_used_count int;
begin
  select id into v_store_id from public.stores where code = 'P31CST';
  select id into v_channel_id from public.collection_channels where key = 'p31c_channel';
  select id into v_pm_id from public.payment_methods where key = 'p31c_pm';
  select id into v_category_id from public.product_categories where code = 'p31ccat';

  -- Dedicated karat for J2, independent of J's (which J already mutated to
  -- 999.0000 via the RPC path).
  set role authenticated;
  perform set_config('request.jwt.claims', '{"sub":"d6000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  insert into public.karats (code, name_ar, sort_order, status) values ('P31CK_J2', 'عيار J2 تزامن 3.2', 973, 'active') returning id into v_karat_id;
  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 300.0000, 'd6000000-0000-4000-8000-000000000001');
  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, public.business_today(), 'p31c section J2 fixture');
  reset role;

  commit;

  perform dblink_connect('conn_a', current_setting('p31c.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p31c.dblink_conninfo') || ' dbname=' || current_database());

  -- A: creates a 2-item order for karat J2, both items sharing the same
  -- (karat, date) gold price resolution — stays OPEN (uncommitted), holding
  -- the SHARED financial-master lock for its whole resolution window.
  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"d6000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_exec('conn_a', format(
    $sql$do $inner$ begin perform public.create_sales_order('%s'::uuid, '%s'::date, '%s'::uuid, '%s'::uuid,
      '[{"category_id":"%s","karat_id":"%s","weight_grams":1.0,"sale_price":400.00},{"category_id":"%s","karat_id":"%s","weight_grams":2.0,"sale_price":800.00}]'::jsonb); end $inner$;$sql$,
    v_store_id, public.business_today(), v_pm_id, v_channel_id, v_category_id, v_karat_id, v_category_id, v_karat_id
  ));

  -- B: a DIRECT UPDATE on daily_gold_prices for the SAME karat/date — NOT
  -- through save_daily_gold_price() at all — while A's transaction is still
  -- open. Must block on A's shared financial-master lock via 0073's BEFORE
  -- STATEMENT trigger exactly like the RPC path did in J above.
  perform dblink_exec('conn_b', 'begin');
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"d6000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$update public.daily_gold_prices set price_per_gram = 999.0000 where karat_id = '%s'::uuid and price_date = '%s'::date$sql$,
    v_karat_id, public.business_today()
  ));

  v_busy := public._p31c_wait_busy('conn_b');
  assert v_busy, 'FAIL J2: التحديث المباشر (اتصال B) على daily_gold_prices لم يُحجب رغم أن create_sales_order() (اتصال A) ما زال مفتوحًا بمعاملة لم تُلتزَم تستخدم نفس العيار/التاريخ — المُشغّل (trigger) الذي يغلق ثغرة الكتابة المباشرة لم يعمل';

  perform dblink_exec('conn_a', 'commit');

  v_ready := public._p31c_wait_ready('conn_b');
  assert v_ready, 'FAIL J2: التحديث المباشر (اتصال B) لم يكتمل خلال المهلة بعد التزام A';
  -- UPDATE (unlike a SELECT/RPC call) still leaves TWO PGresults to drain —
  -- the actual command-tag result, then the trailing empty one — so
  -- _p31c_drain_pending() (itself one dblink_get_result() call) is invoked
  -- twice here, matching the two-call pattern its own comment documents.
  perform public._p31c_drain_pending('conn_b');
  perform public._p31c_drain_pending('conn_b');
  perform dblink_exec('conn_b', 'commit');

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  select so.id into v_order_id from public.sales_orders so
    where so.store_id = v_store_id and so.sale_date = public.business_today()
      and exists (select 1 from public.sales_order_items it where it.sales_order_id = so.id and it.karat_id = v_karat_id)
    order by so.created_at desc limit 1;

  select count(*), count(*) filter (where gold_price_per_gram_snapshot = 300.0000)
    into v_item_count, v_price_used_count
    from public.sales_order_items where sales_order_id = v_order_id and status = 'active';

  assert v_item_count = 2, format('يجب أن تحتوي العملية على بندين، وجد %s', v_item_count);
  assert v_price_used_count = 2, format('FAIL J2: كلا البندين يجب أن يستخدما نفس سعر الذهب القديم (300.0000) رغم أن B حدّث الجدول مباشرة — لا مزيج قديم/جديد ضمن نفس العملية، وجد %s بند فقط بالسعر القديم من أصل %s', v_price_used_count, v_item_count);

  raise notice 'OK: J2 تحديث مباشر (بلا RPC) على daily_gold_prices (اتصال B) انتظر فعليًا حتى التزام create_sales_order() متعددة البنود (اتصال A) — كلا البندين استخدما سعرًا واحدًا متسقًا، إثبات أن مُشغّل 0073 يغلق ثغرة الكتابة المباشرة أيضًا لا الـ RPC فقط';
end $$;

-- ============================================================================
-- L1) Hotfix 3.2.1 item 2 — service_role must actually be able to WRITE
-- daily_gold_prices under the 0073 lock (blocked-then-succeeds), not hit
-- "permission denied for function acquire_financial_master_lock_exclusive".
-- Before 0081's grant, this failed outright with a permission error instead
-- of waiting on conn_a's shared lock like J2 (authenticated) already does.
-- ============================================================================
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_busy boolean; v_ready boolean; v_order_id uuid; v_item_count int; v_price_used_count int;
  v_error text;
begin
  select id into v_store_id from public.stores where code = 'P31CST';
  select id into v_channel_id from public.collection_channels where key = 'p31c_channel';
  select id into v_pm_id from public.payment_methods where key = 'p31c_pm';
  select id into v_category_id from public.product_categories where code = 'p31ccat';

  -- Dedicated karat for L1, independent of J/J2's (already mutated by
  -- earlier sections).
  set role authenticated;
  perform set_config('request.jwt.claims', '{"sub":"d6000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  insert into public.karats (code, name_ar, sort_order, status) values ('P31CK_L1', 'عيار L1 هوتفكس 3.2.1', 974, 'active') returning id into v_karat_id;
  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 300.0000, 'd6000000-0000-4000-8000-000000000001');
  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, public.business_today(), 'p31c section L1 fixture');
  reset role;

  commit;

  perform dblink_connect('conn_a', current_setting('p31c.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p31c.dblink_conninfo') || ' dbname=' || current_database());

  -- A: creates a 2-item order for karat L1 (same shape as J2), stays OPEN,
  -- holding the SHARED financial-master lock for its whole resolution
  -- window.
  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"d6000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_exec('conn_a', format(
    $sql$do $inner$ begin perform public.create_sales_order('%s'::uuid, '%s'::date, '%s'::uuid, '%s'::uuid,
      '[{"category_id":"%s","karat_id":"%s","weight_grams":1.0,"sale_price":400.00},{"category_id":"%s","karat_id":"%s","weight_grams":2.0,"sale_price":800.00}]'::jsonb); end $inner$;$sql$,
    v_store_id, public.business_today(), v_pm_id, v_channel_id, v_category_id, v_karat_id, v_category_id, v_karat_id
  ));

  -- B: SET ROLE service_role, then a DIRECT UPDATE on daily_gold_prices for
  -- the SAME karat/date, while A's transaction is still open. Must BLOCK on
  -- A's shared financial-master lock (0073's trigger + 0081's grant) — not
  -- fail with "permission denied for function
  -- acquire_financial_master_lock_exclusive()".
  perform dblink_exec('conn_b', 'begin');
  perform dblink_exec('conn_b', 'set role service_role');
  perform dblink_send_query('conn_b', format(
    $sql$update public.daily_gold_prices set price_per_gram = 999.0000 where karat_id = '%s'::uuid and price_date = '%s'::date$sql$,
    v_karat_id, public.business_today()
  ));

  v_busy := public._p31c_wait_busy('conn_b');
  assert v_busy, 'FAIL L1: التحديث المباشر بدور service_role (اتصال B) على daily_gold_prices لم يُحجب رغم أن create_sales_order() (اتصال A) ما زال مفتوحًا بمعاملة لم تُلتزَم تستخدم نفس العيار/التاريخ — إما أن القفل لم يعمل، أو أن service_role فشل فورًا بخطأ صلاحيات بدل الانتظار (تحقّق أدناه)';

  perform dblink_exec('conn_a', 'commit');

  v_ready := public._p31c_wait_ready('conn_b');
  assert v_ready, 'FAIL L1: التحديث المباشر (اتصال B، service_role) لم يكتمل خلال المهلة بعد التزام A';

  -- If service_role still lacked EXECUTE on the lock helper, dblink_get_
  -- result() below would raise the underlying "permission denied for
  -- function acquire_financial_master_lock_exclusive" as a genuine SQL
  -- exception here (not a silent v_busy=false) -- assert this call does
  -- NOT raise, which is the actual regression this section exists to catch.
  begin
    perform public._p31c_drain_pending('conn_b');
    perform public._p31c_drain_pending('conn_b');
    v_error := null;
  exception when others then
    v_error := sqlerrm;
  end;
  assert v_error is null, format('FAIL L1: التحديث المباشر بدور service_role فشل بخطأ بدل النجاح بعد الانتظار — %s (هذا بالضبط الخلل الذي يُغلقه GRANT EXECUTE ... TO service_role في 0081)', coalesce(v_error, ''));

  perform dblink_exec('conn_b', 'commit');

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  select so.id into v_order_id from public.sales_orders so
    where so.store_id = v_store_id and so.sale_date = public.business_today()
      and exists (select 1 from public.sales_order_items it where it.sales_order_id = so.id and it.karat_id = v_karat_id)
    order by so.created_at desc limit 1;

  select count(*), count(*) filter (where gold_price_per_gram_snapshot = 300.0000)
    into v_item_count, v_price_used_count
    from public.sales_order_items where sales_order_id = v_order_id and status = 'active';

  assert v_item_count = 2, format('يجب أن تحتوي العملية على بندين، وجد %s', v_item_count);
  assert v_price_used_count = 2, format('FAIL L1: كلا البندين يجب أن يستخدما نفس سعر الذهب القديم (300.0000) رغم أن B (service_role) حدّث الجدول مباشرة — لا مزيج قديم/جديد ضمن نفس العملية، وجد %s بند فقط بالسعر القديم من أصل %s', v_price_used_count, v_item_count);

  -- Confirm B's write actually landed (proves it genuinely succeeded after
  -- waiting, not that it silently no-op'd).
  assert exists (select 1 from public.daily_gold_prices where karat_id = v_karat_id and price_date = public.business_today() and price_per_gram = 999.0000),
    'FAIL L1: تحديث B (service_role) لم يُطبَّق فعليًا على daily_gold_prices رغم عدم وجود خطأ';

  raise notice 'OK: L1 تحديث مباشر بدور service_role (اتصال B) على daily_gold_prices انتظر فعليًا حتى التزام create_sales_order() (اتصال A)، ثم نجح دون أي خطأ صلاحيات — إثبات أن GRANT EXECUTE ... TO service_role (0081) يُصلح المسار بالكامل: الانتظار ثم النجاح، لا رفض فوري';
end $$;

-- ============================================================================
-- L2) Hotfix 3.2.1 item 2 — sanity check: an ORDINARY service_role direct
-- write on daily_gold_prices with NO concurrent Sale in flight must simply
-- succeed outright (no blocking needed, no error) — proves 0081's grant
-- didn't just fix the blocked case above but the baseline unblocked case
-- too.
-- ============================================================================
do $$
declare
  v_karat_id uuid;
begin
  set role authenticated;
  perform set_config('request.jwt.claims', '{"sub":"d6000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  insert into public.karats (code, name_ar, sort_order, status) values ('P31CK_L2', 'عيار L2 هوتفكس 3.2.1', 975, 'active') returning id into v_karat_id;
  reset role;

  set role service_role;
  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram)
    values (public.business_today(), v_karat_id, 250.0000);
  update public.daily_gold_prices set price_per_gram = 251.0000 where karat_id = v_karat_id and price_date = public.business_today();
  reset role;

  assert exists (select 1 from public.daily_gold_prices where karat_id = v_karat_id and price_date = public.business_today() and price_per_gram = 251.0000),
    'FAIL L2: كتابة service_role العادية (بلا أي Sale متزامنة) على daily_gold_prices لم تنجح';

  commit;

  raise notice 'OK: L2 كتابة service_role مباشرة وعادية (بلا أي عملية بيع متزامنة) على daily_gold_prices نجحت دون أي خطأ صلاحيات';
end $$;

-- ============================================================================
-- K) Order number uniqueness under genuine parallel dispatch (spec items
-- 5/25/28): fires several create_sales_order() calls concurrently across
-- both connections; every order_number must be unique (SEQUENCE-based, not
-- MAX+1).
-- ============================================================================
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_numbers text[] := '{}'::text[];
  v_num text;
  v_round int;
  v_distinct_count int; v_total_count int;
begin
  select id into v_store_id from public.stores where code = 'P31CST';
  select id into v_karat_id from public.karats where code = 'P31CK1';
  select id into v_category_id from public.product_categories where code = 'p31ccat';
  select id into v_channel_id from public.collection_channels where key = 'p31c_channel';
  select id into v_pm_id from public.payment_methods where key = 'p31c_pm';

  perform dblink_connect('conn_a', current_setting('p31c.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p31c.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"d6000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"d6000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  for v_round in 1..4 loop
    -- Fire BOTH connections' calls before reading either result, so their
    -- execution genuinely overlaps rather than running strictly sequentially.
    perform dblink_send_query('conn_a', format(
      $sql$select order_number from public.create_sales_order('%s'::uuid, '%s'::date, '%s'::uuid, '%s'::uuid, '[{"category_id":"%s","karat_id":"%s","weight_grams":1.0,"sale_price":400.00}]'::jsonb)$sql$,
      v_store_id, public.business_today(), v_pm_id, v_channel_id, v_category_id, v_karat_id
    ));
    perform dblink_send_query('conn_b', format(
      $sql$select order_number from public.create_sales_order('%s'::uuid, '%s'::date, '%s'::uuid, '%s'::uuid, '[{"category_id":"%s","karat_id":"%s","weight_grams":1.0,"sale_price":400.00}]'::jsonb)$sql$,
      v_store_id, public.business_today(), v_pm_id, v_channel_id, v_category_id, v_karat_id
    ));

    perform public._p31c_wait_ready('conn_a');
    perform public._p31c_wait_ready('conn_b');

    select order_number into v_num from dblink_get_result('conn_a') as t(order_number text);
    v_numbers := array_append(v_numbers, v_num);
    perform public._p31c_drain_pending('conn_a');
    select order_number into v_num from dblink_get_result('conn_b') as t(order_number text);
    v_numbers := array_append(v_numbers, v_num);
    perform public._p31c_drain_pending('conn_b');
  end loop;

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  select count(*), count(distinct n) into v_total_count, v_distinct_count from unnest(v_numbers) as n;
  assert v_total_count = 8, format('يجب الحصول على 8 أرقام عمليات (4 جولات × اتصالين)، وجد %s', v_total_count);
  assert v_distinct_count = 8, format('FAIL K: يجب أن تكون كل أرقام العمليات الثمانية فريدة تحت إرسال متزامن حقيقي عبر اتصالين، وجد %s رقمًا فريدًا فقط من أصل %s', v_distinct_count, v_total_count);

  raise notice 'OK: K كل أرقام العمليات (%s) فريدة تحت إرسال متزامن حقيقي عبر اتصالين منفصلين — SEQUENCE، وليس MAX+1', v_total_count;
end $$;

-- ============================================================================
-- Cleanup — explicit, real DELETE (this file is not rollback-safe). Order
-- respects FK dependencies (items -> orders -> closings -> master data ->
-- store/profiles/permission overrides -> auth.users).
-- ============================================================================
do $$
declare v_store_ids uuid[];
begin
  -- Earlier sections set request.jwt.claims (non-locally, so it outlives
  -- its originating statement) to the P31C test actors' own uuids. Left as
  -- is, prevent_self_permission_override_modification() would read
  -- auth.uid() as one of those actors and block this cleanup from deleting
  -- that actor's own user_permission_overrides rows ("لا يمكنك تعديل
  -- استثناءات الصلاحيات الخاصة بحسابك أنت"). Clearing the claim first
  -- restores the trusted direct-SQL-connection context (auth.uid() is
  -- null), exactly like a fresh psql session.
  perform set_config('request.jwt.claims', '', false);

  select array_agg(id) into v_store_ids from public.stores where code in ('P31CST', 'P31CH1');

  delete from public.audit_logs where entity_id in (select id from public.sales_orders where store_id = any(v_store_ids));
  delete from public.audit_logs where entity_id in (select id from public.daily_closings where store_id = any(v_store_ids));
  delete from public.sales_order_items where sales_order_id in (select id from public.sales_orders where store_id = any(v_store_ids));
  delete from public.sales_orders where store_id = any(v_store_ids);
  delete from public.daily_closings where store_id = any(v_store_ids);
  delete from public.manufacturing_fee_versions where karat_id in (select id from public.karats where code like 'P31CK%');
  delete from public.payment_method_fee_versions where payment_method_id in (select id from public.payment_methods where key = 'p31c_pm');
  delete from public.daily_gold_prices where karat_id in (select id from public.karats where code like 'P31CK%');
  delete from public.karats where code like 'P31CK%';
  delete from public.product_categories where code = 'p31ccat';
  delete from public.collection_channels where key = 'p31c_channel';
  delete from public.payment_methods where key = 'p31c_pm';
  delete from public.stores where code in ('P31CST', 'P31CH1');
  delete from public.user_permission_overrides where user_id in ('d6000000-0000-4000-8000-000000000001', 'd6000000-0000-4000-8000-000000000002');
  delete from public.profiles where id in ('d6000000-0000-4000-8000-000000000001', 'd6000000-0000-4000-8000-000000000002');
  delete from auth.users where id in ('d6000000-0000-4000-8000-000000000001', 'd6000000-0000-4000-8000-000000000002');
end $$;

drop function if exists public._p31c_wait_busy(text, int, numeric);
drop function if exists public._p31c_wait_ready(text, int, numeric);
drop function if exists public._p31c_drain_pending(text);

do $$ begin raise notice 'OK: ALL Sales Integrity Patch 3.1 (Part 2, genuine multi-session concurrency) tests passed — fixtures cleaned up'; end $$;
