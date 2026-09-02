-- ============================================================================
-- Integration test: Phase 9 — Inventory Core, GENUINE multi-session
-- concurrency (mirrors adjustments_core_phase6_concurrency.test.sql's own
-- dblink pattern exactly).
-- ============================================================================
-- NOT safe to run against a shared/staging database — real dblink sessions,
-- auto-committing statements, no wrapping transaction, explicit cleanup at
-- the end. Run ONLY against a throwaway/CI database.
--
-- Requires migrations 0001-latest (including 0227-0230) + supabase/seed.sql
-- already applied, and the `dblink` extension available.
--
-- Connection string override, same convention as the other *_concurrency.
-- test.sql files:
--   psql -v dblink_conninfo="host=... port=... user=... password=..." \
--     -f supabase/tests/inventory_core_phase9_concurrency.test.sql
--
-- Scenario A — Negative-stock race: two concurrent adjust_inventory_stock()
--   calls against the SAME (item, store), each individually valid against
--   the balance BEFORE either runs, but not valid together. Proves the
--   advisory lock from 0227/0230 (taken by record_inventory_stock_movement()
--   in 0229 BEFORE it sums the ledger) genuinely serializes the two calls —
--   the second waits for the first's transaction to end, then is correctly
--   evaluated against the POST-first balance and rejected — rather than both
--   racing off a stale pre-decrement read and both being accepted.
-- ============================================================================

create extension if not exists dblink;

\if :{?dblink_conninfo}
\else
\set dblink_conninfo 'host=127.0.0.1 port=5432 user=postgres password=postgres'
\endif

select set_config('p9cc.dblink_conninfo', :'dblink_conninfo', false);

create or replace function public._p9cc_wait_busy(p_connname text, p_max_polls int default 30, p_interval numeric default 0.1)
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

create or replace function public._p9cc_wait_ready(p_connname text, p_max_polls int default 100, p_interval numeric default 0.1)
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

create or replace function public._p9cc_drain_pending(p_connname text)
returns void
language plpgsql
as $$
begin
  perform 1 from dblink_get_result(p_connname) as t(x text);
end;
$$;

-- ============================================================================
-- 0. Fixtures — own prefix 'a9c00000-.../P9CC', committed immediately.
-- ============================================================================
insert into auth.users (id, email) values
  ('a9c00000-0000-4000-8000-000000000001', 'test-p9cc-actor@example.invalid');

update public.profiles set full_name = 'P9CC actor', status = 'active', store_access_scope = 'all'
  where id = 'a9c00000-0000-4000-8000-000000000001';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a9c00000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in ('categories.view', 'categories.manage', 'karats.view', 'karats.manage', 'inventory.view', 'inventory.receive', 'inventory.adjust');

do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_item_id uuid;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a9c00000-0000-4000-8000-000000000001","role":"authenticated"}';

  insert into public.stores (code, name_ar, status) values ('P9CCSTA', 'فرع تزامن مخزون', 'active') returning id into v_store_id;
  insert into public.karats (code, name_ar, sort_order, status) values ('P9CCK1', 'عيار تزامن مخزون', 995, 'active') returning id into v_karat_id;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('p9cccat', 'تصنيف تزامن مخزون', 995, 'active') returning id into v_category_id;

  select id into v_item_id from public.create_inventory_item('P9CC-SKU-1', 'صنف تزامن مخزون', v_category_id, v_karat_id, 'gram', null);

  -- Committed fixture receipt: 10 units on hand before the race begins.
  perform public.receive_inventory_stock(v_item_id, v_store_id, 10, current_date, 'P9CC fixture receipt', null);

  perform set_config('p9cc.store', v_store_id::text, false);
  perform set_config('p9cc.item', v_item_id::text, false);
end $$;

-- ============================================================================
-- A — Negative-stock race: balance starts at 10. Two concurrent -6
-- adjustments are each individually valid (10 - 6 = 4 >= 0) but NOT valid
-- together (10 - 6 - 6 = -2 < 0). Exactly one must commit; the other must be
-- genuinely rejected once it is unblocked and re-evaluates the POST-first
-- balance — never both accepted off a stale pre-decrement read.
-- ============================================================================
do $$
declare
  v_item_id uuid := current_setting('p9cc.item')::uuid;
  v_store_id uuid := current_setting('p9cc.store')::uuid;
  v_busy boolean;
  v_a_failed boolean := false; v_b_failed boolean := false;
  v_a_balance text; v_b_balance text;
  v_final_balance numeric;
  v_movement_count int;
