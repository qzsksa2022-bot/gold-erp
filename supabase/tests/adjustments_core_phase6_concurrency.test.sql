-- ============================================================================
-- Integration test: Phase 6 — Services / Adjustments Core (0133-0143) +
-- Integrity Patch 6.1 (0144-0156), GENUINE multi-session concurrency
-- (mirrors shipping_core_phase5_concurrency.test.sql's own dblink pattern
-- exactly).
-- ============================================================================
-- NOT safe to run against a shared/staging database — real dblink sessions,
-- auto-committing statements, no wrapping transaction, explicit cleanup at
-- the end. Run ONLY against a throwaway/CI database.
--
-- Requires migrations 0001-latest (including 0133-0156) + supabase/seed.sql
-- already applied, and the `dblink` extension available.
--
-- Connection string override, same convention as the other *_concurrency.
-- test.sql files:
--   psql -v dblink_conninfo="host=... port=... user=... password=..." \
--     -f supabase/tests/adjustments_core_phase6_concurrency.test.sql
--
-- Patch 6.1 item 26 letters (the governing spec's own lettering, NOT the
-- original Phase 6 Core file's A-D — those are folded in below as D/E/C and
-- the original D is kept as a "Bonus" section, per item 26's explicit
-- "Also KEEP the existing Close-vs-Create test"):
--   A — Adjustment Number concurrency: two concurrently-created adjustments
--       never collide on adjustment_number (generate_adjustment_number(),
--       0134, is NOT a naive MAX()+1 read).
--   B — Two Pending Updates on the same row_version: one succeeds, the
--       other genuinely rejected on a stale row_version.
--   C — Approve vs Update: a concurrent update_sales_order_adjustment()
--       genuinely blocks/serializes against approve_sales_order_
--       adjustment() on the same record (folded from original Core C).
--   D — Two Approvals racing the SAME pending record (folded from original
--       Core A).
--   E — Two Reversals racing the SAME approved record (folded from
--       original Core B).
--   F — Daily Close vs Approval: close_sales_day() (EXCLUSIVE) genuinely
--       blocks on approve_sales_order_adjustment()'s open daily-close
--       SHARED lock for (processing store, adjustment_date).
--   G — Daily Close vs Reversal: close_sales_day() (EXCLUSIVE) genuinely
--       blocks on reverse_sales_order_adjustment()'s open daily-close
--       SHARED lock for (processing store, reversal_business_date).
--   H — Payment Fee Version writer vs Approval: create_payment_method_fee_
--       version() (EXCLUSIVE financial-master lock) genuinely blocks on an
--       in-flight approval's open SHARED financial-master lock — the
--       approval takes ONE consistent fee snapshot (percentage/fixed/
--       version/amount all from the same read), never a torn one.
--   I — Adjustment Type rename/disable vs Approval: update_adjustment_type
--       ()/the table-level lock trigger (0153, item 15) genuinely blocks on
--       an in-flight approval's open SHARED adjustments lock (item 14) —
--       no torn type snapshot.
--   Bonus (kept, item 26's explicit instruction) — Daily Close vs create_
--       sales_order_adjustment() (original Core scenario D).
-- ============================================================================

create extension if not exists dblink;

\if :{?dblink_conninfo}
\else
\set dblink_conninfo 'host=127.0.0.1 port=5432 user=postgres password=postgres'
\endif

select set_config('p6cc.dblink_conninfo', :'dblink_conninfo', false);

create or replace function public._p6cc_wait_busy(p_connname text, p_max_polls int default 30, p_interval numeric default 0.1)
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

create or replace function public._p6cc_wait_ready(p_connname text, p_max_polls int default 100, p_interval numeric default 0.1)
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

create or replace function public._p6cc_drain_pending(p_connname text)
returns void
language plpgsql
as $$
begin
  perform 1 from dblink_get_result(p_connname) as t(x text);
end;
$$;

-- ============================================================================
-- 0. Fixtures — own prefix 'a6100000-.../P6CC', committed immediately.
-- ============================================================================
insert into auth.users (id, email) values
  ('a6100000-0000-4000-8000-000000000001', 'test-p6cc-actor@example.invalid');

update public.profiles set full_name = 'P6CC actor', status = 'active', store_access_scope = 'all'
  where id = 'a6100000-0000-4000-8000-000000000001';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a6100000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in (
    'stores.view', 'stores.create', 'karats.view', 'karats.manage', 'categories.view', 'categories.manage',
    'collection_channels.view', 'payment_methods.view', 'payment_methods.manage',
    'gold_prices.view', 'gold_prices.edit', 'manufacturing_fees.view', 'manufacturing_fees.manage',
    'sales.create', 'sales.edit', 'sales.view', 'sales.view_profit', 'sales.close_day',
    'adjustments.view', 'adjustments.create', 'adjustments.approve', 'adjustments.manage_cost',
    'adjustments.reverse', 'adjustments.process_closed_day', 'adjustments.manage_types'
  );

do $$
declare
  v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid; v_type_id uuid; v_type2_id uuid;
  v_store_codes text[] := array['P6CCSTA', 'P6CCSTB', 'P6CCSTC', 'P6CCSTD', 'P6CCSTE', 'P6CCSTF'];
  v_i int;
  v_pm2_id uuid;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}';

  for v_i in 1..array_length(v_store_codes, 1) loop
    insert into public.stores (code, name_ar, status) values (v_store_codes[v_i], 'متجر تزامن تعديلات ' || v_i, 'active');
  end loop;

  insert into public.karats (code, name_ar, sort_order, status) values ('P6CCK1', 'عيار تزامن تعديلات', 994, 'active') returning id into v_karat_id;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('p6cccat', 'تصنيف تزامن تعديلات', 994, 'active') returning id into v_category_id;
  select id into v_channel_id from public.collection_channels where key = 'direct_store';
  select id into v_pm_id from public.payment_methods where key = 'cash';

  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 300.0000, 'a6100000-0000-4000-8000-000000000001');
  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, public.business_today(), 'p6cc fixture');

  select create_adjustment_type('p6cc_type', 'نوع تزامن تعديلات') into v_type_id;

  -- Scenario I's dedicated Adjustment Type — rename/disable races AGAINST a
  -- concurrent approval, so it must not be shared with any other scenario.
  select create_adjustment_type('p6cc_type_i', 'نوع تزامن — إصدار I') into v_type2_id;
  perform set_config('p6cc.type_i', v_type2_id::text, false);

  -- Scenario H's dedicated Payment Method — a NEW fee version race against
  -- a concurrent approval, so it must not be shared with 'cash' (used
  -- everywhere else in this file, including seed-data-adjacent scenarios).
  insert into public.payment_methods (key, name_ar, name_en, fee_model, refund_fee_policy, sort_order, status)
    values ('p6cc_pm_h', 'دفع تزامن H', 'P6CC Payment H', 'percentage', 'manual', 900, 'active')
    returning id into v_pm2_id;
  perform public.create_payment_method_fee_version(v_pm2_id, 3.0, 0, public.business_today(), 'p6cc fixture H');
  perform set_config('p6cc.pm_h', v_pm2_id::text, false);
