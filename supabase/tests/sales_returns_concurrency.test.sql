-- ============================================================================
-- Integration test: Phase 4 — Returns Integrity Patch 4.1, GENUINE
-- multi-session concurrency (mirrors sales_integrity_patch_3_1_concurrency.
-- test.sql's own dblink pattern exactly)
-- ============================================================================
-- NOT safe to run against a shared/staging database — see that file's
-- header for the full rationale (real dblink sessions, auto-committing
-- statements, no wrapping transaction, explicit cleanup at the end).
--
-- Run ONLY against a throwaway/CI database. Requires migrations 0001-latest
-- (including Hotfix 4.2.1's 0106-0112) + supabase/seed.sql already applied,
-- and the `dblink` extension available.
--
-- Connection string override, same convention as the Patch 3.1 file:
--   psql -v dblink_conninfo="host=... port=... user=... password=..." \
--     -f supabase/tests/sales_returns_concurrency.test.sql
--
-- Covers:
--   R1 — Effective-claim exclusivity under genuine concurrency (Section 5):
--        two PENDING returns already coexist on the SAME sales_order_
--        item_id (this alone is now allowed, unlike pre-Patch-4.1 — see
--        sales_returns_core.test.sql's scenario A). Two sessions then race
--        to APPROVE each of the two returns concurrently.
--        acquire_returns_order_lock_exclusive() (0082, keyed by
--        sales_order_id, shared by both returns since they reference the
--        same order) genuinely blocks the second session's approval for
--        the full duration of the first's open transaction; once the first
--        commits, the second's approval proceeds and is rejected by the
--        real DB constraint (sales_return_items_effective_claim_uq, 0092)
--        — never a silent double-effective-claim under real parallel
--        dispatch.
--   R2 — Daily Close vs create_sales_return race (reuses Sales' own
--        acquire_daily_close_lock_shared/exclusive, 0065): close_sales_day()
--        genuinely blocks while a same-(store,day) create_sales_return()
--        transaction is still open, and only proceeds after it commits.
--   R3 — Section 19 lock-order proof: update_sales_order() (0084) and
--        approve_sales_return() (0095) both take "sales_orders row FOR
--        UPDATE, THEN the returns advisory lock" in that exact order —
--        never the reverse. Racing them against each other on the SAME
--        order must always resolve by ordinary blocking (one waits, then
--        proceeds), and must NEVER raise a Postgres deadlock error
--        (which would abort one side with SQLSTATE 40P01). This is the
--        actual proof asked for by Section 19, not just a logical
--        argument.
--
-- Patch 4.2 (Section 9) additions — genuine concurrent refund-ledger
-- mutation races, proving the fixed lock order established by migration
-- 0103 (parent sales_returns row FOR UPDATE first, always) actually
-- prevents record/reverse/finalize/reopen from ever interleaving:
--   R4 — Scenario A: session A finalizes a matched reconciliation and stays
--        open; session B's concurrent record_sales_return_refund() must
--        BLOCK for the full duration of A's open transaction, then be
--        REJECTED once A commits (reconciliation is now finalized) — never
--        silently invalidate the finalized snapshot.
--   R5 — Scenario B: same shape as R4, but B's concurrent call is
--        reverse_sales_return_refund_event() on an still-active event —
--        blocks, then rejected after A commits.
--   R6 — Scenario C: after a legitimate reopen, session A records an
--        additional refund and stays open; session B's concurrent
--        finalize_sales_return_refund() must BLOCK on the same parent-row
--        lock, then — once A commits — compute actual_refunded_total from
--        the now-fully-committed ledger (never a stale pre-lock snapshot),
--        proving there is no reachable state where the Finalized snapshot
--        disagrees with the real ledger total.
--
-- Hotfix 4.2.1 (Section 19) addition — genuine concurrent double-reversal
-- race against the append-only reversal ledger (0106/0107):
--   R7 — TWO sessions concurrently call reverse_sales_return_refund_event()
--        on the SAME still-active event. The lock order (parent sales_
--        returns row FOR UPDATE first) makes the second session block for
--        the full duration of the first's open transaction; once the first
--        commits, the second is rejected by the real "already reversed"
--        check (backstopped by unique(refund_event_id) on sales_return_
--        refund_event_reversals) — exactly ONE reversal row ever exists for
--        the event, never two, even under genuine parallel dispatch.
-- ============================================================================

create extension if not exists dblink;

\if :{?dblink_conninfo}
\else
\set dblink_conninfo 'host=127.0.0.1 port=5432 user=postgres password=postgres'
\endif

select set_config('p4c.dblink_conninfo', :'dblink_conninfo', false);

-- ---------------------------------------------------------------------------
-- Polling helpers — identical pattern to _p31c_wait_busy/_wait_ready/
-- _drain_pending (own name prefix so both files can coexist in the same
-- database without colliding), dropped at the end.
-- ---------------------------------------------------------------------------
create or replace function public._p4c_wait_busy(p_connname text, p_max_polls int default 30, p_interval numeric default 0.1)
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

create or replace function public._p4c_wait_ready(p_connname text, p_max_polls int default 100, p_interval numeric default 0.1)
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

create or replace function public._p4c_drain_pending(p_connname text)
returns void
language plpgsql
as $$
begin
  perform 1 from dblink_get_result(p_connname) as t(x text);
end;
$$;

-- ============================================================================
-- 0. Fixtures — own prefix 'P4C', committed immediately (no wrapping
-- transaction) so both dblink sessions can see them right away.
-- ============================================================================
insert into auth.users (id, email) values
  ('da000000-0000-4000-8000-000000000001', 'test-p4c-a@example.invalid'),
  ('da000000-0000-4000-8000-000000000002', 'test-p4c-b@example.invalid');

update public.profiles set full_name = 'P4C actor A', status = 'active', store_access_scope = 'all'
  where id = 'da000000-0000-4000-8000-000000000001';
update public.profiles set full_name = 'P4C actor B', status = 'active', store_access_scope = 'all'
  where id = 'da000000-0000-4000-8000-000000000002';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'da000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in (
    'stores.view', 'stores.create', 'karats.view', 'karats.manage', 'categories.view', 'categories.manage',
    'collection_channels.view', 'collection_channels.manage', 'payment_methods.view', 'payment_methods.manage',
    'gold_prices.view', 'gold_prices.edit', 'manufacturing_fees.view', 'manufacturing_fees.manage',
    'sales.create', 'sales.edit', 'sales.view', 'sales.view_profit', 'sales.close_day',
    'returns.view', 'returns.create', 'returns.approve'
  );

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'da000000-0000-4000-8000-000000000002', id, 'grant' from public.permissions
  where key in ('sales.view', 'sales.edit', 'returns.view', 'returns.create', 'returns.approve', 'sales.close_day', 'stores.view');

do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"da000000-0000-4000-8000-000000000001","role":"authenticated"}';

  insert into public.stores (code, name_ar, status) values ('P4CST', 'متجر تزامن مرتجعات', 'active') returning id into v_store_id;
  -- Second store dedicated to R3 — R2 closes P4CST's business_today(), so
  -- R3 (which runs after R2) needs its own never-closed store.
  insert into public.stores (code, name_ar, status) values ('P4CST2', 'متجر تزامن مرتجعات 2', 'active');
  insert into public.karats (code, name_ar, sort_order, status) values ('P4CK1', 'عيار تزامن مرتجعات', 995, 'active') returning id into v_karat_id;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('p4ccat', 'تصنيف تزامن مرتجعات', 995, 'active') returning id into v_category_id;
  insert into public.collection_channels (key, name_ar, sort_order, status) values ('p4c_channel', 'قناة تزامن مرتجعات', 995, 'active') returning id into v_channel_id;
  insert into public.payment_methods (key, name_ar, fee_model, refund_fee_policy, sort_order, status)
    values ('p4c_pm', 'دفع تزامن مرتجعات', 'percentage', 'proportional_reversal', 995, 'active') returning id into v_pm_id;

  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 300.0000, 'da000000-0000-4000-8000-000000000001');
  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, public.business_today(), 'p4c fixture');
  perform public.create_payment_method_fee_version(v_pm_id, 10, 0, public.business_today(), 'p4c fixture');
