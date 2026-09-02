-- ============================================================================
-- Integration test: Phase 9 — Inventory Core (0227-0229)
-- ============================================================================
-- Single-transaction, rolled-back-at-the-end regression test, mirroring
-- adjustments_core_phase6.test.sql's own convention exactly.
--
-- Prefix 'a9000000-...' is not used by any other test file's fixtures
-- (checked against every prefix currently in use across supabase/tests/).
--
--   01 = full-permission actor (inventory.view + inventory.receive +
--        inventory.adjust), store_access_scope='all'
--   02 = inventory.view-only actor, store_access_scope='all'
--   03 = inventory.receive-only actor (no view, no adjust), store_access_
--        scope='all'
--   04 = inventory.adjust-only actor (no view, no receive), store_access_
--        scope='all'
--   05 = inventory.view + inventory.receive + inventory.adjust, but
--        store_access_scope='single', default_store_id=Store B ONLY
--        (cross-store scope rejection test)
--
-- Requires migrations 0001-latest + supabase/seed.sql already applied.
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/inventory_core_phase9.test.sql
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0. Setup — actors, two stores, one category, one karat.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('a9000000-0000-4000-8000-000000000001', 'test-p9-manager@example.invalid'),
  ('a9000000-0000-4000-8000-000000000002', 'test-p9-viewonly@example.invalid'),
  ('a9000000-0000-4000-8000-000000000003', 'test-p9-receiveonly@example.invalid'),
  ('a9000000-0000-4000-8000-000000000004', 'test-p9-adjustonly@example.invalid'),
  ('a9000000-0000-4000-8000-000000000005', 'test-p9-storebonly@example.invalid');

update public.profiles set full_name = 'Test P9 Inventory Manager', status = 'active', store_access_scope = 'all'
  where id = 'a9000000-0000-4000-8000-000000000001';
update public.profiles set full_name = 'Test P9 View-Only Actor', status = 'active', store_access_scope = 'all'
  where id = 'a9000000-0000-4000-8000-000000000002';
update public.profiles set full_name = 'Test P9 Receive-Only Actor', status = 'active', store_access_scope = 'all'
  where id = 'a9000000-0000-4000-8000-000000000003';
update public.profiles set full_name = 'Test P9 Adjust-Only Actor', status = 'active', store_access_scope = 'all'
  where id = 'a9000000-0000-4000-8000-000000000004';
-- 005 is deliberately store-scoped to Store B ONLY — default_store_id is set
-- below, once Store B's id is known.
update public.profiles set full_name = 'Test P9 Store-B-Only Actor', status = 'active', store_access_scope = 'all'
  where id = 'a9000000-0000-4000-8000-000000000005';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a9000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  -- `stores.create` is required by 0010's `stores_insert` RLS policy (WITH
  -- CHECK has_permission('stores.create')) — this actor creates the two test
  -- stores below as `authenticated`, exactly like adjustments_core_phase6.
  -- test.sql's own fixture actor does. `stores.view` alone only satisfies
  -- the SELECT policy.
  -- `audit_logs.view` is required by the audit_logs SELECT policy (0010,
  -- last rewritten in 0187) — section 7 below asserts that every Phase 9
  -- mutation was actually recorded, and without it that SELECT returns zero
  -- rows for a reason that has nothing to do with whether the audit rows
  -- were written.
  where key in ('stores.view', 'stores.create', 'karats.view', 'karats.manage', 'categories.view', 'categories.manage', 'audit_logs.view', 'inventory.view', 'inventory.receive', 'inventory.adjust');

-- Deliberately inventory.view ONLY.
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a9000000-0000-4000-8000-000000000002', id, 'grant' from public.permissions
  where key in ('inventory.view');

-- Deliberately inventory.receive ONLY — no view, no adjust.
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a9000000-0000-4000-8000-000000000003', id, 'grant' from public.permissions
  where key in ('inventory.receive');

-- Deliberately inventory.adjust ONLY — no view, no receive.
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a9000000-0000-4000-8000-000000000004', id, 'grant' from public.permissions
  where key in ('inventory.adjust');

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a9000000-0000-4000-8000-000000000005', id, 'grant' from public.permissions
  where key in ('inventory.view', 'inventory.receive', 'inventory.adjust');

set role authenticated;
set local request.jwt.claims = '{"sub":"a9000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_store_a uuid;
  v_store_b uuid;
  v_karat uuid;
  v_category uuid;