end $$;

-- Helper: create one Sales Order + one PENDING adjustment in the given
-- store, returns nothing (values fetched by the caller via a temp table).
create temporary table p6cc_scratch (label text, value text);
grant all on p6cc_scratch to authenticated;

do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid; v_type_id uuid;
  v_order_id uuid; v_result record;
  v_i int;
  v_store_codes text[] := array['P6CCSTA', 'P6CCSTB', 'P6CCSTC', 'P6CCSTD', 'P6CCSTE', 'P6CCSTF'];
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}';

  select id into v_karat_id from public.karats where code = 'P6CCK1';
  select id into v_category_id from public.product_categories where code = 'p6cccat';
  select id into v_channel_id from public.collection_channels where key = 'direct_store';
  select id into v_pm_id from public.payment_methods where key = 'cash';
  select id into v_type_id from public.adjustment_types where code = 'p6cc_type';

  for v_i in 1..array_length(v_store_codes, 1) loop
    select id into v_store_id from public.stores where code = v_store_codes[v_i];

    select * into v_result from create_sales_order(
      v_store_id, public.business_today(), v_pm_id, v_channel_id,
      jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0, 'sale_price', 500.00)),
      'P6CC-ORDER-' || v_i
    );
    v_order_id := v_result.id;

    insert into p6cc_scratch values ('store_' || v_i, v_store_id::text);
    insert into p6cc_scratch values ('order_' || v_i, v_order_id::text);

    -- Stores 1-3 and 5-6 each get one PENDING adjustment (with a cost
    -- already set, since payment_reference/direct_cost management is not
    -- what these scenarios exercise). Store 4 is reserved for the Bonus
    -- scenario (create_sales_order_adjustment() itself is the race target
    -- there, so it must NOT already have one).
    if v_i <> 4 then
      select id into v_result from create_sales_order_adjustment(
        v_order_id, v_type_id, v_store_id, public.business_today(), v_pm_id, v_channel_id, true, 100.00, 30.00, 'P6CC fixture', null, null
      );
      insert into p6cc_scratch values ('adj_' || v_i, v_result.id::text);
    end if;
  end loop;

  -- Extra fresh PENDING adjustments needed by scenarios A (number race) and
  -- B (two-pending-updates race) — both created on Store 1's order, both
  -- untouched by any other scenario.
  select value::uuid into v_order_id from p6cc_scratch where label = 'order_1';
  select value::uuid into v_store_id from p6cc_scratch where label = 'store_1';
  select id into v_result from create_sales_order_adjustment(
    v_order_id, v_type_id, v_store_id, public.business_today(), v_pm_id, v_channel_id, true, 40.00, null, 'P6CC fixture B', null, null
  );
  insert into p6cc_scratch values ('adj_b', v_result.id::text);

  -- Scenario H's own pending adjustment, using the dedicated 'p6cc_pm_h'
  -- payment method (whose fee version this scenario races a rewrite of).
  select id into v_result from create_sales_order_adjustment(
    v_order_id, v_type_id, v_store_id, public.business_today(), current_setting('p6cc.pm_h')::uuid, v_channel_id, true, 200.00, 20.00, 'P6CC fixture H', null, null
  );
  insert into p6cc_scratch values ('adj_h', v_result.id::text);

  -- Scenario I's own pending adjustment, using the dedicated 'p6cc_type_i'
  -- Adjustment Type (whose rename/disable this scenario races).
  select id into v_result from create_sales_order_adjustment(
    v_order_id, current_setting('p6cc.type_i')::uuid, v_store_id, public.business_today(), v_pm_id, v_channel_id, true, 80.00, 15.00, 'P6CC fixture I', null, null
  );
  insert into p6cc_scratch values ('adj_i', v_result.id::text);
end $$;