end $$;

-- ============================================================================
-- R1 — Effective-claim exclusivity under genuine concurrency (Section 5)
-- ============================================================================
-- Order+item creation, and BOTH pending returns, are each their OWN
-- top-level statement (own implicit transaction, fully committed before the
-- next runs) — creating two PENDING returns on the same item no longer
-- conflicts at all under Patch 4.1 (unlike the pre-Patch-4.1 version of
-- this test), so this can safely happen sequentially, single-connection,
-- before the real concurrency race (which is now at APPROVAL time) begins.
-- Tagged 'P4C-R1' via customer_name so the next block can find it with a
-- plain superuser SELECT (sales_orders/sales_order_items have zero
-- direct-SELECT RLS for `authenticated`, but this script's default
-- connection role — before any `set local role` — is the superuser it
-- connected as, which bypasses RLS same as `reset role` elsewhere in this
-- project's test suite).
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_order_id uuid; v_item_id uuid;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"da000000-0000-4000-8000-000000000001","role":"authenticated"}';

  select id into v_store_id from public.stores where code = 'P4CST';
  select id into v_karat_id from public.karats where code = 'P4CK1';
  select id into v_category_id from public.product_categories where code = 'p4ccat';
  select id into v_channel_id from public.collection_channels where key = 'p4c_channel';
  select id into v_pm_id from public.payment_methods where key = 'p4c_pm';

  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0, 'sale_price', 400.00)),
    'P4C-R1'
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  perform public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 400.00
  );
  perform public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'customer_changed_mind',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 400.00
  );
end $$;

do $$
declare
  v_order_id uuid; v_return_1 uuid; v_return_2 uuid; v_row_version_1 bigint; v_row_version_2 bigint;
  v_busy boolean; v_ready boolean;
  v_b_failed boolean := false;
  v_b_error text;
begin
  select id into v_order_id from public.sales_orders where customer_name = 'P4C-R1';
  -- Distinguish the two returns by their distinct scenario (NOT
  -- created_at — both were created in the same transaction and can share
  -- an identical now()-derived timestamp, which would make asc/desc
  -- ordering ambiguous).
  select id, row_version into v_return_1, v_row_version_1 from public.sales_returns where sales_order_id = v_order_id and scenario = 'defective_product';
  select id, row_version into v_return_2, v_row_version_2 from public.sales_returns where sales_order_id = v_order_id and scenario = 'customer_changed_mind';

  perform dblink_connect('conn_a', current_setting('p4c.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p4c.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"da000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A approves the FIRST return and stays OPEN (no commit yet) —
  -- acquire_returns_order_lock_exclusive() for this order is held for the
  -- rest of A's transaction (Section 19 lock order: sales_returns row ->
  -- sales_orders row -> advisory lock).
  perform dblink_exec('conn_a', format(
    $sql$do $inner$ begin perform public.approve_sales_return('%s'::uuid, %s::bigint); end $inner$;$sql$,
    v_return_1, v_row_version_1
  ));

  -- B attempts to approve the SECOND return on the SAME order/item,
  -- asynchronously.
  perform dblink_exec('conn_b', 'begin');
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"da000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select id, return_number from public.approve_sales_return('%s'::uuid, %s::bigint)$sql$,
    v_return_2, v_row_version_2
  ));

  v_busy := public._p4c_wait_busy('conn_b');
  assert v_busy, 'FAIL R1: approve_sales_return() (اتصال B) لم يُحجب رغم أن approve_sales_return() (اتصال A) ما زال مفتوحًا بمعاملة لم تُلتزَم لنفس الطلب — acquire_returns_order_lock_exclusive() لم يعمل';

  perform dblink_exec('conn_a', 'commit');

  v_ready := public._p4c_wait_ready('conn_b');
  assert v_ready, 'FAIL R1: approve_sales_return() (اتصال B) لم يكتمل خلال المهلة بعد التزام A';

  begin
    perform id from dblink_get_result('conn_b', true) as t(id uuid, return_number text);
    v_b_failed := false;
  exception when others then
    v_b_failed := true;
    v_b_error := sqlerrm;
  end;
  perform public._p4c_drain_pending('conn_b');
  perform dblink_exec('conn_b', 'commit');

  assert v_b_failed, 'FAIL R1: كان يجب أن يفشل اعتماد اتصال B بعد أن التزم اتصال A باعتماد المرتجع الآخر على نفس البند أولاً';
  assert v_b_error like '%هذه القطعة مرتجعة بالفعل%', format('FAIL R1: رسالة خطأ B غير متوقعة: %s', v_b_error);

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  raise notice 'OK: R1 اتصال B حُجب فعليًا طوال معاملة A المفتوحة على نفس الطلب، ثم فشل بعد الالتزام برسالة واضحة (فهرس sales_return_items_effective_claim_uq الفريد) — لا ازدواج مطالبات فعّالة ممكن حتى تحت تزامن حقيقي (%)', v_b_error;
end $$;