begin
  insert into public.stores (code, name_ar, status) values ('P9-STA', 'فرع اختبار 9 - أ', 'active') returning id into v_store_a;
  insert into public.stores (code, name_ar, status) values ('P9-STB', 'فرع اختبار 9 - ب', 'active') returning id into v_store_b;
  perform set_config('p9t.store_a', v_store_a::text, false);
  perform set_config('p9t.store_b', v_store_b::text, false);

  insert into public.karats (code, name_ar, sort_order, status) values ('P9K1', 'عيار اختبار 9', 991, 'active') returning id into v_karat;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('p9cat1', 'تصنيف اختبار 9', 991, 'active') returning id into v_category;
  perform set_config('p9t.karat', v_karat::text, false);
  perform set_config('p9t.category', v_category::text, false);
end;
$$;

-- Store-scoping actor 005 to Store B must NOT happen inside the block above.
-- That block runs as `authenticated` (actor 001), and 0010's
-- `profiles_update` policy requires users.edit/users.disable (0018's
-- `profiles_update_store_access` requires users.manage_store_access) — none
-- of which this deliberately inventory-only actor holds. An UPDATE blocked
-- by RLS does not raise: it silently matches zero rows, leaving actor 005 at
-- the default scope 'all' and making every cross-store rejection assertion
-- below pass vacuously against an actor that was never actually scoped.
-- Done as the session superuser instead, exactly like the profile updates at
-- the top of this file.
reset role;
reset request.jwt.claims;

update public.profiles
   set store_access_scope = 'single', default_store_id = current_setting('p9t.store_b')::uuid
 where id = 'a9000000-0000-4000-8000-000000000005';

-- Explicit proof the fixture actually took effect — this is the exact silent
-- no-op described above, so it is asserted rather than assumed.
do $$
declare
  v_scope text;
  v_default_store uuid;
begin
  select store_access_scope, default_store_id into v_scope, v_default_store
  from public.profiles where id = 'a9000000-0000-4000-8000-000000000005';

  if v_scope <> 'single' or v_default_store is distinct from current_setting('p9t.store_b')::uuid then
    raise exception 'TEST FAILED: fixture did not store-scope actor 005 to Store B (scope=%, default_store_id=%)', v_scope, v_default_store;
  end if;
end;
$$;

set role authenticated;
set local request.jwt.claims = '{"sub":"a9000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- 1. create_inventory_item() — permission boundary + validation.
-- ---------------------------------------------------------------------------

-- view-only actor cannot create an item.
set local request.jwt.claims = '{"sub":"a9000000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$
begin
  begin
    perform public.create_inventory_item('P9-SKU-1', 'خاتم اختبار', current_setting('p9t.category')::uuid, current_setting('p9t.karat')::uuid, 'gram', null);
    raise exception 'TEST FAILED: view-only actor was able to create an inventory item';
  exception when others then
    if sqlerrm not like '%صلاحية%' then
      raise;
    end if;
  end;
end;
$$;

-- receive-only actor CAN create an item (item creation is gated on
-- inventory.receive, per the approved-scope permission shape).
set local request.jwt.claims = '{"sub":"a9000000-0000-4000-8000-000000000003","role":"authenticated"}';
do $$
declare
  v_id uuid;
  v_sku text;
begin
  select id, sku into v_id, v_sku from public.create_inventory_item('P9-SKU-1', 'خاتم اختبار', current_setting('p9t.category')::uuid, current_setting('p9t.karat')::uuid, 'gram', null);
  if v_id is null or v_sku <> 'P9-SKU-1' then
    raise exception 'TEST FAILED: create_inventory_item did not return the expected row';
  end if;
  perform set_config('p9t.item_1', v_id::text, false);
end;
$$;

-- Duplicate SKU (case-insensitive) is rejected.
do $$
begin
  begin
    perform public.create_inventory_item('p9-sku-1', 'خاتم مكرر', current_setting('p9t.category')::uuid, null, 'gram', null);
    raise exception 'TEST FAILED: duplicate SKU (case-insensitive) was accepted';
  exception when others then
    if sqlerrm not like '%مستخدم%' then
      raise;
    end if;
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. receive_inventory_stock() — positive-only, store-scoped, balance
--    derived live from the ledger.
-- ---------------------------------------------------------------------------

