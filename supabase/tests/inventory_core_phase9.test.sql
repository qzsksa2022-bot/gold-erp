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
  where key in ('stores.view', 'karats.view', 'karats.manage', 'categories.view', 'categories.manage', 'inventory.view', 'inventory.receive', 'inventory.adjust');

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

  update public.profiles set store_access_scope = 'single', default_store_id = v_store_b
    where id = 'a9000000-0000-4000-8000-000000000005';
end;
$$;

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
  select resulting_balance into v_balance from public.receive_inventory_stock(current_setting('p9t.item_1')::uuid, current_setting('p9t.store_a')::uuid, 10, current_date, 'PO-1', 'first receipt');
  if v_balance <> '10' then
    raise exception 'TEST FAILED: expected resulting_balance=10 after first receipt, got %', v_balance;
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
  if v_balance <> '12.5' then
    raise exception 'TEST FAILED: expected resulting_balance=12.5 after +2.5 adjustment, got %', v_balance;
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
  if v_balance <> '0' then
    raise exception 'TEST FAILED: expected resulting_balance=0 after zeroing adjustment, got %', v_balance;
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
set local request.jwt.claims = '{"sub":"a9000000-0000-4000-8000-000000000004","role":"authenticated"}';
do $$
declare
  v_row_version bigint;
begin
  select row_version into v_row_version from public.inventory_items where id = current_setting('p9t.item_1')::uuid;

  -- Stale row_version is rejected.
  begin
    perform public.update_inventory_item(current_setting('p9t.item_1')::uuid, v_row_version - 1, 'اسم محدث', current_setting('p9t.category')::uuid, null, 'gram', true, null);
    raise exception 'TEST FAILED: a stale row_version was accepted by update_inventory_item';
  exception when others then
    if sqlerrm not like '%جهة أخرى%' then
      raise;
    end if;
  end;

  -- Correct row_version succeeds and increments.
  perform public.update_inventory_item(current_setting('p9t.item_1')::uuid, v_row_version, 'اسم محدث', current_setting('p9t.category')::uuid, null, 'gram', true, null);

  if (select row_version from public.inventory_items where id = current_setting('p9t.item_1')::uuid) <> v_row_version + 1 then
    raise exception 'TEST FAILED: row_version did not increment after a successful update';
  end if;
end;
$$;

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
begin
  select count(*) into v_count from public.audit_logs
  where entity_id = current_setting('p9t.item_1')::uuid
    and action in ('inventory.create_item', 'inventory.update_item');
  if v_count < 2 then
    raise exception 'TEST FAILED: expected at least 2 audit_logs rows (create_item + update_item) for the test item, got %', v_count;
  end if;

  select count(*) into v_count from public.audit_logs
  where action in ('inventory.receive', 'inventory.adjust')
    and entity_type = 'inventory_stock_movement'
    and (new_values ->> 'item_id') = current_setting('p9t.item_1');
  if v_count < 4 then
    raise exception 'TEST FAILED: expected at least 4 audit_logs rows for the test item''s stock movements, got %', v_count;
  end if;
end;
$$;

reset role;
rollback;

\echo 'inventory_core_phase9.test.sql PASSED'