-- ============================================================================
-- R2 — Daily Close vs create_sales_return race
-- ============================================================================
-- Order+item creation as its own committed top-level statement — same
-- reasoning as R1 above.
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_order_id uuid;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"da000000-0000-4000-8000-000000000001","role":"authenticated"}';

  select id into v_store_id from public.stores where code = 'P4CST';
  select id into v_karat_id from public.karats where code = 'P4CK1';
  select id into v_category_id from public.product_categories where code = 'p4ccat';
  select id into v_channel_id from public.collection_channels where key = 'p4c_channel';
  select id into v_pm_id from public.payment_methods where key = 'p4c_pm';

  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0, 'sale_price', 250.00)),
    'P4C-R2'
  );
end $$;

do $$
declare
  v_store_id uuid;
  v_order_id uuid; v_item_id uuid; v_close_day date;
  v_busy boolean; v_ready boolean;
  v_closing_count int;
begin
  v_close_day := public.business_today();
  select id into v_store_id from public.stores where code = 'P4CST';
  select id into v_order_id from public.sales_orders where store_id = v_store_id and customer_name = 'P4C-R2';
  select id into v_item_id from public.sales_order_items where sales_order_id = v_order_id and status = 'active';

  perform dblink_connect('conn_a', current_setting('p4c.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p4c.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"da000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A opens a return for this exact (processed_store_id, return_date) and
  -- stays OPEN — holds the SHARED daily-close lock for the rest of its txn.
  perform dblink_exec('conn_a', format(
    $sql$do $inner$ begin perform public.create_sales_return(
      '%s'::uuid, '%s'::uuid, '%s'::date, 'defective_product',
      jsonb_build_array(jsonb_build_object('sales_order_item_id', '%s'::uuid)),
      %s::bigint, 'collected', 250.00
    ); end $inner$;$sql$,
    v_order_id, v_store_id, v_close_day, v_item_id,
    (select row_version from public.sales_orders where id = v_order_id)
  ));

  -- B attempts to close the SAME (store, day), asynchronously.
  perform dblink_exec('conn_b', 'begin');
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"da000000-0000-4000-8000-000000000002","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select public.close_sales_day('%s'::uuid, '%s'::date, 'R2 concurrency test')$sql$,
    v_store_id, v_close_day
  ));

  v_busy := public._p4c_wait_busy('conn_b');
  assert v_busy, 'FAIL R2: close_sales_day() (اتصال B) لم يُحجب رغم أن create_sales_return() (اتصال A) ما زال مفتوحًا لنفس المتجر/اليوم';

  perform dblink_exec('conn_a', 'commit');

  v_ready := public._p4c_wait_ready('conn_b');
  assert v_ready, 'FAIL R2: close_sales_day() (اتصال B) لم يكتمل خلال المهلة بعد التزام A';

  perform closing_id from dblink_get_result('conn_b', true) as t(closing_id uuid);
  perform public._p4c_drain_pending('conn_b');
  perform dblink_exec('conn_b', 'commit');

  select count(*) into v_closing_count from public.daily_closings where store_id = v_store_id and business_date = v_close_day;
  assert v_closing_count = 1, format('FAIL R2: يجب أن يكون اليوم مغلقًا الآن بعد نجاح B، وجد %s صف إغلاق', v_closing_count);

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  raise notice 'OK: R2 close_sales_day() انتظر فعليًا حتى التزام create_sales_return() المفتوحة (بتوقيع jsonb الجديد) لنفس المتجر/اليوم قبل أن يتابع — القفل المشترك/الحصري لـReturns مطابق تمامًا لآلية Sales';
end $$;

-- ============================================================================
-- R3 — Section 19 lock-order proof: approve_sales_return() vs
-- update_sales_order(), raced against each other on the SAME order, must
-- resolve by ordinary blocking and NEVER raise a Postgres deadlock
-- (SQLSTATE 40P01).
-- ============================================================================
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_order_id uuid;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"da000000-0000-4000-8000-000000000001","role":"authenticated"}';

  select id into v_store_id from public.stores where code = 'P4CST2';
  select id into v_karat_id from public.karats where code = 'P4CK1';
  select id into v_category_id from public.product_categories where code = 'p4ccat';
  select id into v_channel_id from public.collection_channels where key = 'p4c_channel';
  select id into v_pm_id from public.payment_methods where key = 'p4c_pm';

  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(
      jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0, 'sale_price', 300.00),
      jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0, 'sale_price', 300.00)
    ),
    'P4C-R3'
  );
end $$;

-- A pending return on item A only — its OWN top-level statement (own
-- committed transaction, fully visible to conn_a's genuinely separate
-- session below) so the race further down is purely about lock ORDER, not
-- creation. Tagged via the order's customer_name (P4C-R3), same convention
-- as R1/R2 above.
do $$
declare
  v_store_id uuid;
  v_order_id uuid; v_item_a uuid;
begin
  set local request.jwt.claims = '{"sub":"da000000-0000-4000-8000-000000000001","role":"authenticated"}';

  select id into v_store_id from public.stores where code = 'P4CST2';
  select id into v_order_id from public.sales_orders where store_id = v_store_id and customer_name = 'P4C-R3';
  select id into v_item_a from public.sales_order_items where sales_order_id = v_order_id and status = 'active' order by line_no asc limit 1;

  perform public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_a)),
    (select row_version from public.sales_orders where id = v_order_id), 'collected', 300.00
  );
end $$;

do $$
declare
  v_store_id uuid;
  v_order_id uuid; v_item_a uuid; v_item_b uuid; v_return_id uuid; v_row_version bigint;
  v_payment_method_id uuid; v_collection_channel_id uuid; v_items jsonb; v_order_row_version bigint;
  v_busy boolean; v_ready boolean;
  v_a_error text; v_a_failed boolean := false;
  v_b_error text; v_b_failed boolean := false;