-- view-only actor cannot receive stock.
set local request.jwt.claims = '{"sub":"a9000000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$
begin
  begin
    perform public.receive_inventory_stock(current_setting('p9t.item_1')::uuid, current_setting('p9t.store_a')::uuid, 10, current_date, null, null);
    raise exception 'TEST FAILED: view-only actor was able to receive stock';
  exception when others then
    if sqlerrm not like '%صلاحية%' then
      raise;
    end if;
  end;
end;
$$;

-- adjust-only actor cannot receive stock (receive requires inventory.receive
-- specifically, not inventory.adjust).
set local request.jwt.claims = '{"sub":"a9000000-0000-4000-8000-000000000004","role":"authenticated"}';
do $$
begin
  begin
    perform public.receive_inventory_stock(current_setting('p9t.item_1')::uuid, current_setting('p9t.store_a')::uuid, 10, current_date, null, null);
    raise exception 'TEST FAILED: adjust-only actor was able to receive stock';
  exception when others then
    if sqlerrm not like '%صلاحية%' then
      raise;
    end if;
  end;
end;
$$;

-- receive-only actor CAN receive stock at an operable store.
set local request.jwt.claims = '{"sub":"a9000000-0000-4000-8000-000000000003","role":"authenticated"}';
do $$
declare
  v_balance text;
begin
  -- `resulting_balance` is sum(quantity_delta)::text over a numeric(12, 3)
  -- column (0228), and 0229 deliberately returns it as TEXT rather than a
  -- raw numeric (PostgREST would serialize a numeric as an unquoted JSON
  -- number and silently lose precision). So the exact expected string always
  -- carries the column's own 3-decimal scale — asserting on '10' here would
  -- be asserting that the ::text contract had been dropped.
  select resulting_balance into v_balance from public.receive_inventory_stock(current_setting('p9t.item_1')::uuid, current_setting('p9t.store_a')::uuid, 10, current_date, 'PO-1', 'first receipt');
  if v_balance <> '10.000' then
    raise exception 'TEST FAILED: expected resulting_balance=10.000 after first receipt, got %', v_balance;
  end if;
end;
$$;

-- A negative/zero quantity is rejected by receive_inventory_stock (CHECK +
-- RPC guard both reject; RPC guard fires first with a friendly message).
do $$
begin
  begin
    perform public.receive_inventory_stock(current_setting('p9t.item_1')::uuid, current_setting('p9t.store_a')::uuid, -5, current_date, null, null);
    raise exception 'TEST FAILED: a negative receive quantity was accepted';
  exception when others then
    if sqlerrm not like '%موجبًا%' then
      raise;
    end if;
  end;
end;
$$;

do $$
begin
  begin
    perform public.receive_inventory_stock(current_setting('p9t.item_1')::uuid, current_setting('p9t.store_a')::uuid, 0, current_date, null, null);
    raise exception 'TEST FAILED: a zero receive quantity was accepted';
  exception when others then
    if sqlerrm not like '%صفرًا%' then
      raise;
    end if;
  end;
end;
$$;

-- Store-B-only actor cannot receive stock at Store A (not in their operable set).
set local request.jwt.claims = '{"sub":"a9000000-0000-4000-8000-000000000005","role":"authenticated"}';
do $$
begin
  begin
    perform public.receive_inventory_stock(current_setting('p9t.item_1')::uuid, current_setting('p9t.store_a')::uuid, 5, current_date, null, null);
    raise exception 'TEST FAILED: Store-B-only actor received stock at Store A';
  exception when others then
    if sqlerrm not like '%فرع%' then
      raise;
    end if;
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. adjust_inventory_stock() — signed, mandatory reason, negative-stock
--    rejection (the authoritative DB-layer guard).
-- ---------------------------------------------------------------------------

-- receive-only actor cannot adjust stock (adjust requires inventory.adjust
-- specifically, not inventory.receive).
set local request.jwt.claims = '{"sub":"a9000000-0000-4000-8000-000000000003","role":"authenticated"}';
do $$
begin
  begin
    perform public.adjust_inventory_stock(current_setting('p9t.item_1')::uuid, current_setting('p9t.store_a')::uuid, -1, 'جرد', current_date, null);
    raise exception 'TEST FAILED: receive-only actor was able to adjust stock';
  exception when others then
    if sqlerrm not like '%صلاحية%' then
      raise;
    end if;
  end;
end;
$$;