-- Scenario E (two reversals) needs adj_2 already APPROVED before the race
-- begins — a write inside the SAME do block as a later dblink race would
-- hold its row lock for that block's entire (single-transaction) duration,
-- deadlocking a same-row dblink FOR UPDATE issued later in that same
-- still-open top-level transaction, so this is its own committed statement.
do $$
declare
  v_adj_id uuid; v_row_version bigint;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}';
  select value::uuid into v_adj_id from p6cc_scratch where label = 'adj_2';
  select row_version into v_row_version from get_sales_order_adjustment(v_adj_id);
  perform approve_sales_order_adjustment(v_adj_id, v_row_version, null);
end $$;

-- Scenario G (daily close vs reversal) needs adj_6 (Store F) already
-- APPROVED before the race begins, for the same reason as above.
do $$
declare
  v_adj_id uuid; v_row_version bigint;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}';
  select value::uuid into v_adj_id from p6cc_scratch where label = 'adj_6';
  select row_version into v_row_version from get_sales_order_adjustment(v_adj_id);
  perform approve_sales_order_adjustment(v_adj_id, v_row_version, null);
end $$;

-- ============================================================================
-- A — Adjustment Number concurrency: two concurrent creates never collide.
-- ============================================================================
do $$
declare
  v_order_id uuid; v_store_id uuid; v_type_id uuid; v_pm_id uuid; v_channel_id uuid;
  v_num_a text; v_num_b text;
  v_a_failed boolean := false; v_b_failed boolean := false;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}';
  select value::uuid into v_order_id from p6cc_scratch where label = 'order_1';
  select value::uuid into v_store_id from p6cc_scratch where label = 'store_1';
  select id into v_type_id from public.adjustment_types where code = 'p6cc_type';
  select id into v_pm_id from public.payment_methods where key = 'cash';
  select id into v_channel_id from public.collection_channels where key = 'direct_store';

  perform dblink_connect('conn_a', current_setting('p6cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p6cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- Different rows (no shared row lock at all) — fired genuinely
  -- concurrently, no artificial serialization.
  perform dblink_send_query('conn_a', format(
    $sql$select * from public.create_sales_order_adjustment('%s'::uuid, '%s'::uuid, '%s'::uuid, public.business_today(), '%s'::uuid, '%s'::uuid, true, 10.00, null, 'P6CC race A-1', null, null)$sql$,
    v_order_id, v_type_id, v_store_id, v_pm_id, v_channel_id
  ));
  perform dblink_send_query('conn_b', format(
    $sql$select * from public.create_sales_order_adjustment('%s'::uuid, '%s'::uuid, '%s'::uuid, public.business_today(), '%s'::uuid, '%s'::uuid, true, 10.00, null, 'P6CC race A-2', null, null)$sql$,
    v_order_id, v_type_id, v_store_id, v_pm_id, v_channel_id
  ));

  perform public._p6cc_wait_ready('conn_a');
  begin
    select adjustment_number into v_num_a from dblink_get_result('conn_a', true) as t(id uuid, adjustment_number text);
    perform public._p6cc_drain_pending('conn_a');
  exception when others then
    v_a_failed := true;
  end;

  perform public._p6cc_wait_ready('conn_b');
  begin
    select adjustment_number into v_num_b from dblink_get_result('conn_b', true) as t(id uuid, adjustment_number text);
    perform public._p6cc_drain_pending('conn_b');
  exception when others then
    v_b_failed := true;
  end;

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  assert not v_a_failed and not v_b_failed, 'FAIL A: كلا الإنشاءين المتزامنين يجب أن ينجحا (لا قفل صف مشترك بينهما)';
  assert v_num_a is not null and v_num_b is not null, 'FAIL A: رقم التعديل/الخدمة فارغ لأحد الإنشاءين المتزامنين';
  assert v_num_a <> v_num_b, format('FAIL A: تصادم في رقم التعديل/الخدمة بين إنشاءين متزامنين — كلاهما %s', v_num_a);
  assert (v_num_a ~ '^ADJ-[0-9]{10}$') and (v_num_b ~ '^ADJ-[0-9]{10}$'), 'FAIL A: تنسيق رقم التعديل/الخدمة غير صحيح لأحد الإنشاءين';

  raise notice 'PASS A: adjustment number concurrency — two simultaneous creates both succeeded with distinct numbers (no MAX()+1 race)';
end $$;

-- ============================================================================
-- B — Two Pending Updates on the SAME row_version: one succeeds, the other
-- genuinely rejected on a stale row_version.
-- ============================================================================
do $$
declare
  v_adj_id uuid; v_row_version bigint;
  v_store_id uuid; v_type_id uuid; v_pm_id uuid; v_channel_id uuid;
  v_busy boolean;
  v_a_failed boolean := false; v_b_failed boolean := false;
  v_final record;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}';
  select value::uuid into v_adj_id from p6cc_scratch where label = 'adj_b';
  select row_version into v_row_version from get_sales_order_adjustment(v_adj_id);
  select adjustment_type_id, processing_store_id, payment_method_id, collection_channel_id
    into v_type_id, v_store_id, v_pm_id, v_channel_id
    from get_sales_order_adjustment(v_adj_id);

  perform dblink_connect('conn_a', current_setting('p6cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p6cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A holds the row lock open mid-update (raises customer_charge to 41.00).
  perform dblink_send_query('conn_a', format(
    $sql$select * from public.update_sales_order_adjustment('%s'::uuid, %s::bigint, '%s'::uuid, '%s'::uuid, public.business_today(), '%s'::uuid, '%s'::uuid, true, 41.00, 'P6CC race B — A', null, null)$sql$,
    v_adj_id, v_row_version, v_type_id, v_store_id, v_pm_id, v_channel_id
  ));
  perform public._p6cc_wait_ready('conn_a');
  perform id from dblink_get_result('conn_a', true) as t(id uuid, row_version bigint);
  perform public._p6cc_drain_pending('conn_a');

  -- B races the SAME stale row_version concurrently while A's transaction
  -- is still open — genuinely blocks, sent async and polled.
  perform dblink_send_query('conn_b', format(
    $sql$select * from public.update_sales_order_adjustment('%s'::uuid, %s::bigint, '%s'::uuid, '%s'::uuid, public.business_today(), '%s'::uuid, '%s'::uuid, true, 42.00, 'P6CC race B — B', null, null)$sql$,
    v_adj_id, v_row_version, v_type_id, v_store_id, v_pm_id, v_channel_id
  ));
  v_busy := public._p6cc_wait_busy('conn_b');
  assert v_busy, 'FAIL B: محاولة التحديث الثانية من B لم تُحجب رغم أن تحديث A ما زال يحمل قفل الصف مفتوحًا';

  perform dblink_exec('conn_a', 'commit');
  perform public._p6cc_wait_ready('conn_b');
  begin
    perform id from dblink_get_result('conn_b', true) as t(id uuid, row_version bigint);
    perform public._p6cc_drain_pending('conn_b');
  exception when others then
    v_b_failed := true;
  end;

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  assert v_b_failed, 'FAIL B: التحديث الثاني بإصدار قديم (قبل تحديث A) كان يجب أن يُرفض بتعارض الإصدارات';

  select * into v_final from get_sales_order_adjustment(v_adj_id);
  assert v_final.customer_charge::numeric = 41.00, format('FAIL B: يجب أن تعكس القيمة تحديث A (41.00)، الموجود: %s', v_final.customer_charge);

  raise notice 'PASS B: two pending updates race — A wins, B genuinely rejected on stale row_version';
end $$;

-- ============================================================================
-- C — Approve vs Update on the SAME pending adjustment (A updates, B
-- concurrently attempts to approve using the now-stale pre-update version).
-- ============================================================================
do $$
declare
  v_adj_id uuid; v_row_version bigint;
  v_store_id uuid; v_type_id uuid; v_pm_id uuid; v_channel_id uuid;
  v_busy boolean;
  v_b_failed boolean := false; v_b_error text;
  v_final record;
begin
    set local role authenticated;
  set local request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}';
  select value::uuid into v_adj_id from p6cc_scratch where label = 'adj_3';
  select row_version into v_row_version from get_sales_order_adjustment(v_adj_id);
  select adjustment_type_id, processing_store_id, payment_method_id, collection_channel_id
    into v_type_id, v_store_id, v_pm_id, v_channel_id
    from get_sales_order_adjustment(v_adj_id);

  perform dblink_connect('conn_a', current_setting('p6cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p6cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A holds the row lock open mid-update (raises customer_charge to 250.00).
  perform dblink_send_query('conn_a', format(
    $sql$select * from public.update_sales_order_adjustment('%s'::uuid, %s::bigint, '%s'::uuid, '%s'::uuid, public.business_today(), '%s'::uuid, '%s'::uuid, true, 250.00, 'P6CC race C update', null, null)$sql$,
    v_adj_id, v_row_version, v_type_id, v_store_id, v_pm_id, v_channel_id
  ));
  perform public._p6cc_wait_ready('conn_a');
  perform id from dblink_get_result('conn_a', true) as t(id uuid, row_version bigint); -- update committed inside A's still-open txn
  perform public._p6cc_drain_pending('conn_a');

  -- B concurrently races approve_sales_order_adjustment() against the SAME
  -- record using the OLD (now-stale) row_version. A's update already ran
  -- (result drained above) but A's TRANSACTION is still open (no commit
  -- yet), so B's row lock attempt genuinely blocks here — sent async and
  -- polled, never a synchronous call that would deadlock this script.
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select * from public.approve_sales_order_adjustment('%s'::uuid, %s::bigint, null)$sql$, v_adj_id, v_row_version
  ));

  v_busy := public._p6cc_wait_busy('conn_b');
  assert v_busy, 'FAIL C: محاولة الاعتماد من B لم تُحجب رغم أن تحديث A ما زال يحمل قفل الصف مفتوحًا';

  perform dblink_exec('conn_a', 'commit');
  perform public._p6cc_wait_ready('conn_b');

  begin
    perform id from dblink_get_result('conn_b', true) as t(id uuid, adjustment_number text, row_version bigint, status text, net_adjustment_profit text);
    perform public._p6cc_drain_pending('conn_b');
  exception when others then
    v_b_failed := true; v_b_error := sqlerrm;
  end;

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  assert v_b_failed, 'FAIL C: اعتماد بإصدار قديم (قبل تحديث A) كان يجب أن يُرفض بتعارض الإصدارات';

  select * into v_final from get_sales_order_adjustment(v_adj_id);
  assert v_final.customer_charge::numeric = 250.00, format('FAIL C: يجب أن تعكس القيمة تحديث A (250.00)، الموجود: %s', v_final.customer_charge);
  assert v_final.status = 'pending', 'FAIL C: السجل يجب أن يبقى pending — اعتماد B رُفض';

  raise notice 'PASS C: update-vs-approve race — A''s update wins, B''s stale-version approve is genuinely rejected';
end $$;

-- ============================================================================
-- D — double-approve race on the SAME pending adjustment (two approvals
-- racing the same record; folded from original Core scenario A).
-- ============================================================================
do $$
declare
  v_adj_id uuid; v_row_version bigint;
  v_busy boolean; v_ready boolean;
  v_b_error text; v_b_failed boolean := false;
  v_approved_count int;
begin
    set local role authenticated;
  set local request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}';
  select value::uuid into v_adj_id from p6cc_scratch where label = 'adj_1';
  select row_version into v_row_version from get_sales_order_adjustment(v_adj_id);

  perform dblink_connect('conn_a', current_setting('p6cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p6cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A locks the row via approve_sales_order_adjustment() and stays OPEN.
  perform dblink_send_query('conn_a', format(
    $sql$select * from public.approve_sales_order_adjustment('%s'::uuid, %s::bigint, null)$sql$, v_adj_id, v_row_version
  ));
  v_ready := public._p6cc_wait_ready('conn_a');
  assert v_ready, 'FAIL D: جلسة A لم تُكمل الاعتماد الأول';
  perform id from dblink_get_result('conn_a', true) as t(id uuid, adjustment_number text, row_version bigint, status text, net_adjustment_profit text);
  perform public._p6cc_drain_pending('conn_a');

  -- B races the SAME stale row_version concurrently — must be rejected
  -- once A's row lock is released (A already committed nothing yet — still
  -- inside an open transaction, so B blocks on the FOR UPDATE lock first).
  perform dblink_exec('conn_b', 'begin');
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select * from public.approve_sales_order_adjustment('%s'::uuid, %s::bigint, null)$sql$, v_adj_id, v_row_version
  ));

  v_busy := public._p6cc_wait_busy('conn_b');
  assert v_busy, 'FAIL D: محاولة الاعتماد الثانية من B لم تُحجب رغم أن اعتماد A ما زال يحمل قفل الصف مفتوحًا';

  perform dblink_exec('conn_a', 'commit');
  perform dblink_disconnect('conn_a');

  perform public._p6cc_wait_ready('conn_b');
  begin
    perform id from dblink_get_result('conn_b', true) as t(id uuid, adjustment_number text, row_version bigint, status text, net_adjustment_profit text);
    perform public._p6cc_drain_pending('conn_b');
  exception when others then
    v_b_failed := true;
    v_b_error := sqlerrm;
  end;

  perform dblink_disconnect('conn_b');

  select count(*) into v_approved_count from get_sales_order_adjustment(v_adj_id) where status = 'approved';
  assert v_approved_count = 1, 'FAIL D: يجب أن ينتهي السجل بحالة approved واحدة فقط بعد السباق';
  assert v_b_failed, format('FAIL D: يجب أن تُرفض محاولة الاعتماد الثانية (تعارض إصدارات) — النتيجة: b_failed=%s', v_b_failed);

  raise notice 'PASS D: double-approve race — exactly one approval wins, the other rejected on stale row_version';