begin
  -- Default connecting (superuser) role — same rationale as R1/R2's own
  -- second blocks above: these plain SELECTs against sales_orders/sales_
  -- order_items/sales_returns need superuser's RLS bypass (those tables
  -- have zero direct SELECT RLS policies for `authenticated`). Every value
  -- B's update_sales_order() call needs is resolved HERE (as superuser,
  -- outside conn_b's `authenticated` role) and spliced in as a literal —
  -- embedding these as subqueries inside conn_b's own dispatched SQL would
  -- silently read back NULL under RLS once conn_b is `set role
  -- authenticated`, which is a test-harness pitfall, not a product bug.
  select id into v_store_id from public.stores where code = 'P4CST2';
  select id into v_order_id from public.sales_orders where store_id = v_store_id and customer_name = 'P4C-R3';
  select id into v_item_a from public.sales_order_items where sales_order_id = v_order_id and status = 'active' order by line_no asc limit 1;
  select id into v_item_b from public.sales_order_items where sales_order_id = v_order_id and status = 'active' order by line_no desc limit 1;
  select id, row_version into v_return_id, v_row_version from public.sales_returns where sales_order_id = v_order_id;

  select payment_method_id, collection_channel_id, row_version into v_payment_method_id, v_collection_channel_id, v_order_row_version
  from public.sales_orders where id = v_order_id;
  select jsonb_agg(jsonb_build_object('id', soi.id, 'category_id', soi.category_id, 'karat_id', soi.karat_id, 'weight_grams', soi.weight_grams, 'sale_price', soi.sale_price))
  into v_items
  from public.sales_order_items soi where soi.sales_order_id = v_order_id and soi.status = 'active';

  perform dblink_connect('conn_a', current_setting('p4c.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p4c.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"da000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A approves the return on item A — locks: sales_returns row -> sales_
  -- orders row FOR UPDATE -> advisory lock -> sales_order_items rows —
  -- and stays OPEN.
  perform dblink_exec('conn_a', format(
    $sql$do $inner$ begin perform public.approve_sales_return('%s'::uuid, %s::bigint); end $inner$;$sql$,
    v_return_id, v_row_version
  ));

  -- B concurrently attempts a METADATA-ONLY update_sales_order() on the
  -- SAME order (customer_name change, items resupplied UNCHANGED — no
  -- actual financial field differs, so it would succeed once it gets in
  -- even with an approved return present) — update_sales_order() locks
  -- sales_orders row FOR UPDATE first (0084's own established order),
  -- which is the SAME resource A already holds, so B must block here,
  -- never deadlock (both always take sales_orders row before the advisory
  -- lock — same order, no cycle).
  perform dblink_exec('conn_b', 'begin');
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"da000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select id from public.update_sales_order(
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::jsonb,
      'اسم عميل معدَّل من B', null, null, null,
      %s::bigint
    )$sql$,
    v_order_id, v_payment_method_id, v_collection_channel_id, v_items, v_order_row_version
  ));

  v_busy := public._p4c_wait_busy('conn_b');
  assert v_busy, 'FAIL R3: update_sales_order() (اتصال B) لم يُحجب رغم أن approve_sales_return() (اتصال A) ما زال مفتوحًا ويحمل قفل صف sales_orders لنفس الطلب';

  perform dblink_exec('conn_a', 'commit');

  v_ready := public._p4c_wait_ready('conn_b');
  assert v_ready, 'FAIL R3: update_sales_order() (اتصال B) لم يكتمل خلال المهلة بعد التزام A — احتمال طريق مسدود (deadlock) لم يُكتشف بواسطة Postgres نفسه';

  begin
    perform id from dblink_get_result('conn_b', true) as t(id uuid);
    v_b_failed := false;
  exception when others then
    v_b_failed := true;
    v_b_error := sqlerrm;
  end;
  perform public._p4c_drain_pending('conn_b');
  perform dblink_exec('conn_b', 'commit');

  -- B resupplies IDENTICAL item values (no actual financial change), so
  -- update_sales_order()'s financial-lock guard has nothing to reject —
  -- B is expected to SUCCEED here once it gets the lock. The critical
  -- proof for Section 19 is NOT whether B succeeds or fails on business
  -- logic — it's that B never raised SQLSTATE 40P01 (deadlock_detected),
  -- proving the shared lock order (sales_orders row before advisory lock,
  -- in both functions) holds under genuine concurrency.
  if v_b_failed then
    assert v_b_error not like '%deadlock%' and v_b_error not like '%طريق مسدود%', format('FAIL R3: طريق مسدود حقيقي اكتُشف بين approve_sales_return() و update_sales_order() — ترتيب الأقفال (Section 19) غير آمن: %s', v_b_error);
  end if;

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  raise notice 'OK: R3 لا طريق مسدود (deadlock) بين approve_sales_return() و update_sales_order() عند التسابق على نفس الطلب — كلاهما يقفل صف sales_orders قبل القفل الاستشاري بنفس الترتيب تمامًا (Section 19)، B حُجب فعليًا ثم اكتمل بشكل طبيعي (%)', coalesce(v_b_error, 'نجح B بدون مانع مالي');
end $$;

-- ============================================================================
-- Patch 4.2 (Section 9) fixtures — a dedicated third store (P4CST3, never
-- touched by R2's close_sales_day() above) and actor 01 additionally needs
-- returns.record_refund (not required by R1-R3).
-- ============================================================================
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'da000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key = 'returns.record_refund'
  on conflict (user_id, permission_id) do nothing;

do $$
declare
  v_store_id uuid;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"da000000-0000-4000-8000-000000000001","role":"authenticated"}';

  insert into public.stores (code, name_ar, status) values ('P4CST3', 'متجر تزامن مرتجعات 3 (Patch 4.2)', 'active') returning id into v_store_id;
end $$;