set local request.jwt.claims = '{"sub":"a9000000-0000-4000-8000-000000000004","role":"authenticated"}';

-- A blank reason is rejected.
do $$
begin
  begin
    perform public.adjust_inventory_stock(current_setting('p9t.item_1')::uuid, current_setting('p9t.store_a')::uuid, -1, '   ', current_date, null);
    raise exception 'TEST FAILED: a blank reason was accepted for a stock adjustment';
  exception when others then
    if sqlerrm not like '%سبب%' then
      raise;
    end if;
  end;
end;
$$;

-- A positive correction (found extra stock) succeeds, balance derived live.
do $$
declare
  v_balance text;
begin
  select resulting_balance into v_balance from public.adjust_inventory_stock(current_setting('p9t.item_1')::uuid, current_setting('p9t.store_a')::uuid, 2.5, 'جرد فعلي - كمية زائدة', current_date, null);
  if v_balance <> '12.500' then
    raise exception 'TEST FAILED: expected resulting_balance=12.500 after +2.5 adjustment, got %', v_balance;
  end if;
end;
$$;

-- THE AUTHORITATIVE GUARD: an adjustment that would push the balance
-- negative is rejected, current balance (12.5) unchanged.
do $$
begin
  begin
    perform public.adjust_inventory_stock(current_setting('p9t.item_1')::uuid, current_setting('p9t.store_a')::uuid, -100, 'محاولة سحب أكثر من المتاح', current_date, null);
    raise exception 'TEST FAILED: an adjustment that would push stock negative was accepted';
  exception when others then
    if sqlerrm not like '%سالبة%' then
      raise;
    end if;
  end;
end;
$$;

-- Verify via the manager actor (001) — actor 004 (inventory.adjust only, no
-- inventory.view) cannot SELECT inventory_stock_movements directly at all
-- (RLS, 0228), so the verification read must run under a session that
-- actually holds inventory.view, not the mutating actor.
set local request.jwt.claims = '{"sub":"a9000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_balance numeric;
begin
  select coalesce(sum(quantity_delta), 0) into v_balance
  from public.inventory_stock_movements
  where item_id = current_setting('p9t.item_1')::uuid and store_id = current_setting('p9t.store_a')::uuid;
  if v_balance <> 12.5 then
    raise exception 'TEST FAILED: balance was mutated by the rejected negative-stock attempt (expected 12.5, got %)', v_balance;
  end if;
end;
$$;
set local request.jwt.claims = '{"sub":"a9000000-0000-4000-8000-000000000004","role":"authenticated"}';

-- Exactly zeroing out the balance is allowed (boundary: new balance = 0, not < 0).
do $$
declare
  v_balance text;
begin
  select resulting_balance into v_balance from public.adjust_inventory_stock(current_setting('p9t.item_1')::uuid, current_setting('p9t.store_a')::uuid, -12.5, 'تصفير الرصيد للاختبار', current_date, null);
  if v_balance <> '0.000' then
    raise exception 'TEST FAILED: expected resulting_balance=0.000 after zeroing adjustment, got %', v_balance;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. inventory_stock_movements is append-only — TRUSTED-write proof: even a
--    raw superuser UPDATE (bypassing RLS entirely, unlike an `authenticated`
--    actor who would additionally be blocked by RLS finding zero writable
--    rows) is rejected by reject_inventory_stock_movement_mutation() (0228).
--    Mirrors settlement_batches_reject_financial_mutation's TRUSTED-write
--    proof in settlements_phase7.test.sql exactly.
-- ---------------------------------------------------------------------------
reset role;
reset request.jwt.claims;
do $$
begin
  begin
    update public.inventory_stock_movements set quantity_delta = 999 where item_id = current_setting('p9t.item_1')::uuid;
    raise exception 'TEST FAILED: a raw superuser UPDATE on inventory_stock_movements succeeded';
  exception when others then
    if sqlerrm not like '%للقراءة فقط%' then
      raise;
    end if;
  end;
end;
$$;
do $$
begin
  begin
    delete from public.inventory_stock_movements where item_id = current_setting('p9t.item_1')::uuid;
    raise exception 'TEST FAILED: a raw superuser DELETE on inventory_stock_movements succeeded';
  exception when others then
    if sqlerrm not like '%للقراءة فقط%' then
      raise;
    end if;
  end;
end;
$$;
set role authenticated;