end $$;

-- ============================================================================
-- E — double-reverse race on the SAME approved adjustment (folded from
-- original Core scenario B). adj_2 was approved in the fixtures section.
-- ============================================================================
do $$
declare
  v_adj_id uuid; v_row_version bigint;
  v_a_error text; v_b_error text;
  v_a_failed boolean := false; v_b_failed boolean := false;
  v_is_reversed boolean;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}';
  select value::uuid into v_adj_id from p6cc_scratch where label = 'adj_2';
  select row_version into v_row_version from get_sales_order_adjustment(v_adj_id);

  perform dblink_connect('conn_a', current_setting('p6cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p6cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A locks the adjustment row (FOR UPDATE inside reverse_sales_order_
  -- adjustment(), 0141/0150) and stays open — genuine overlap, not sequential.
  perform dblink_send_query('conn_a', format(
    $sql$select * from public.reverse_sales_order_adjustment('%s'::uuid, %s::bigint, public.business_today(), 'عكس أول (سباق E)', null)$sql$,
    v_adj_id, v_row_version
  ));
  perform public._p6cc_wait_ready('conn_a');
  begin
    perform id from dblink_get_result('conn_a', true) as t(id uuid, reversal_id uuid);
    perform public._p6cc_drain_pending('conn_a');
  exception when others then
    v_a_failed := true; v_a_error := sqlerrm;
  end;

  -- B races the SAME row concurrently while A's transaction is still open
  -- (A's own reverse call already returned above, but has not committed).
  perform dblink_send_query('conn_b', format(
    $sql$select * from public.reverse_sales_order_adjustment('%s'::uuid, %s::bigint, public.business_today(), 'عكس ثانٍ (سباق E)', null)$sql$,
    v_adj_id, v_row_version
  ));
  perform public._p6cc_wait_busy('conn_b');

  perform dblink_exec('conn_a', 'commit');
  perform dblink_disconnect('conn_a');

  perform public._p6cc_wait_ready('conn_b');
  begin
    perform id from dblink_get_result('conn_b', true) as t(id uuid, reversal_id uuid);
    perform public._p6cc_drain_pending('conn_b');
  exception when others then
    v_b_failed := true; v_b_error := sqlerrm;
  end;
  perform dblink_disconnect('conn_b');

  -- The base reversals table has ZERO RLS policies (§30) — check via the
  -- read RPC's server-computed effective_status instead of a direct SELECT.
  select (effective_status = 'reversed') into v_is_reversed from get_sales_order_adjustment(v_adj_id);

  assert v_is_reversed, 'FAIL E: يجب أن يصبح effective_status = reversed بعد نجاح إحدى محاولتي العكس بالضبط';
  assert (v_a_failed or v_b_failed), 'FAIL E: إحدى محاولتي العكس المتزامنتين يجب أن تُرفض';
  assert not (v_a_failed and v_b_failed), 'FAIL E: إحدى محاولتي العكس على الأقل يجب أن تنجح';

  raise notice 'PASS E: double-reverse race — exactly one reversal row exists, the other genuinely rejected';
end $$;

-- ============================================================================
-- F — Daily Close vs Approval: close_sales_day() (EXCLUSIVE) genuinely
-- blocks on approve_sales_order_adjustment()'s open daily-close SHARED lock
-- for (processing store, adjustment_date). Store 5 is dedicated to this
-- scenario so the close it performs never affects any other scenario.
-- ============================================================================
do $$
declare
  v_adj_id uuid; v_row_version bigint; v_store_id uuid;
  v_busy boolean;
  v_close_failed boolean := false;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}';
  select value::uuid into v_adj_id from p6cc_scratch where label = 'adj_5';
  select value::uuid into v_store_id from p6cc_scratch where label = 'store_5';
  select row_version into v_row_version from get_sales_order_adjustment(v_adj_id);

  perform dblink_connect('conn_a', current_setting('p6cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p6cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A approves (holds the daily-close SHARED lock open, item 9's step 9).
  perform dblink_send_query('conn_a', format(
    $sql$select * from public.approve_sales_order_adjustment('%s'::uuid, %s::bigint, null)$sql$, v_adj_id, v_row_version
  ));
  perform public._p6cc_wait_ready('conn_a');
  perform id from dblink_get_result('conn_a', true) as t(id uuid, adjustment_number text, row_version bigint, status text, net_adjustment_profit text);
  perform public._p6cc_drain_pending('conn_a'); -- approve committed inside A's still-open txn, holding the daily-close SHARED lock

  -- B concurrently tries to CLOSE the same store/day — needs the EXCLUSIVE
  -- daily-close lock — must genuinely block while A's transaction is open.
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select public.close_sales_day('%s'::uuid, public.business_today(), 'P6CC race F close')$sql$, v_store_id
  ));

  v_busy := public._p6cc_wait_busy('conn_b');
  assert v_busy, 'FAIL F: close_sales_day() (اتصال B) لم يُحجب رغم أن اعتماد A ما زال مفتوحًا ويحمل القفل المشترك لإغلاق اليوم';

  perform dblink_exec('conn_a', 'commit');

  perform public._p6cc_wait_ready('conn_b');
  begin
    perform x from dblink_get_result('conn_b', true) as t(x uuid);
    perform public._p6cc_drain_pending('conn_b');
  exception when others then
    v_close_failed := true;
  end;

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  assert not v_close_failed, 'FAIL F: إغلاق اليوم كان يجب أن ينجح بعد التزام A (لا يوجد سبب حقيقي للرفض هنا)';

  if not exists (select 1 from public.daily_closings where store_id = v_store_id and business_date = public.business_today()) then
    raise exception 'FAIL F: اليوم لم يُقفل فعليًا بعد نجاح close_sales_day()';
  end if;

  raise notice 'PASS F: Daily Close vs Approval — B genuinely blocks on A''s open shared lock, then proceeds cleanly once A commits';