-- ============================================================================
-- R4 — Scenario A (Section 9): finalize holds the parent lock open; a
-- concurrent record_sales_return_refund() blocks, then is rejected once A
-- commits.
-- ============================================================================
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_order_id uuid; v_item_id uuid; v_return_id uuid; v_row_version bigint;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"da000000-0000-4000-8000-000000000001","role":"authenticated"}';

  select id into v_store_id from public.stores where code = 'P4CST3';
  select id into v_karat_id from public.karats where code = 'P4CK1';
  select id into v_category_id from public.product_categories where code = 'p4ccat';
  select id into v_channel_id from public.collection_channels where key = 'p4c_channel';
  select id into v_pm_id from public.payment_methods where key = 'p4c_pm';

  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0, 'sale_price', 1000.00)),
    'P4C-R4'
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 1000.00
  );
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_id, v_row_version);

  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.record_sales_return_refund(v_return_id, 1000.00, v_pm_id);
end $$;

do $$
declare
  v_store_id uuid; v_pm_id uuid;
  v_order_id uuid; v_return_id uuid; v_row_version bigint;
  v_busy boolean; v_ready boolean;
  v_b_failed boolean := false;
  v_b_error text;
  v_still_finalized boolean;
begin
  select id into v_store_id from public.stores where code = 'P4CST3';
  select id into v_pm_id from public.payment_methods where key = 'p4c_pm';
  select id into v_order_id from public.sales_orders where store_id = v_store_id and customer_name = 'P4C-R4';
  select id, row_version into v_return_id, v_row_version from public.sales_returns where sales_order_id = v_order_id;

  perform dblink_connect('conn_a', current_setting('p4c.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p4c.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"da000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A finalizes (matched — the single 1000.00 event above equals the
  -- 1000.00 target) and stays OPEN — holds the parent sales_returns row
  -- lock for the rest of its open transaction (0103, Section 3).
  perform dblink_exec('conn_a', format(
    $sql$do $inner$ begin perform public.finalize_sales_return_refund('%s'::uuid, %s::bigint); end $inner$;$sql$,
    v_return_id, v_row_version
  ));

  -- B attempts to record an ADDITIONAL refund on the SAME return,
  -- asynchronously — record_sales_return_refund() locks the same parent row
  -- FIRST (fixed order, 0103), so it must block on A's still-open lock.
  perform dblink_exec('conn_b', 'begin');
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"da000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select id, sales_return_id, amount from public.record_sales_return_refund('%s'::uuid, 100.00, '%s'::uuid)$sql$,
    v_return_id, v_pm_id
  ));

  v_busy := public._p4c_wait_busy('conn_b');
  assert v_busy, 'FAIL R4: record_sales_return_refund() (اتصال B) لم يُحجب رغم أن finalize_sales_return_refund() (اتصال A) ما زال مفتوحًا ويحمل قفل صف sales_returns لنفس المرتجع';

  perform dblink_exec('conn_a', 'commit');

  v_ready := public._p4c_wait_ready('conn_b');
  assert v_ready, 'FAIL R4: record_sales_return_refund() (اتصال B) لم يكتمل خلال المهلة بعد التزام A';

  begin
    perform id from dblink_get_result('conn_b', true) as t(id uuid, sales_return_id uuid, amount text);
    v_b_failed := false;
  exception when others then
    v_b_failed := true;
    v_b_error := sqlerrm;
  end;
  perform public._p4c_drain_pending('conn_b');
  perform dblink_exec('conn_b', 'commit');

  assert v_b_failed, 'FAIL R4: كان يجب أن يُرفض تسجيل استرداد B بعد أن التزم A بإغلاق التسوية أولاً على نفس المرتجع';
  assert v_b_error like '%يجب إعادة فتح التسوية أولًا%', format('FAIL R4: رسالة خطأ B غير متوقعة: %s', v_b_error);

  -- Plain superuser table read (bypasses RLS) rather than the list_sales_
  -- returns() RPC -- this outer session never `set role authenticated` in
  -- THIS statement's own implicit transaction (that was scoped `local` to
  -- the earlier fixture statement above), so has_permission() would see no
  -- JWT claims here, exactly like R1-R3's own second blocks.
  select refund_finalized_at is not null into v_still_finalized from public.sales_returns where id = v_return_id;
  assert v_still_finalized, format('FAIL R4: refund_finalized_at يجب أن يبقى مضبوطًا (لم يُفسد اللقطة النهائية) بعد رفض B، وجد %s', v_still_finalized);

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  raise notice 'OK: R4 (Section 9-A) اتصال B حُجب فعليًا طوال معاملة finalize_sales_return_refund() المفتوحة لاتصال A على نفس المرتجع، ثم رُفض بوضوح بعد الالتزام لأن التسوية أصبحت finalized بالفعل — لا حالة يمكن فيها أن يتجاوز سجل استرداد جديد تسوية مُغلَقة (%)', v_b_error;
end $$;

-- ============================================================================
-- R5 — Scenario B (Section 9): finalize holds the parent lock open; a
-- concurrent reverse_sales_return_refund_event() on a still-active event
-- blocks, then is rejected once A commits.
-- ============================================================================
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_order_id uuid; v_item_id uuid; v_return_id uuid; v_row_version bigint;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"da000000-0000-4000-8000-000000000001","role":"authenticated"}';

  select id into v_store_id from public.stores where code = 'P4CST3';
  select id into v_karat_id from public.karats where code = 'P4CK1';
  select id into v_category_id from public.product_categories where code = 'p4ccat';
  select id into v_channel_id from public.collection_channels where key = 'p4c_channel';
  select id into v_pm_id from public.payment_methods where key = 'p4c_pm';

  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0, 'sale_price', 800.00)),
    'P4C-R5'
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 800.00
  );
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_id, v_row_version);

  perform public.record_sales_return_refund(v_return_id, 800.00, v_pm_id);
end $$;

do $$
declare
  v_store_id uuid;
  v_order_id uuid; v_return_id uuid; v_row_version bigint; v_event_id uuid;
  v_busy boolean; v_ready boolean;
  v_b_failed boolean := false;
  v_b_error text;
  v_reconciliation_state text;
