-- ============================================================================
-- Integration test: Production upgrade path onto Phase 9 (Inventory Core)
-- without re-running seed.sql
-- ============================================================================
-- This file does NOT build the database itself — it only ASSERTS against a
-- database that was already built the way a real production upgrade would
-- experience it:
--
--   1. Fresh DB, migrations 0001-0226 applied (everything through the
--      "CI: run verification on Phase branches" baseline — the last shipped
--      state before Phase 9).
--   2. The REAL supabase/seed.sql applied (a real upgrade already ran this
--      once, long before Phase 9 existed — it is never re-run here).
--   3. Migrations 0227 through the latest (Phase 9) applied on top — in a
--      SEPARATE psql invocation, exactly like a production upgrade would.
--
-- See scripts/run_upgrade_test_phase9_inventory.sh for the orchestration
-- that builds exactly this sequence, then runs this file.
--
-- Proves two distinct things:
--   (A) The 3 new Phase 9 permission keys (inventory.view/receive/adjust)
--       and their role grants come from migration 0227 itself, idempotently
--       — NOT from seed.sql (which never ran again) and not missing.
--   (B) The entire new Inventory engine is immediately USABLE the moment
--       0227-0229 finish applying — create an item, receive stock, adjust
--       stock, list balances/history — all inside this same rolled-back
--       transaction so it never mutates whatever database this runs
--       against. No pre-existing Sales/Returns/Settlements data is needed
--       (unlike Phase 6/7's upgrade tests) — Inventory Core is a wholly new,
--       additive module with zero dependency on prior transactional data.
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/upgrade_phase9_inventory.test.sql
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- (A) Permission keys + role grants come from 0227, not seed.sql.
-- ---------------------------------------------------------------------------
do $$
declare
  v_count integer;
  v_super_admin_count integer;
  v_admin_count integer;
  v_supervisor_count integer;
  v_accountant_count integer;
begin
  select count(*) into v_count from public.permissions
    where category = 'inventory'
    and key in ('inventory.view', 'inventory.receive', 'inventory.adjust');
  assert v_count = 3, format('BUG: يجب أن توجد 3 صلاحيات Phase 9 الجديدة بعد الترقية بدون seed.sql — وُجد %s', v_count);

  select count(*) into v_super_admin_count
  from public.role_permissions rp
  join public.roles r on r.id = rp.role_id
  join public.permissions p on p.id = rp.permission_id
  where r.key = 'super_admin' and p.key in ('inventory.view', 'inventory.receive', 'inventory.adjust');
  assert v_super_admin_count = 3, format('BUG: super_admin يجب أن يملك 3 صفوف صريحة لصلاحيات Phase 9 الجديدة، وُجد %s', v_super_admin_count);

  select count(*) into v_admin_count
  from public.role_permissions rp
  join public.roles r on r.id = rp.role_id
  join public.permissions p on p.id = rp.permission_id
  where r.key = 'admin' and p.key in ('inventory.view', 'inventory.receive', 'inventory.adjust');
  assert v_admin_count = 3, format('BUG: admin يجب أن يملك 3 صفوف صريحة لصلاحيات Phase 9 الجديدة، وُجد %s', v_admin_count);

  select count(*) into v_supervisor_count
  from public.role_permissions rp
  join public.roles r on r.id = rp.role_id
  join public.permissions p on p.id = rp.permission_id
  where r.key = 'supervisor' and p.key in ('inventory.view', 'inventory.receive', 'inventory.adjust');
  assert v_supervisor_count = 3, format('BUG: supervisor يجب أن يملك 3 صفوف صريحة لصلاحيات Phase 9 الجديدة، وُجد %s', v_supervisor_count);

  select count(*) into v_accountant_count
  from public.role_permissions rp
  join public.roles r on r.id = rp.role_id
  join public.permissions p on p.id = rp.permission_id
  where r.key = 'accountant' and p.key = 'inventory.view';
  assert v_accountant_count = 1, format('BUG: accountant يجب أن يملك inventory.view فقط، وُجد %s', v_accountant_count);
end;
$$;

-- ---------------------------------------------------------------------------
-- (B) End-to-end lifecycle usable immediately post-upgrade — no legacy
-- fixture needed.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values ('a9999999-0000-4000-8000-000000000001', 'test-p9-upgrade-actor@example.invalid');
update public.profiles set full_name = 'Test P9 Upgrade Actor', status = 'active', store_access_scope = 'all'
  where id = 'a9999999-0000-4000-8000-000000000001';
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a9999999-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in ('stores.view', 'categories.view', 'categories.manage', 'inventory.view', 'inventory.receive', 'inventory.adjust');

set role authenticated;
set local request.jwt.claims = '{"sub":"a9999999-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_store uuid;
  v_category uuid;
  v_item_id uuid;
  v_balance text;
  v_count int;
begin
  insert into public.stores (code, name_ar, status) values ('P9UP-ST', 'فرع ترقية 9', 'active') returning id into v_store;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('p9upcat', 'تصنيف ترقية 9', 991, 'active') returning id into v_category;

  select id into v_item_id from public.create_inventory_item('P9UP-SKU-1', 'صنف ترقية 9', v_category, null, 'gram', null);
  if v_item_id is null then
    raise exception 'BUG: create_inventory_item لم يُرجع صنفًا بعد الترقية';
  end if;

  select resulting_balance into v_balance from public.receive_inventory_stock(v_item_id, v_store, 20, current_date, 'PO-UPGRADE', null);
  if v_balance <> '20' then
    raise exception 'BUG: الرصيد المتوقع بعد الاستلام هو 20، وُجد %', v_balance;
  end if;

  select resulting_balance into v_balance from public.adjust_inventory_stock(v_item_id, v_store, -5, 'جرد فعلي بعد الترقية', current_date, null);
  if v_balance <> '15' then
    raise exception 'BUG: الرصيد المتوقع بعد التصحيح هو 15، وُجد %', v_balance;
  end if;

  -- Negative-stock rejection is immediately enforced post-upgrade.
  begin
    perform public.adjust_inventory_stock(v_item_id, v_store, -1000, 'محاولة سحب أكثر من المتاح', current_date, null);
    raise exception 'BUG: تم قبول تصحيح كان سيجعل الرصيد سالبًا بعد الترقية مباشرة';
  exception when others then
    if sqlerrm not like '%سالبة%' then
      raise;
    end if;
  end;

  select count(*) into v_count from public.list_inventory_stock_balances(v_store, v_item_id, null, 20, 0);
  if v_count <> 1 then
    raise exception 'BUG: يُتوقع صف رصيد واحد بعد الترقية، وُجد %', v_count;
  end if;

  select count(*) into v_count from public.list_inventory_stock_movements(v_item_id, v_store, null, null, 20, 0);
  if v_count <> 2 then
    raise exception 'BUG: يُتوقع حركتان (استلام + تصحيح) بعد الترقية، وُجد %', v_count;
  end if;
end;
$$;

reset role;
rollback;

\echo 'upgrade_phase9_inventory.test.sql PASSED'