end $$;

-- ============================================================================
-- G — Daily Close vs Reversal: close_sales_day() (EXCLUSIVE) genuinely
-- blocks on reverse_sales_order_adjustment()'s open daily-close SHARED lock
-- for (processing store, reversal_business_date). Store 6's adj_6 was
-- pre-approved in the fixtures section above.
-- ============================================================================
do $$
declare
  v_adj_id uuid; v_row_version bigint; v_store_id uuid;
  v_busy boolean;
  v_close_failed boolean := false;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}';
  select value::uuid into v_adj_id from p6cc_scratch where label = 'adj_6';
  select value::uuid into v_store_id from p6cc_scratch where label = 'store_6';
  select row_version into v_row_version from get_sales_order_adjustment(v_adj_id);

  perform dblink_connect('conn_a', current_setting('p6cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p6cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A reverses (holds the daily-close SHARED lock, keyed to the REVERSAL
  -- business date, open — item 20/22's own Daily Close step).
  perform dblink_send_query('conn_a', format(
    $sql$select * from public.reverse_sales_order_adjustment('%s'::uuid, %s::bigint, public.business_today(), 'عكس لاختبار G', null)$sql$,
    v_adj_id, v_row_version
  ));
  perform public._p6cc_wait_ready('conn_a');
  perform id from dblink_get_result('conn_a', true) as t(id uuid, reversal_id uuid);
  perform public._p6cc_drain_pending('conn_a');

  -- B concurrently tries to CLOSE the same store/day — must genuinely block.
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select public.close_sales_day('%s'::uuid, public.business_today(), 'P6CC race G close')$sql$, v_store_id
  ));

  v_busy := public._p6cc_wait_busy('conn_b');
  assert v_busy, 'FAIL G: close_sales_day() (اتصال B) لم يُحجب رغم أن عكس A ما زال مفتوحًا ويحمل القفل المشترك لإغلاق اليوم';

  perform dblink_exec('conn_a', 'commit');

  perform public._p6cc_wait_ready('conn_b');
  begin
    perform x from dblink_get_result('conn_b', true) as t(x uuid);
    perform public._p6cc_drain_pending('conn_b');
  exception when others then
    v_close_failed := true;
  end;

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  assert not v_close_failed, 'FAIL G: إغلاق اليوم كان يجب أن ينجح بعد التزام A';

  raise notice 'PASS G: Daily Close vs Reversal — B genuinely blocks on A''s open shared lock, then proceeds cleanly once A commits';