begin
  select id into v_store_id from public.stores where code = 'P4CST3';
  select id into v_order_id from public.sales_orders where store_id = v_store_id and customer_name = 'P4C-R5';
  select id, row_version into v_return_id, v_row_version from public.sales_returns where sales_order_id = v_order_id;
  select id into v_event_id from public.sales_return_refund_events where sales_return_id = v_return_id and status = 'active';

  perform dblink_connect('conn_a', current_setting('p4c.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p4c.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"da000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  perform dblink_exec('conn_a', format(
    $sql$do $inner$ begin perform public.finalize_sales_return_refund('%s'::uuid, %s::bigint); end $inner$;$sql$,
    v_return_id, v_row_version
  ));

  -- B attempts to reverse the still-ACTIVE event on the SAME return,
  -- asynchronously — reverse_sales_return_refund_event() locks the parent
  -- row FIRST (0103), before even reading the event row, so it must block
  -- on A's still-open finalize.
  perform dblink_exec('conn_b', 'begin');
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"da000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select id from public.reverse_sales_return_refund_event('%s'::uuid, 'محاولة تراجع أثناء تسوية مفتوحة')$sql$,
    v_event_id
  ));

  v_busy := public._p4c_wait_busy('conn_b');
  assert v_busy, 'FAIL R5: reverse_sales_return_refund_event() (اتصال B) لم يُحجب رغم أن finalize_sales_return_refund() (اتصال A) ما زال مفتوحًا ويحمل قفل صف sales_returns لنفس المرتجع';

  perform dblink_exec('conn_a', 'commit');

  v_ready := public._p4c_wait_ready('conn_b');
  assert v_ready, 'FAIL R5: reverse_sales_return_refund_event() (اتصال B) لم يكتمل خلال المهلة بعد التزام A';

  begin
    perform id from dblink_get_result('conn_b', true) as t(id uuid);
    v_b_failed := false;
  exception when others then
    v_b_failed := true;
    v_b_error := sqlerrm;
  end;
  perform public._p4c_drain_pending('conn_b');
  perform dblink_exec('conn_b', 'commit');

  assert v_b_failed, 'FAIL R5: كان يجب أن يُرفض تراجع B عن سجل الاسترداد بعد أن التزم A بإغلاق التسوية أولاً على نفس المرتجع';
  assert v_b_error like '%يجب إعادة فتح التسوية أولًا%', format('FAIL R5: رسالة خطأ B غير متوقعة: %s', v_b_error);

  -- Hotfix 4.2.1 (Section 19) — the REAL invariant now: reverse_sales_
  -- return_refund_event() (0107) INSERTs into sales_return_refund_event_
  -- reversals rather than UPDATEing the original event, so B's rejected
  -- attempt must have created NO row there at all — checking the legacy
  -- status column alone (frozen, never written by the new function) would
  -- no longer prove this.
  assert not exists (select 1 from public.sales_return_refund_event_reversals where refund_event_id = v_event_id),
    'FAIL R5: يجب ألا يوجد أي صف في sales_return_refund_event_reversals — محاولة التراجع المرفوضة من B يجب ألا تترك أي أثر (Section 1/19)';
  select status into v_reconciliation_state from public.sales_return_refund_events where id = v_event_id;
  assert v_reconciliation_state = 'active', format('FAIL R5: عمود status القديم (متجمّد، لم يعد مصدر الحقيقة) يجب أن يبقى active كما كان قبل محاولة B، وجد %s', v_reconciliation_state);

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  raise notice 'OK: R5 (Section 9-B) اتصال B حُجب فعليًا طوال معاملة finalize_sales_return_refund() المفتوحة لاتصال A على نفس المرتجع، ثم رُفضت محاولة التراجع عن سجل استرداد نشط بوضوح بعد الالتزام لأن التسوية أصبحت finalized بالفعل (%)', v_b_error;
end $$;

-- ============================================================================
-- R6 — Scenario C (Section 9): after a legitimate reopen, a concurrent
-- record + finalize race must serialize cleanly — finalize's
-- actual_refunded_total must reflect the OTHER session's now-committed
-- refund, never a stale pre-lock snapshot.
-- ============================================================================
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_order_id uuid; v_item_id uuid; v_return_id uuid; v_row_version bigint;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"da000000-0000-4000-8000-000000000001","role":"authenticated"}';

  select id into v_store_id from public.stores where code = 'P4CST3';
  select id into v_karat_id from public.karats where code = 'P4CK1';
  select id into v_category_id from public.product_categories where code = 'p4ccat';
  select id into v_channel_id from public.collection_channels where key = 'p4c_channel';
  select id into v_pm_id from public.payment_methods where key = 'p4c_pm';

  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0, 'sale_price', 500.00)),
    'P4C-R6'
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 500.00
  );
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_id, v_row_version);

  perform public.record_sales_return_refund(v_return_id, 500.00, v_pm_id);

  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.finalize_sales_return_refund(v_return_id, v_row_version);

  -- A single-session, legitimate reopen (Section 4) — the precondition R6's
  -- race actually tests. Captures the post-reopen row_version B will use.
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.reopen_sales_return_refund_reconciliation(v_return_id, v_row_version, 'إعادة فتح لاختبار R6 — تسجيل استرداد إضافي متزامن مع التسوية');
end $$;

do $$
declare
  v_store_id uuid; v_pm_id uuid;
  v_order_id uuid; v_return_id uuid; v_row_version bigint;
  v_busy boolean; v_ready boolean;
  v_b_failed boolean := false;
  v_b_error text;
  v_actual_total text; v_variance text;
  v_history_count int;