-- ---------------------------------------------------------------------------
-- 5. update_inventory_item() — row_version optimistic concurrency.
-- ---------------------------------------------------------------------------
-- The actor used below is 004 — deliberately inventory.adjust ONLY, to prove
-- that update_inventory_item() is gated on `adjust`. That same actor has no
-- inventory.view, so it cannot SELECT inventory_items at all (0228's
-- `inventory_items_select` policy requires inventory.view). Reading
-- row_version as that actor returns NULL, and a NULL expected-version makes
-- every assertion in this section vacuous: `row_version <> NULL` is NULL,
-- never true, so the "stale version" call is not rejected and the
-- "incremented correctly" comparison is NULL too. The version is therefore
-- captured as the session superuser, outside RLS, exactly like the other
-- fixture values in this file.
reset role;
reset request.jwt.claims;
select set_config('p9t.item_1_version', (select row_version::text from public.inventory_items where id = current_setting('p9t.item_1')::uuid), false);

set role authenticated;
set local request.jwt.claims = '{"sub":"a9000000-0000-4000-8000-000000000004","role":"authenticated"}';
do $$
declare
  v_row_version bigint := current_setting('p9t.item_1_version')::bigint;
begin
  if v_row_version is null then
    raise exception 'TEST FAILED: fixture did not capture item_1 row_version';
  end if;

  -- Stale row_version is rejected. The expected message is this project's
  -- standard optimistic-concurrency wording ("... مستخدم آخر ..."), shared
  -- with every other update RPC (0075/0086/0146/...).
  begin
    perform public.update_inventory_item(current_setting('p9t.item_1')::uuid, v_row_version - 1, 'اسم محدث', current_setting('p9t.category')::uuid, null, 'gram', true, null);
    raise exception 'TEST FAILED: a stale row_version was accepted by update_inventory_item';
  exception when others then
    if sqlerrm not like '%مستخدم آخر%' then
      raise;
    end if;
  end;

  -- A NULL expected version must be rejected outright, never treated as
  -- "no opinion" — `row_version <> NULL` silently bypasses the whole check.
  begin
    perform public.update_inventory_item(current_setting('p9t.item_1')::uuid, null, 'اسم محدث', current_setting('p9t.category')::uuid, null, 'gram', true, null);
    raise exception 'TEST FAILED: a NULL expected row_version bypassed the optimistic-concurrency check';
  exception when others then
    if sqlerrm not like '%رقم إصدار%' then
      raise;
    end if;
  end;

  -- Correct row_version succeeds.
  perform public.update_inventory_item(current_setting('p9t.item_1')::uuid, v_row_version, 'اسم محدث', current_setting('p9t.category')::uuid, null, 'gram', true, null);
end;
$$;

-- The post-update assertion needs the same out-of-RLS read as the capture
-- above, for the same reason.
reset role;
reset request.jwt.claims;
do $$
declare
  v_expected bigint := current_setting('p9t.item_1_version')::bigint + 1;
  v_actual bigint;
begin
  select row_version into v_actual from public.inventory_items where id = current_setting('p9t.item_1')::uuid;
  if v_actual is distinct from v_expected then
    raise exception 'TEST FAILED: row_version did not increment after a successful update (expected %, got %)', v_expected, v_actual;
  end if;
end;
$$;
set role authenticated;

-- ---------------------------------------------------------------------------
-- 6. list_inventory_stock_balances()/list_inventory_stock_movements() —
--    read-side store visibility scoping.
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"a9000000-0000-4000-8000-000000000005","role":"authenticated"}';
do $$
declare
  v_count int;
begin
  -- Store-B-only actor querying Store A explicitly is rejected.
  begin
    perform public.list_inventory_stock_movements(null, current_setting('p9t.store_a')::uuid, null, null, 20, 0);
    raise exception 'TEST FAILED: Store-B-only actor was able to query Store A movement history';
  exception when others then
    if sqlerrm not like '%فرع%' then
      raise;
    end if;
  end;

  -- Unscoped query (p_store_id null) silently returns zero rows for Store A
  -- data (never leaks it) — this actor has no movements of their own yet.
  select count(*) into v_count from public.list_inventory_stock_movements(null, null, null, null, 20, 0);
  if v_count <> 0 then
    raise exception 'TEST FAILED: Store-B-only actor unexpectedly saw % movement row(s) from a store they cannot access', v_count;
  end if;
end;
$$;