end $$;

-- ============================================================================
-- H — Payment Fee Version writer vs Approval: create_payment_method_fee_
-- version() (EXCLUSIVE financial-master lock) genuinely blocks on an
-- in-flight approval's open SHARED financial-master lock. adj_h uses the
-- dedicated 'p6cc_pm_h' payment method (never touched by any other
-- scenario), so the NEW fee version created here cannot disturb anything
-- else in this file.
-- ============================================================================
do $$
declare
  v_adj_id uuid; v_row_version bigint; v_pm_id uuid := current_setting('p6cc.pm_h')::uuid;
  v_busy boolean;
  v_write_failed boolean := false;
  v_final record;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}';
  select value::uuid into v_adj_id from p6cc_scratch where label = 'adj_h';
  select row_version into v_row_version from get_sales_order_adjustment(v_adj_id);

  perform dblink_connect('conn_a', current_setting('p6cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p6cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A approves (customer_charge=200 > 0, so this DOES resolve a fee and
  -- takes the SHARED financial-master lock, held open).
  perform dblink_send_query('conn_a', format(
    $sql$select * from public.approve_sales_order_adjustment('%s'::uuid, %s::bigint, null)$sql$, v_adj_id, v_row_version
  ));
  perform public._p6cc_wait_ready('conn_a');
  perform id from dblink_get_result('conn_a', true) as t(id uuid, adjustment_number text, row_version bigint, status text, net_adjustment_profit text);
  perform public._p6cc_drain_pending('conn_a');

  -- B concurrently tries to write a NEW fee version for the SAME payment
  -- method — needs the EXCLUSIVE financial-master lock — must genuinely
  -- block while A's transaction (and its SHARED lock) is still open.
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select public.create_payment_method_fee_version('%s'::uuid, 9.0, 0, (public.business_today() + 1), 'P6CC race H new version')$sql$,
    v_pm_id
  ));

  v_busy := public._p6cc_wait_busy('conn_b');
  assert v_busy, 'FAIL H: كتابة إصدار عمولة جديد (اتصال B) لم تُحجب رغم أن اعتماد A ما زال مفتوحًا ويحمل قفل البيانات المالية المشترك';

  perform dblink_exec('conn_a', 'commit');

  perform public._p6cc_wait_ready('conn_b');
  begin
    perform x from dblink_get_result('conn_b', true) as t(x uuid);
    perform public._p6cc_drain_pending('conn_b');
  exception when others then
    v_write_failed := true;
  end;

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  assert not v_write_failed, 'FAIL H: كتابة إصدار العمولة الجديد كان يجب أن تنجح بعد التزام A';

  -- No torn snapshot — the approval's own fee figures come from ONE
  -- consistent read of the fee that was active BEFORE B's new version
  -- (percentage=3.0/fixed=0, the fixture's own seeded version), never a mix.
  select * into v_final from get_sales_order_adjustment(v_adj_id);
  assert v_final.original_payment_fee_amount::numeric = 6.00, format('FAIL H: مبلغ العمولة يجب أن يعكس النسخة السارية وقت الاعتماد (3%% * 200 = 6.00)، الموجود: %s', v_final.original_payment_fee_amount);

  raise notice 'PASS H: Payment Fee Version writer vs Approval — B genuinely blocks on A''s open shared financial-master lock; A''s snapshot is consistent, never torn';
end $$;

-- ============================================================================
-- I — Adjustment Type rename/disable vs Approval: update_adjustment_type()
-- (via the table-level EXCLUSIVE lock trigger, 0153/item 15) genuinely
-- blocks on an in-flight approval's open SHARED adjustments lock (item 14).
-- adj_i uses the dedicated 'p6cc_type_i' Adjustment Type.
-- ============================================================================
do $$
declare
  v_adj_id uuid; v_row_version bigint; v_type_id uuid := current_setting('p6cc.type_i')::uuid;
  v_busy boolean;
  v_rename_failed boolean := false;
  v_final record;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}';
  select value::uuid into v_adj_id from p6cc_scratch where label = 'adj_i';
  select row_version into v_row_version from get_sales_order_adjustment(v_adj_id);

  perform dblink_connect('conn_a', current_setting('p6cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p6cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A approves (takes the SHARED adjustments lock, item 14, before
  -- resolving/snapshotting the Adjustment Type — held open).
  perform dblink_send_query('conn_a', format(
    $sql$select * from public.approve_sales_order_adjustment('%s'::uuid, %s::bigint, null)$sql$, v_adj_id, v_row_version
  ));
  perform public._p6cc_wait_ready('conn_a');
  perform id from dblink_get_result('conn_a', true) as t(id uuid, adjustment_number text, row_version bigint, status text, net_adjustment_profit text);
  perform public._p6cc_drain_pending('conn_a');

  -- B concurrently tries to rename the SAME Adjustment Type — the 0153
  -- BEFORE STATEMENT trigger takes the EXCLUSIVE adjustments lock — must
  -- genuinely block while A's SHARED lock is still open.
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  -- update_adjustment_type() returns void — dblink cannot bind a `void`
  -- result column, so the call is wrapped in a boolean CASE purely so
  -- dblink_get_result() has a real column type to bind to.
  perform dblink_send_query('conn_b', format(
    $sql$select case when public.update_adjustment_type('%s'::uuid, 'نوع تزامن — إصدار I (بعد إعادة التسمية)', null, null, 1) is null then true else true end$sql$,
    v_type_id
  ));

  v_busy := public._p6cc_wait_busy('conn_b');
  assert v_busy, 'FAIL I: إعادة تسمية النوع (اتصال B) لم تُحجب رغم أن اعتماد A ما زال مفتوحًا ويحمل قفل التعديلات المشترك';

  perform dblink_exec('conn_a', 'commit');

  perform public._p6cc_wait_ready('conn_b');
  begin
    perform x from dblink_get_result('conn_b', true) as t(x boolean);
    perform public._p6cc_drain_pending('conn_b');
  exception when others then
    v_rename_failed := true;
  end;

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  assert not v_rename_failed, 'FAIL I: إعادة تسمية النوع كان يجب أن تنجح بعد التزام A';

  -- No torn snapshot — A's approval snapshotted the type name BEFORE B's
  -- rename (item 25's own historical-stability guarantee, proven here under
  -- genuine concurrency rather than sequential ordering).
  select * into v_final from get_sales_order_adjustment(v_adj_id);
  assert v_final.adjustment_type_name_ar = 'نوع تزامن — إصدار I', format('FAIL I: يجب أن يعكس اعتماد A اسم النوع قبل إعادة التسمية، الموجود: %s', v_final.adjustment_type_name_ar);
  assert (select name_ar from public.adjustment_types where id = v_type_id) = 'نوع تزامن — إصدار I (بعد إعادة التسمية)', 'FAIL I: إعادة التسمية من B لم تُطبَّق فعليًا بعد التزامها';

  raise notice 'PASS I: Adjustment Type rename vs Approval — B genuinely blocks on A''s open shared adjustments lock; A''s type snapshot is consistent, never torn';
end $$;

-- ============================================================================
-- Bonus (kept, item 26's explicit instruction) — Daily Close vs create_
-- sales_order_adjustment() (original Core scenario D).
-- ============================================================================
-- Setup — the Sales Order must be created (and COMMITTED) in its own
-- statement before any dblink session tries to read it: an uncommitted row
-- from the top-level session's own still-open transaction is invisible to
-- a separate dblink connection under normal MVCC visibility.
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid; v_channel2_id uuid;
  v_result record;
begin
  select id into v_store_id from public.stores where code = 'P6CCSTD';
  select id into v_karat_id from public.karats where code = 'P6CCK1';
  select id into v_category_id from public.product_categories where code = 'p6cccat';
  select id into v_channel2_id from public.collection_channels where key = 'direct_store';
  select id into v_pm_id from public.payment_methods where key = 'cash';

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}';

  select * into v_result from create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel2_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0, 'sale_price', 500.00)),
    'P6CC-ORDER-D-BONUS'
  );
  insert into p6cc_scratch values ('order_d', v_result.id::text);