begin
  select id into v_store_id from public.stores where code = 'P4CST3';
  select id into v_pm_id from public.payment_methods where key = 'p4c_pm';
  select id into v_order_id from public.sales_orders where store_id = v_store_id and customer_name = 'P4C-R6';
  select id, row_version into v_return_id, v_row_version from public.sales_returns where sales_order_id = v_order_id;

  -- Confirm the reopen genuinely cleared finalized_at before racing — plain
  -- superuser table read (same rationale as R4's fix above: this outer
  -- session never `set role authenticated` in THIS statement's own
  -- implicit transaction) — otherwise B's finalize below would hit the
  -- "already finalized" branch instead of the race this scenario is
  -- actually about.
  assert (select refund_finalized_at is null from public.sales_returns where id = v_return_id), 'FAIL R6: يجب أن تكون التسوية معاد فتحها (refund_finalized_at = null) قبل بدء السباق';

  perform dblink_connect('conn_a', current_setting('p4c.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p4c.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"da000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A records an ADDITIONAL 50.00 refund (on top of the 500.00 already
  -- committed above) and stays OPEN — record_sales_return_refund() locks
  -- the parent sales_returns row first (0103), same as finalize.
  perform dblink_exec('conn_a', format(
    $sql$do $inner$ begin perform public.record_sales_return_refund('%s'::uuid, 50.00, '%s'::uuid); end $inner$;$sql$,
    v_return_id, v_pm_id
  ));

  -- B concurrently attempts to finalize, using the row_version captured
  -- right after reopen — record_sales_return_refund() never bumps sales_
  -- returns.row_version (it only inserts a ledger row), so this version is
  -- still valid once B actually gets the lock.
  perform dblink_exec('conn_b', 'begin');
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"da000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select id, return_number, actual_refunded_total, refund_variance from public.finalize_sales_return_refund('%s'::uuid, %s::bigint, 'فرق بسبب استرداد إضافي سُجِّل أثناء التسوية المعاد فتحها')$sql$,
    v_return_id, v_row_version
  ));

  v_busy := public._p4c_wait_busy('conn_b');
  assert v_busy, 'FAIL R6: finalize_sales_return_refund() (اتصال B) لم يُحجب رغم أن record_sales_return_refund() (اتصال A) ما زال مفتوحًا ويحمل قفل صف sales_returns لنفس المرتجع';

  perform dblink_exec('conn_a', 'commit');

  v_ready := public._p4c_wait_ready('conn_b');
  assert v_ready, 'FAIL R6: finalize_sales_return_refund() (اتصال B) لم يكتمل خلال المهلة بعد التزام A';

  begin
    select actual_refunded_total, refund_variance into v_actual_total, v_variance
    from dblink_get_result('conn_b', true) as t(id uuid, return_number text, actual_refunded_total text, refund_variance text);
    v_b_failed := false;
  exception when others then
    v_b_failed := true;
    v_b_error := sqlerrm;
  end;
  perform public._p4c_drain_pending('conn_b');
  perform dblink_exec('conn_b', 'commit');

  assert not v_b_failed, format('FAIL R6: كان يجب أن ينجح إغلاق B للتسوية بعد التزام A (لم يتغيّر row_version — record_sales_return_refund() لا يزيده) — الخطأ: %s', v_b_error);
  -- The real proof: B's finalize genuinely blocked until A's transaction
  -- committed, THEN computed actual_refunded_total from the fully-committed
  -- ledger (500.00 original + 50.00 from A = 550.00) — never a stale
  -- pre-lock snapshot that would have silently excluded A's refund.
  assert v_actual_total = '550.00', format('FAIL R6: actual_refunded_total يجب أن يعكس استرداد A المُلتزَم (550.00) — لا لقطة قديمة قبل القفل، وجد %s', v_actual_total);
  assert v_variance = '-50.00', format('FAIL R6: الفارق يجب أن يكون -50.00 (500.00 مستهدف - 550.00 فعلي)، وجد %s', v_variance);

  select count(*) into v_history_count from public.sales_return_refund_reconciliation_events where sales_return_id = v_return_id;
  assert v_history_count = 3, format('FAIL R6: سجل التسوية يجب أن يحوي 3 أحداث (finalized, reopened, finalized) بعد هذه الدورة الكاملة، وجد %s', v_history_count);

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  raise notice 'OK: R6 (Section 9-C) بعد إعادة فتح شرعية، اتصال B حُجب فعليًا طوال معاملة تسجيل استرداد A المفتوحة على نفس المرتجع، ثم أغلق التسوية بنجاح بعد الالتزام مع مجموع مسترد فعليًا يعكس استرداد A بالكامل (550.00) — لا حالة يمكن فيها ألا تطابق التسوية النهائية السجل الفعلي';
end $$;

-- ============================================================================
-- R7 — Hotfix 4.2.1 (Section 19): TWO concurrent reverse_sales_return_
-- refund_event() calls against the SAME (still-active) refund event —
-- unique(refund_event_id) on sales_return_refund_event_reversals (0106)
-- must allow EXACTLY ONE winner, with the loser rejected by the same
-- friendly "already reversed" message a sequential double-reversal attempt
-- gets (reverse_sales_return_refund_event() locks the parent sales_returns
-- row FIRST, so B genuinely blocks behind A's open transaction rather than
-- racing the unique constraint directly — the constraint itself remains the
-- authoritative backstop regardless, per 0107's own comment).
-- ============================================================================
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_order_id uuid; v_item_id uuid; v_return_id uuid; v_row_version bigint;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"da000000-0000-4000-8000-000000000001","role":"authenticated"}';

  select id into v_store_id from public.stores where code = 'P4CST3';
  select id into v_karat_id from public.karats where code = 'P4CK1';
  select id into v_category_id from public.product_categories where code = 'p4ccat';
  select id into v_channel_id from public.collection_channels where key = 'p4c_channel';
  select id into v_pm_id from public.payment_methods where key = 'p4c_pm';

  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0, 'sale_price', 650.00)),
    'P4C-R7'
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 650.00
  );
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_id, v_row_version);

  perform public.record_sales_return_refund(v_return_id, 650.00, v_pm_id);
end $$;

do $$
declare
  v_store_id uuid;
  v_order_id uuid; v_return_id uuid; v_event_id uuid;
  v_busy boolean; v_ready boolean;
  v_b_failed boolean := false; v_b_error text;
  v_reversal_count int;