begin
  perform dblink_connect('conn_a', current_setting('p9cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p9cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"a9c00000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"a9c00000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A takes the advisory lock (0227/0230) inside record_inventory_stock_
  -- movement() (0229), sums the ledger (10), applies -6 -> 4, and stays
  -- open (no commit yet) so the lock is held for the rest of this scenario.
  perform dblink_send_query('conn_a', format(
    $sql$select * from public.adjust_inventory_stock('%s'::uuid, '%s'::uuid, -6, 'P9CC race A — first outbound', current_date, null)$sql$,
    v_item_id, v_store_id
  ));
  perform public._p9cc_wait_ready('conn_a');
  begin
    select resulting_balance into v_a_balance from dblink_get_result('conn_a', true) as t(id uuid, resulting_balance text);
    perform public._p9cc_drain_pending('conn_a');
  exception when others then
    v_a_failed := true;
  end;

  -- B concurrently races the SAME (item, store) pair while A's transaction
  -- is still open — genuinely blocks on the SAME advisory lock key
  -- (1008, hashtext(item_id || ':' || store_id)), sent async and polled,
  -- never a synchronous call that would deadlock this script.
  perform dblink_send_query('conn_b', format(
    $sql$select * from public.adjust_inventory_stock('%s'::uuid, '%s'::uuid, -6, 'P9CC race B — second outbound', current_date, null)$sql$,
    v_item_id, v_store_id
  ));
  v_busy := public._p9cc_wait_busy('conn_b');
  assert v_busy, 'FAIL A: محاولة B لم تُحجب رغم أن معاملة A ما زالت مفتوحة وتحمل القفل الاستشاري لنفس الصنف/الفرع';

  perform dblink_exec('conn_a', 'commit');

  perform public._p9cc_wait_ready('conn_b');
  begin
    select resulting_balance into v_b_balance from dblink_get_result('conn_b', true) as t(id uuid, resulting_balance text);
    perform public._p9cc_drain_pending('conn_b');
  exception when others then
    v_b_failed := true;
  end;

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  assert not v_a_failed, 'FAIL A: أول حركة سحب (10 - 6 = 4) كان يجب أن تنجح';
  assert v_a_balance = '4', format('FAIL A: الرصيد بعد حركة A الأولى يجب أن يكون 4، الموجود: %s', v_a_balance);
  assert v_b_failed, 'FAIL A: ثاني حركة سحب متزامنة كان يجب أن تُرفض بعد إعادة تقييمها على الرصيد الفعلي بعد التزام A (4 - 6 = سالب)، لا أن تُقبل بناءً على قراءة قديمة (10) قبل حركة A';

  -- Authoritative proof: only A's movement committed. Verified via a fresh
  -- SUM() over the ledger (never a stored/cached balance column, per 0228).
  select coalesce(sum(quantity_delta), 0) into v_final_balance
  from public.inventory_stock_movements
  where item_id = v_item_id and store_id = v_store_id;
  assert v_final_balance = 4, format('FAIL A: الرصيد النهائي المشتق من دفتر الحركات يجب أن يكون 4 (وليس سالبًا)، الموجود: %s', v_final_balance);

  select count(*) into v_movement_count
  from public.inventory_stock_movements
  where item_id = v_item_id and store_id = v_store_id;
  assert v_movement_count = 2, format('FAIL A: يجب أن يوجد صفان فقط في دفتر الحركات (الاستلام الأولي + حركة A الناجحة) — لا صف لمحاولة B المرفوضة. الموجود: %s', v_movement_count);

  raise notice 'PASS A: negative-stock race — A''s outbound (10->4) commits, B''s concurrent outbound is genuinely serialized and correctly rejected once re-evaluated against the post-A balance (never both accepted)';
end $$;

-- ---------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------
drop function if exists public._p9cc_wait_busy(text, int, numeric);
drop function if exists public._p9cc_wait_ready(text, int, numeric);
drop function if exists public._p9cc_drain_pending(text);

\echo 'inventory_core_phase9_concurrency.test.sql PASSED'