set local request.jwt.claims = '{"sub":"a9000000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$
declare
  v_count int;
begin
  select count(*) into v_count from public.list_inventory_stock_movements(current_setting('p9t.item_1')::uuid, current_setting('p9t.store_a')::uuid, null, null, 20, 0);
  if v_count < 3 then
    raise exception 'TEST FAILED: view-only actor with all-store access expected at least 3 movement rows for the test item, got %', v_count;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. audit_logs — every mutation above was recorded.
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"a9000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_count int;
  v_movements int;
begin
  select count(*) into v_count from public.audit_logs
  where entity_id = current_setting('p9t.item_1')::uuid
    and action in ('inventory.create_item', 'inventory.update_item');
  if v_count < 2 then
    raise exception 'TEST FAILED: expected at least 2 audit_logs rows (create_item + update_item) for the test item, got %', v_count;
  end if;

  -- The real invariant is "every COMMITTED movement produced exactly one
  -- audit row", not a hardcoded count — a literal is silently wrong the
  -- moment a movement is added to or reordered within this file (which is
  -- exactly what a stale `< 4` was here: only three movements have actually
  -- succeeded at this point, the two post-0230 sanity movements happen later
  -- in section 8). Comparing against the ledger itself keeps this assertion
  -- honest and self-maintaining.
  select count(*) into v_movements from public.inventory_stock_movements
  where item_id = current_setting('p9t.item_1')::uuid;

  select count(*) into v_count from public.audit_logs
  where action in ('inventory.receive', 'inventory.adjust')
    and entity_type = 'inventory_stock_movement'
    and (new_values ->> 'item_id') = current_setting('p9t.item_1');

  if v_movements = 0 then
    raise exception 'TEST FAILED: no stock movements were committed for the test item at all';
  end if;

  if v_count <> v_movements then
    raise exception 'TEST FAILED: expected exactly one audit_logs row per committed stock movement (% movements), got % audit rows', v_movements, v_count;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. acquire_inventory_item_store_lock() is internal-only (0230 fix) — an
--    ordinary authenticated actor (any permission set) cannot call the
--    advisory-lock helper directly, but receive/adjust RPCs (which call it
--    internally via record_inventory_stock_movement()'s owner privileges)
--    still work unaffected.
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"a9000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
begin
  begin
    perform public.acquire_inventory_item_store_lock(current_setting('p9t.item_1')::uuid, current_setting('p9t.store_a')::uuid);
    raise exception 'TEST FAILED: an authenticated actor was able to call acquire_inventory_item_store_lock() directly';
  exception
    when insufficient_privilege then
      null; -- expected: EXECUTE revoked from authenticated (0230)
    when others then
      raise exception 'TEST FAILED: acquire_inventory_item_store_lock() direct call rejected with an unexpected error (expected insufficient_privilege): %', sqlerrm;
  end;
end;
$$;

-- receive_inventory_stock()/adjust_inventory_stock() still work after the
-- 0230 fix — the lock is still reachable via record_inventory_stock_
-- movement()'s owner-privileged internal call.
set local request.jwt.claims = '{"sub":"a9000000-0000-4000-8000-000000000003","role":"authenticated"}';
do $$
declare
  v_balance text;
begin
  select resulting_balance into v_balance from public.receive_inventory_stock(current_setting('p9t.item_1')::uuid, current_setting('p9t.store_a')::uuid, 3, current_date, null, 'post-0230 sanity receipt');
  if v_balance <> '3.000' then
    raise exception 'TEST FAILED: receive_inventory_stock() stopped working after the 0230 EXECUTE revoke (expected resulting_balance=3.000, got %)', v_balance;
  end if;
end;
$$;

set local request.jwt.claims = '{"sub":"a9000000-0000-4000-8000-000000000004","role":"authenticated"}';
do $$
declare
  v_balance text;
begin
  select resulting_balance into v_balance from public.adjust_inventory_stock(current_setting('p9t.item_1')::uuid, current_setting('p9t.store_a')::uuid, -3, 'post-0230 sanity adjustment', current_date, null);
  if v_balance <> '0.000' then
    raise exception 'TEST FAILED: adjust_inventory_stock() stopped working after the 0230 EXECUTE revoke (expected resulting_balance=0.000, got %)', v_balance;
  end if;
end;
$$;

reset role;
rollback;

\echo 'inventory_core_phase9.test.sql PASSED'