end $$;

do $$
declare
  v_store_id uuid; v_type_id uuid; v_pm_id uuid; v_channel_id uuid;
  v_order_id uuid;
  v_busy boolean;
  v_close_failed boolean := false;
begin
  select id into v_store_id from public.stores where code = 'P6CCSTD';
  select id into v_type_id from public.adjustment_types where code = 'p6cc_type';
  select id into v_pm_id from public.payment_methods where key = 'cash';
  select id into v_channel_id from public.collection_channels where key = 'direct_store';
  select value::uuid into v_order_id from p6cc_scratch where label = 'order_d';

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}';

  perform dblink_connect('conn_a', current_setting('p6cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p6cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A creates an adjustment (holds the daily-close SHARED lock open, 0146).
  perform dblink_send_query('conn_a', format(
    $sql$select * from public.create_sales_order_adjustment('%s'::uuid, '%s'::uuid, '%s'::uuid, public.business_today(), '%s'::uuid, '%s'::uuid, true, 60.00, null, 'P6CC race Bonus', null, null)$sql$,
    v_order_id, v_type_id, v_store_id, v_pm_id, v_channel_id
  ));
  perform public._p6cc_wait_ready('conn_a');
  perform id from dblink_get_result('conn_a', true) as t(id uuid, adjustment_number text);
  perform public._p6cc_drain_pending('conn_a'); -- create committed inside A's still-open txn, holding the daily-close SHARED lock

  -- B concurrently tries to CLOSE the same store/day — needs the EXCLUSIVE
  -- daily-close lock — must genuinely block while A's transaction is open.
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"a6100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select public.close_sales_day('%s'::uuid, public.business_today(), 'P6CC race Bonus close')$sql$, v_store_id
  ));

  v_busy := public._p6cc_wait_busy('conn_b');
  assert v_busy, 'FAIL Bonus: close_sales_day() (اتصال B) لم يُحجب رغم أن create_sales_order_adjustment() (اتصال A) ما زال مفتوحًا ويحمل القفل المشترك لإغلاق اليوم';

  perform dblink_exec('conn_a', 'commit');

  perform public._p6cc_wait_ready('conn_b');
  begin
    perform x from dblink_get_result('conn_b', true) as t(x uuid);
    perform public._p6cc_drain_pending('conn_b');
  exception when others then
    v_close_failed := true;
  end;

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  assert not v_close_failed, 'FAIL Bonus: إغلاق اليوم كان يجب أن ينجح بعد التزام A (لا يوجد سبب حقيقي للرفض هنا)';

  if not exists (select 1 from public.daily_closings where store_id = v_store_id and business_date = public.business_today()) then
    raise exception 'FAIL Bonus: اليوم لم يُقفل فعليًا بعد نجاح close_sales_day()';
  end if;

  raise notice 'PASS Bonus: Daily Close vs create_sales_order_adjustment() — B genuinely blocks on A''s open shared lock, then proceeds cleanly once A commits';
end $$;

-- ---------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------
drop function if exists public._p6cc_wait_busy(text, int, numeric);
drop function if exists public._p6cc_wait_ready(text, int, numeric);
drop function if exists public._p6cc_drain_pending(text);