begin
  select id into v_store_id from public.stores where code = 'P4CST3';
  select id into v_order_id from public.sales_orders where store_id = v_store_id and customer_name = 'P4C-R7';
  select id into v_return_id from public.sales_returns where sales_order_id = v_order_id;
  select id into v_event_id from public.sales_return_refund_events where sales_return_id = v_return_id and status = 'active';

  perform dblink_connect('conn_a', current_setting('p4c.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p4c.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"da000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A reverses the event synchronously (succeeds) and stays OPEN
  -- (uncommitted) — reverse_sales_return_refund_event() locks the parent
  -- sales_returns row FIRST (0107), so B (below) must block on it, exactly
  -- like every other refund-ledger race in this file.
  perform dblink_exec('conn_a', format(
    $sql$do $inner$ begin perform public.reverse_sales_return_refund_event('%s'::uuid, 'محاولة تراجع متزامنة أولى (A) — R7'); end $inner$;$sql$,
    v_event_id
  ));

  perform dblink_exec('conn_b', 'begin');
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"da000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select id from public.reverse_sales_return_refund_event('%s'::uuid, 'محاولة تراجع متزامنة ثانية (B) — R7')$sql$,
    v_event_id
  ));

  v_busy := public._p4c_wait_busy('conn_b');
  assert v_busy, 'FAIL R7: محاولة التراجع الثانية (اتصال B) لم تُحجب رغم أن محاولة A ما زالت مفتوحة وتحمل قفل صف sales_returns لنفس المرتجع';

  perform dblink_exec('conn_a', 'commit');

  v_ready := public._p4c_wait_ready('conn_b');
  assert v_ready, 'FAIL R7: محاولة التراجع الثانية (اتصال B) لم تكتمل خلال المهلة بعد التزام A';

  begin
    perform id from dblink_get_result('conn_b', true) as t(id uuid);
    v_b_failed := false;
  exception when others then
    v_b_failed := true;
    v_b_error := sqlerrm;
  end;
  perform public._p4c_drain_pending('conn_b');
  perform dblink_exec('conn_b', 'commit');

  assert v_b_failed, 'FAIL R7: كان يجب أن تُرفض محاولة التراجع الثانية (B) عن نفس سجل الاسترداد — تراجع مزدوج على نفس الحدث يجب أن يُمنع دائمًا';
  assert v_b_error like '%متراجَع عنه بالفعل%', format('FAIL R7: رسالة رفض B غير متوقعة: %s', v_b_error);

  -- THE key structural proof: exactly ONE row exists for this event —
  -- unique(refund_event_id) (0106) is the ultimate backstop, never a race
  -- that could leave two.
  select count(*) into v_reversal_count from public.sales_return_refund_event_reversals where refund_event_id = v_event_id;
  assert v_reversal_count = 1, format('FAIL R7: يجب أن يوجد صف واحد بالضبط في sales_return_refund_event_reversals لهذا الحدث بعد السباق، وجد %s', v_reversal_count);

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  raise notice 'OK: R7 (Hotfix 4.2.1، Section 19) محاولتا تراجع متزامنتان عن نفس سجل الاسترداد — الأولى (A) نجحت، والثانية (B) حُجبت فعليًا ثم رُفضت بوضوح بعد التزام A، وبقي صف واحد بالضبط في sales_return_refund_event_reversals — unique(refund_event_id) يمنع أي تراجع مزدوج حتى تحت تزامن حقيقي';
end $$;

-- ============================================================================
-- Cleanup — real DELETE (no wrapping transaction to roll back).
-- ============================================================================
-- Patch 4.2: sales_return_refund_reconciliation_events_sales_return_id_fkey
-- is ON DELETE RESTRICT (0099, deliberately — an append-only history table
-- must never silently cascade away), so it MUST be cleared before deleting
-- sales_returns below, or that delete would fail outright.
delete from public.sales_return_refund_reconciliation_events where sales_return_id in (select id from public.sales_returns where processed_store_id in (select id from public.stores where code in ('P4CST', 'P4CST2', 'P4CST3')));
-- Hotfix 4.2.1 (0106): sales_return_refund_event_reversals is ON DELETE
-- RESTRICT against BOTH sales_return_refund_events and sales_returns, and
-- sales_return_refund_events itself is now trigger-protected from DELETE
-- outside the migration-only backfill GUC escape hatch (0106/0107) — this
-- is real test-harness teardown of throwaway fixture rows, not an
-- application code path, so it uses that same documented, narrowly-scoped
-- escape hatch for exactly this one statement.
delete from public.sales_return_refund_event_reversals where sales_return_id in (select id from public.sales_returns where processed_store_id in (select id from public.stores where code in ('P4CST', 'P4CST2', 'P4CST3')));
select set_config('app.allow_refund_event_backfill', 'on', false);
delete from public.sales_return_refund_events where sales_return_id in (select id from public.sales_returns where processed_store_id in (select id from public.stores where code in ('P4CST', 'P4CST2', 'P4CST3')));
select set_config('app.allow_refund_event_backfill', 'off', false);
delete from public.sales_return_items where sales_return_id in (select id from public.sales_returns where processed_store_id in (select id from public.stores where code in ('P4CST', 'P4CST2', 'P4CST3')));
delete from public.sales_returns where processed_store_id in (select id from public.stores where code in ('P4CST', 'P4CST2', 'P4CST3'));
delete from public.audit_logs where user_id in ('da000000-0000-4000-8000-000000000001', 'da000000-0000-4000-8000-000000000002');
delete from public.daily_closings where store_id in (select id from public.stores where code in ('P4CST', 'P4CST2', 'P4CST3'));
delete from public.sales_order_items where sales_order_id in (select id from public.sales_orders where store_id in (select id from public.stores where code in ('P4CST', 'P4CST2', 'P4CST3')));
delete from public.sales_orders where store_id in (select id from public.stores where code in ('P4CST', 'P4CST2', 'P4CST3'));
delete from public.payment_method_fee_versions where payment_method_id in (select id from public.payment_methods where key = 'p4c_pm');
delete from public.manufacturing_fee_versions where karat_id in (select id from public.karats where code = 'P4CK1');
delete from public.daily_gold_prices where karat_id in (select id from public.karats where code = 'P4CK1');
delete from public.payment_methods where key = 'p4c_pm';
delete from public.collection_channels where key = 'p4c_channel';
delete from public.product_categories where code = 'p4ccat';
delete from public.karats where code = 'P4CK1';
delete from public.stores where code in ('P4CST', 'P4CST2', 'P4CST3');
delete from public.user_permission_overrides where user_id in ('da000000-0000-4000-8000-000000000001', 'da000000-0000-4000-8000-000000000002');
delete from public.profiles where id in ('da000000-0000-4000-8000-000000000001', 'da000000-0000-4000-8000-000000000002');
delete from auth.users where id in ('da000000-0000-4000-8000-000000000001', 'da000000-0000-4000-8000-000000000002');

drop function if exists public._p4c_wait_busy(text, int, numeric);
drop function if exists public._p4c_wait_ready(text, int, numeric);
drop function if exists public._p4c_drain_pending(text);

do $$ begin
  raise notice 'ALL sales_returns_concurrency.test.sql ASSERTIONS PASSED (R1-R3 Patch 4.1, R4-R6 Patch 4.2 Section 9, R7 Hotfix 4.2.1 Section 19)';
end $$;
